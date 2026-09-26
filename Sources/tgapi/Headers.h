#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Logger/Logger.h"
#import "Constants.h"

@interface TLParser : NSObject
+ (NSData *)handleResponse:(NSData *)data functionID:(NSNumber *)ios;
@end

@interface AYDeletedFilter : NSObject
@property (class, nonatomic, readonly) BOOL isEnabled;
+ (NSData *)filter:(NSData *)data;
@end

@interface AYDeletedMarks : NSObject
@property (class, nonatomic, readonly) NSNotificationName changedNotification;
+ (BOOL)isDeletedWithNode:(NSObject *)node;
+ (NSString *)keyWithNode:(NSObject *)node;
@end

@interface AYEditHistory : NSObject
@property (class, nonatomic, readonly) BOOL isEnabled;
@property (class, nonatomic, readonly) NSNotificationName changedNotification;
+ (void)observe:(NSData *)data;
+ (BOOL)isEditedWithNode:(NSObject *)node;
+ (NSArray<NSArray<NSString *> *> *)versionsWithNode:(NSObject *)node;
@end

@interface AYMessageDetails : NSObject
+ (NSArray<NSArray<NSString *> *> *)linesWithNode:(NSObject *)node;
@end

@interface AYNotes : NSObject
@property (class, nonatomic, readonly) NSNotificationName changedNotification;
+ (BOOL)hasNoteWithNode:(NSObject *)node;
+ (NSString *)noteWithNode:(NSObject *)node;
+ (void)setNoteWithNode:(NSObject *)node text:(NSString *)text;
+ (NSArray<NSArray<NSString *> *> *)all;
@end

@interface MTRpcError : NSObject
- (id)initWithErrorCode:(int)code errorDescription:(id)desc;
@end

@interface MTRequestResponseInfo : NSObject
- (id)initWithNetworkType:(int)a  timestamp:(CGFloat)b  duration:(CGFloat)c;
@end

@interface MTRequest : NSObject
@property (nonatomic, strong) NSNumber *functionID;
@property (nonatomic, strong) NSData *fakeData;
@property (nonatomic, copy) void (^completed)(id boxedResponse, MTRequestResponseInfo *info, MTRpcError *error);
@property (nonatomic, strong, readonly) id (^responseParser)(NSData *);
@end

// Function Handlers
#ifdef __cplusplus
extern "C" {
#endif
void handleOnlineStatus(MTRequest *request, NSData *payload);
void handleSetTyping(MTRequest *request, NSData *payload);
void handleMessageReadReceipt(MTRequest *request, NSData *payload);
void handleStoriesReadReceipt(MTRequest *request, NSData *payload);
void handleGetSponsoredMessages(MTRequest *request, NSData *payload);
void handleChannelsReadReceipt(MTRequest *request, NSData *payload);
#ifdef __cplusplus
}
#endif
