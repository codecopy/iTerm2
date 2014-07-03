//
//  iTermRestorableSession.h
//  iTerm
//
//  Created by George Nachman on 5/30/14.
//
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, iTermRestorableSessionGroup) {
    kiTermRestorableSessionGroupSession,
    kiTermRestorableSessionGroupTab,
    kiTermRestorableSessionGroupWindow
};

@class PTYSession;

@interface iTermRestorableSession : NSObject

@property(nonatomic, retain) NSArray *sessions;
@property(nonatomic, copy) NSString *terminalGuid;
@property(nonatomic, assign) int tabUniqueId;
@property(nonatomic, retain) NSDictionary *arrangement;
@property(nonatomic, assign) iTermRestorableSessionGroup group;

@end
