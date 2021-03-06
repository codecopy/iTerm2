//
//  iTermGraphDatabase.m
//  iTerm2
//
//  Created by George Nachman on 7/27/20.
//

#import "iTermGraphDatabase.h"

#import "DebugLogging.h"
#import "FMDatabase.h"
#import "NSArray+iTerm.h"
#import "NSObject+iTerm.h"
#import "iTermGraphDeltaEncoder.h"
#import "iTermGraphTableTransformer.h"
#import "iTermThreadSafety.h"
#import <stdatomic.h>

@class iTermGraphDatabaseState;

@interface iTermGraphDatabaseState: iTermSynchronizedState<iTermGraphDatabaseState *>
@property (nonatomic, strong) id<iTermDatabase> db;
// Load complete means that the initial attempt to load the DB has finished. It may have failed, leaving
// us without any state, but it is now safe to proceed to use the graph DB as it won't change out
// from under you after this point.
@property (nonatomic) BOOL loadComplete;
- (instancetype)initWithQueue:(dispatch_queue_t)queue database:(id<iTermDatabase>)db;
- (void)addLoadCompleteBlock:(void (^)(void))block;
@end

@implementation iTermGraphDatabaseState {
    NSMutableArray<void (^)(void)> *_loadCompleteBlocks;
}
- (instancetype)initWithQueue:(dispatch_queue_t)queue database:(id<iTermDatabase>)db {
    self = [super initWithQueue:queue];
    if (self) {
        _db = db;
        _loadCompleteBlocks = [NSMutableArray array];
    }
    return self;
}

- (void)addLoadCompleteBlock:(void (^)(void))block {
    if (self.loadComplete) {
        dispatch_async(dispatch_get_main_queue(), block);
    } else {
        [_loadCompleteBlocks addObject:[block copy]];
    }
}

- (void)setLoadComplete:(BOOL)loadComplete {
    if (loadComplete == _loadComplete) {
        return;
    }
    if (loadComplete && !_loadComplete) {
        NSArray<void (^)(void)> *blocks = [_loadCompleteBlocks copy];
        [_loadCompleteBlocks removeAllObjects];
        [blocks enumerateObjectsUsingBlock:^(void (^ _Nonnull block)(void), NSUInteger idx, BOOL * _Nonnull stop) {
            dispatch_async(dispatch_get_main_queue(), block);
        }];
    }
    _loadComplete = loadComplete;
}

@end

@interface iTermGraphDatabase()
@property (atomic, readwrite) iTermEncoderGraphRecord *record;
@end

@implementation iTermGraphDatabase {
    NSInteger _recoveryCount;
    _Atomic int _updating;
    _Atomic int _invalid;
}

- (instancetype)initWithDatabase:(id<iTermDatabase>)db {
    self = [super init];
    if (self) {
        if (![db lock]) {
            DLog(@"Could not acquire lock. Give up.");
            return nil;
        }
        _updating = ATOMIC_VAR_INIT(0);
        _invalid = ATOMIC_VAR_INIT(0);
        _thread = [[iTermThread alloc] initWithLabel:@"com.iterm2.graph-db"
                                        stateFactory:^iTermSynchronizedState * _Nonnull(dispatch_queue_t  _Nonnull queue) {
            return [[iTermGraphDatabaseState alloc] initWithQueue:queue
                                                         database:db];
        }];

        _url = [db url];
        [_thread dispatchAsync:^(iTermGraphDatabaseState *state) {
            [self finishInitialization:state];
            state.loadComplete = YES;
        }];
    }
    return self;
}

- (void)finishInitialization:(iTermGraphDatabaseState *)state {
    if ([self reallyFinishInitialization:state]) {
        return;
    }
    // Failed.
    [state.db unlock];
    state.db = nil;
    _invalid = YES;
}

- (BOOL)reallyFinishInitialization:(iTermGraphDatabaseState *)state {
    if (![self openAndInitializeDatabase:state]) {
        DLog(@"openAndInitialize failed. Attempt recovery.");
        return [self attemptRecovery:state encoder:nil];
    }
    DLog(@"Opened ok.");

    NSError *error = nil;
    self.record = [self load:state error:&error];
    if (error) {
        DLog(@"load failed. Attempt recovery.");
        return [self attemptRecovery:state encoder:nil];
    }
    DLog(@"Loaded ok.");

    return YES;
}

