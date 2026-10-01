#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Logger/Logger.h"
#import "Constants.h"

// Short self-dismissing message at the bottom of the key window (DeletedBadge.xm).
void AYPresentToast(NSString *message);

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
+ (BOOL)isDeletedWithKey:(NSString *)key;
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
+ (BOOL)isEditedWithKey:(NSString *)key;
+ (NSArray<NSArray<NSString *> *> *)versionsWithNode:(NSObject *)node;
+ (NSArray<NSArray<NSString *> *> *)versionsWithKey:(NSString *)key;
+ (NSArray<NSArray<NSString *> *> *)editedList;
@end

@interface AYMessageDetails : NSObject
+ (NSArray<NSArray<NSString *> *> *)linesWithNode:(NSObject *)node;
+ (NSString *)textWithNode:(NSObject *)node;
@end

// Speaks a message's text on-device with AVSpeechSynthesizer (ReadAloud.m, #29).
@interface AYReadAloud : NSObject
+ (void)speak:(NSString *)text;
@end

@interface AYVoiceConverter : NSObject
+ (void)convertURL:(NSURL *)url
        completion:(void (^)(NSData *oggOpusData, NSTimeInterval duration, NSData *waveform, NSError *error))completion;
+ (void)decodeURL:(NSURL *)url completion:(void (^)(NSData *pcm, NSError *error))completion;
+ (BOOL)writePCM:(NSData *)pcm toWriter:(id)writer;
@end

// Reflects a story/secret-media viewer object for the byte size of the video it shows, so the
// Save button can find that exact file in the Postbox media cache (see DeletedBadge.xm).
@interface AYMediaFile : NSObject
+ (NSNumber *)videoByteSizeFrom:(NSObject *)root;
@end

@interface AYNotes : NSObject
@property (class, nonatomic, readonly) NSNotificationName changedNotification;
+ (BOOL)hasNoteWithNode:(NSObject *)node;
+ (BOOL)hasNoteWithKey:(NSString *)key;
@property (class, nonatomic, readonly) BOOL isEmpty;
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

// Swift payload builder (DirectSend.swift): serializes layer-229 upload/send requests.
@interface AYDirectSend : NSObject
+ (NSData *)saveFilePartWithFileId:(long long)fileId part:(int)part chunk:(NSData *)chunk;
+ (NSData *)sendVoiceWithFileId:(long long)fileId parts:(int)parts duration:(int)duration waveform:(NSData *)waveform randomId:(long long)randomId peer:(NSData *)peer;
+ (NSData *)sendImageDocumentWithFileId:(long long)fileId parts:(int)parts fileName:(NSString *)fileName mime:(NSString *)mime width:(int)width height:(int)height randomId:(long long)randomId peer:(NSData *)peer;
@end

// Records the live main-API request service so AYVoiceSend can issue its own requests through it.
void AYCaptureRequestService(MTRequestMessageService *service);

// Remembers the current chat's InputPeer by sniffing outgoing getHistory/readHistory payloads.
void AYCaptureOutgoingPeer(NSData *payload);

// Uploads an OGG/Opus clip and sends it as a real voice message (no mic), via raw MTProto.
// chatKey is the target chat's normalized key ("u<id>"/"g<id>"/"c<id>", from AYReceipts); the
// matching InputPeer (captured from that chat's own traffic) is used so the voice note lands in the
// chat the user is looking at, not Saved Messages. nil falls back to the most recent chat.
@interface AYVoiceSend : NSObject
+ (void)sendOGG:(NSData *)ogg duration:(int)duration waveform:(NSData *)waveform chatKey:(NSString *)chatKey;
@end

// Shared raw-MTProto plumbing (DirectSendRunner.mm): issue a serialized request through the live
// service (NO if none captured yet), and the InputPeer of the chat the user is looking at. Declared
// without extern "C" to match the ObjC++ definitions, like AYCaptureRequestService above.
BOOL AYIssueRequest(NSData *payload, int functionId, void (^completed)(id result, MTRpcError *error));
NSData *AYCurrentPeerOrSelf(void);
// The InputPeer captured for a specific chat key ("u<id>"/"g<id>"/"c<id>"), or nil if that chat's
// traffic hasn't been seen this session. Used to target the exact chat instead of the latest one.
NSData *AYPeerForChatKey(NSString *key);

// messages.translateText serializer / result reader (Translate.swift, #25).
@interface AYTranslate : NSObject
+ (NSData *)buildTranslateText:(NSString *)text toLang:(NSString *)toLang;
+ (NSString *)parseTranslated:(NSData *)data;
@end

@interface AYReceipts : NSObject
+ (NSString *)peerKeyWithPayload:(NSData *)payload;
+ (NSString *)peerKeyWithNode:(NSObject *)node;
+ (NSString *)storyKeyWithView:(NSObject *)view;
+ (NSString *)chatKeyWithController:(NSObject *)controller;
+ (BOOL)isAllowedWithKey:(NSString *)key;
+ (void)setAllowed:(BOOL)allowed key:(NSString *)key;
@end

// Posted on the main queue whenever a receipt is held or revealed.
#define kAYReceiptsChangedNotification @"ayTELEReceiptsChanged"

// Blocked read receipts held per chat; revealKey sends the real one on demand.
@interface AYReceiptQueue : NSObject
+ (void)holdPayload:(NSData *)payload service:(MTRequestMessageService *)service;
+ (BOOL)hasHeldForKey:(NSString *)key;
+ (NSString *)latestStoryKey;
+ (NSString *)latestChatKey;
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
