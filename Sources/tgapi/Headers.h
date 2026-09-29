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
+ (NSArray<NSArray<NSString *> *> *)deletedList;
@end

@interface AYProtected : NSObject
@property (class, nonatomic, readonly) BOOL isEnabled;
+ (NSData *)filter:(NSData *)data;
@end

@interface AYDeletedArchive : NSObject
+ (void)backfillWithNode:(NSObject *)node;
@end

@interface AYEditHistory : NSObject
@property (class, nonatomic, readonly) BOOL isEnabled;
@property (class, nonatomic, readonly) BOOL shouldObserve;
@property (class, nonatomic, readonly) NSNotificationName changedNotification;
+ (void)observe:(NSData *)data;
+ (BOOL)isEditedWithNode:(NSObject *)node;
+ (NSArray<NSArray<NSString *> *> *)versionsWithNode:(NSObject *)node;
+ (NSArray<NSArray<NSString *> *> *)versionsWithKey:(NSString *)key;
+ (NSArray<NSArray<NSString *> *> *)editedList;
@end

@interface AYMessageDetails : NSObject
+ (NSArray<NSArray<NSString *> *> *)linesWithNode:(NSObject *)node;
+ (NSString *)textWithNode:(NSObject *)node;
@end

@interface AYVoiceConverter : NSObject
+ (void)convertURL:(NSURL *)url
        completion:(void (^)(NSData *oggOpusData, NSTimeInterval duration, NSData *waveform, NSError *error))completion;
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
@property (nonatomic, strong) NSData *receiptPayload;
@property (nonatomic, strong) NSNumber *ayBypass;
- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser;
@property (nonatomic, copy) void (^completed)(id boxedResponse, MTRequestResponseInfo *info, MTRpcError *error);
@property (nonatomic, strong, readonly) id (^responseParser)(NSData *);
@end

@interface MTRequestMessageService : NSObject
- (void)addRequest:(MTRequest *)request;
@end

@interface AYReceipts : NSObject
+ (NSString *)peerKeyWithPayload:(NSData *)payload;
+ (NSString *)peerKeyWithNode:(NSObject *)node;
+ (NSString *)storyKeyWithView:(NSObject *)view;
@end

// Blocked read receipts held per chat; revealKey sends the real one on demand.
@interface AYReceiptQueue : NSObject
+ (void)holdPayload:(NSData *)payload service:(MTRequestMessageService *)service;
+ (BOOL)hasHeldForKey:(NSString *)key;
+ (NSString *)latestStoryKey;
+ (void)revealKey:(NSString *)key completion:(void (^)(BOOL ok))completion;
@end

// Function Handlers
#ifdef __cplusplus
extern "C" {
#endif
void handleOnlineStatus(MTRequest *request, NSData *payload);
void handleSetTyping(MTRequest *request, NSData *payload);
void handleMessageReadReceipt(MTRequest *request, NSData *payload);
void handleReadMessageContents(MTRequest *request, NSData *payload);
void handleChannelsReadMessageContents(MTRequest *request, NSData *payload);
void handleStoriesReadReceipt(MTRequest *request, NSData *payload);
void handleStoriesIncrementViews(MTRequest *request, NSData *payload);
void handleGetSponsoredMessages(MTRequest *request, NSData *payload);
void handleChannelsReadReceipt(MTRequest *request, NSData *payload);
#ifdef __cplusplus
}
#endif