// NOTE: It is critical that the completion block not be called synchronously.
- (BOOL)updateSynchronously:(BOOL)sync
                      block:(void (^ NS_NOESCAPE)(iTermGraphEncoder * _Nonnull))block
                 completion:(nullable iTermCallback *)completion {
    assert([NSThread isMainThread]);
    if (_invalid) {
        [completion invokeWithObject:@NO];
        return YES;
    }
    if (self.updating && !sync) {
        return NO;
    }
    [self beginUpdate];
    iTermGraphDeltaEncoder *encoder = [[iTermGraphDeltaEncoder alloc] initWithPreviousRevision:self.record];
    block(encoder);
    __weak __typeof(self) weakSelf = self;

    void (^perform)(iTermGraphDatabaseState *) = ^(iTermGraphDatabaseState *state) {
        if (!self->_invalid) {
            [weakSelf trySaveEncoder:encoder state:state completion:completion];
        }
        [weakSelf endUpdate];
    };
    if (sync) {
        [_thread dispatchSync:perform];
    } else {
        [_thread dispatchAsync:perform];
    }
    return YES;
}

- (void)invalidate {
    [_thread dispatchAsync:^(iTermGraphDatabaseState *state) {
        self->_invalid = YES;
        [state.db close];
        state.db = nil;
    }];
}

- (void)whenReady:(void (^)(void))readyBlock {
    [_thread dispatchAsync:^(iTermGraphDatabaseState *state) {
        [state addLoadCompleteBlock:readyBlock];
    }];
}

#pragma mark - Private

// any queue
- (BOOL)updating {
    return _updating > 0;
}

// any queue
- (void)beginUpdate {
    _updating++;
}

// any queue
- (void)endUpdate {
    _updating--;
}

// This will mutate encoder.record.
// NOTE: It is critical that the completion block not be called synchronously.
- (void)trySaveEncoder:(iTermGraphDeltaEncoder *)originalEncoder
                 state:(iTermGraphDatabaseState *)state
            completion:(nullable iTermCallback *)completion {
    iTermGraphDeltaEncoder *encoder = originalEncoder;
    BOOL ok = YES;
    @try {
        if (!state.db) {
            ok = NO;
            return;
        }
        if ([self save:encoder state:state]) {
            _recoveryCount = 0;
            return;
        }

        DLog(@"save failed: %@ with recovery count %@", state.db.lastError, @(_recoveryCount));
        if (_recoveryCount >= 3) {
            DLog(@"Not attempting recovery.");
            ok = NO;
            return;
        }
        _recoveryCount += 1;
        // Create a fresh encoder that's not in a partially broken state. Replace the encoder pointer
        // so we can get its record below, as a successful recovery mutates the record by setting
        // rowids in it.
        encoder = [[iTermGraphDeltaEncoder alloc] initWithRecord:originalEncoder.record];
        ok = [self attemptRecovery:state encoder:encoder];
    } @catch (NSException *exception) {
        ITAssertWithMessage(NO, @"%@", exception.it_compressedDescription);
    } @finally {
        [completion invokeWithObject:@(ok)];
        if (ok) {
            // If we were able to save, then use this record as the new baseline. Note that we
            // very carefully take it from encoder, not originalEncoder, because regardless of
            // whether a recovery was attempted `encoder.record` has the correct rowids.
            self.record = encoder.record;
        }
    }
}

// On failure, the db will be closed.
- (BOOL)attemptRecovery:(iTermGraphDatabaseState *)state
                encoder:(iTermGraphDeltaEncoder *)encoder {
    if (!state.db) {
        return NO;
    }
    [state.db close];
    [state.db unlink];
    if (![self openAndInitializeDatabase:state]) {
        DLog(@"Failed to open and initialize datbase after deleting it.");
        return NO;
    }
    if (!encoder) {
        DLog(@"Opened database after deleting it. There is no record to save.");
        return YES;
    }
    DLog(@"Save record after deleting and creating database.");
    const BOOL ok = [self save:encoder state:state];
    if (!ok) {
        [state.db close];
        return NO;
    }
    return YES;
}

- (BOOL)save:(iTermGraphDeltaEncoder *)encoder
       state:(iTermGraphDatabaseState *)state {
    assert(state.db);

    const BOOL ok = [state.db transaction:^BOOL{
        return [self reallySave:encoder state:state];
    }];
    if (!ok) {
        [encoder.record eraseRowIDs];
        DLog(@"Commit transaction failed: %@", state.db.lastError);
    }
    return ok;
}

// Runs within a transaction.
- (BOOL)reallySave:(iTermGraphDeltaEncoder *)encoder
             state:(iTermGraphDatabaseState *)state {
    DLog(@"Start saving");
    NSDate *start = [NSDate date];
    const BOOL ok =
    [encoder enumerateRecords:^(iTermEncoderGraphRecord * _Nullable before,
                                iTermEncoderGraphRecord * _Nullable after,
                                NSNumber *parent,
                                BOOL *stop) {
        if (before && !before.rowid) {
            @throw [NSException exceptionWithName:@"MissingRowID"
                                           reason:[NSString stringWithFormat:@"Before lacking a rowid: %@", before]
                                         userInfo:nil];
        }
        if (before && !after) {
            if (![state.db executeUpdate:@"delete from Node where rowid=?", before.rowid]) {
                *stop = YES;
                return;
            }
            return;
        }
        if (!before && after) {
            if (![state.db executeUpdate:@"insert into Node (key, identifier, parent, data) values (?, ?, ?, ?)",
                  after.key, after.identifier, parent, after.data ?: [NSData data]]) {
                *stop = YES;
                return;
            }
            NSNumber *lastInsertRowID = state.db.lastInsertRowId;
            assert(lastInsertRowID);
            @try {
                // Issue 9117
                after.rowid = lastInsertRowID;
            } @catch (NSException *exception) {
                @throw [exception it_rethrowWithMessage:@"after.key=%@ after.identifier=%@", after.key, after.identifier];
            }
            return;
        }
        if (before && after) {
            if (after.rowid == nil) {
                after.rowid = before.rowid;
            } else {
                if (before.generation == after.generation &&
                    after.generation != iTermGenerationAlwaysEncode) {
                    DLog(@"Don't update rowid %@ %@[%@] because it is unchanged", before.rowid, after.key, after.identifier);
                    return;
                }
            }
            assert(before.rowid.longLongValue == after.rowid.longLongValue);
            if ([before.data isEqual:after.data]) {
                return;
            }
            if (![state.db executeUpdate:@"update Node set data=? where rowid=?", after.data, before.rowid]) {
                *stop = YES;
            }
            return;
        }
        assert(NO);
    }];
    NSDate *end = [NSDate date];
    DLog(@"Save duration: %f0.1ms", (end.timeIntervalSinceNow - start.timeIntervalSinceNow) * 1000);
    return ok;
}

- (BOOL)createTables:(iTermGraphDatabaseState *)state {
    [state.db executeUpdate:@"PRAGMA journal_mode=WAL"];

    if (![state.db executeUpdate:@"create table if not exists Node (key text not null, identifier text not null, parent integer not null, data blob)"]) {
        return NO;
    }
    [state.db executeUpdate:@"create index if not exists parent_index on Node (parent)"];

    // Delete nodes without parents.
    [state.db executeUpdate:
     @"delete from Node where "
     @"  rowid in ("
     @"    select child.rowid as id "
     @"      from "
     @"        Node as child"
     @"        left join "
     @"          Node as parentNode "
     @"          on parentNode.rowid = child.parent "
     @"      where "
     @"        parentNode.rowid is NULL and "
     @"        child.parent != 0"
     @"  )"];
    return YES;
}

// If this returns YES, the database is open and has the expected tables.
- (BOOL)openAndInitializeDatabase:(iTermGraphDatabaseState *)state {
    if (![state.db open]) {
        return NO;
    }

    if (![self createTables:state]) {
        DLog(@"Create table failed: %@", state.db.lastError);
        [state.db close];
        return NO;
    }
    return YES;
}

- (iTermEncoderGraphRecord * _Nullable)load:(iTermGraphDatabaseState *)state
                                      error:(out NSError **)error {
    NSMutableArray<NSArray *> *nodes = [NSMutableArray array];
    {
        FMResultSet *rs = [state.db executeQuery:@"select key, identifier, parent, rowid, data from Node"];
        while ([rs next]) {
            [nodes addObject:@[ [rs stringForColumn:@"key"],
                                [rs stringForColumn:@"identifier"],
                                @([rs longLongIntForColumn:@"parent"]),
                                @([rs longLongIntForColumn:@"rowid"]),
                                [rs dataForColumn:@"data"] ?: [NSData data] ]];
        }
        [rs close];
    }

    iTermGraphTableTransformer *transformer = [[iTermGraphTableTransformer alloc] initWithNodeRows:nodes];
    iTermEncoderGraphRecord *record = transformer.root;
    
    if (!record) {
        if (error) {
            *error = transformer.lastError;
        }
        return nil;
    }

    return record;
}

@end

