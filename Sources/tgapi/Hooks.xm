#import "Headers.h"

#define kChannelsReadHistory -871347913

// Read receipts we answered with fakeData, newest per chat, so the two-finger menu can
// send the real one later ("reveal"). The service is weak: a logged-out account just drops it.
@interface AYHeldReceipt : NSObject
@property (nonatomic, copy) NSData *payload;
@property (nonatomic, weak) MTRequestMessageService *service;
@end
@implementation AYHeldReceipt
@end

@implementation AYReceiptQueue
+ (NSMutableDictionary<NSString *, AYHeldReceipt *> *)held {
	static NSMutableDictionary *held;
	static dispatch_once_t token;
	dispatch_once(&token, ^{ held = [NSMutableDictionary new]; });
	return held;
}
+ (void)holdPayload:(NSData *)payload service:(MTRequestMessageService *)service {
	NSString *key = nil;
	@try { key = [AYReceipts peerKeyWithPayload:payload]; } @catch (NSException *e) {}
	if (!key || !service) return;
	AYHeldReceipt *receipt = [AYHeldReceipt new];
	receipt.payload = payload;
	receipt.service = service;
	@synchronized (self) {
		[self held][key] = receipt;
		[self latest][[key hasPrefix:@"s:"] ? @"story" : @"chat"] = key;
	}
	[self postChanged];
}
+ (void)postChanged {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:kAYReceiptsChangedNotification object:nil];
	});
}
// Most recent held story key: the story viewer's fallback when reflection can't name the peer.
+ (NSMutableDictionary<NSString *, NSString *> *)latest {
	static NSMutableDictionary *latest;
	static dispatch_once_t token;
	dispatch_once(&token, ^{ latest = [NSMutableDictionary new]; });
	return latest;
}
+ (NSString *)latestStoryKey {
	@synchronized (self) { return [self latest][@"story"]; }
}
// Most recent held chat (messages/channels.readHistory) key: the chat eye's fallback.
+ (NSString *)latestChatKey {
	@synchronized (self) { return [self latest][@"chat"]; }
}
+ (BOOL)hasHeldForKey:(NSString *)key {
	if (!key) return NO;
	@synchronized (self) { return [self held][key].service != nil; }
}
+ (void)revealKey:(NSString *)key completion:(void (^)(BOOL ok))completion {
	AYHeldReceipt *receipt = nil;
	if (key) { @synchronized (self) { receipt = [self held][key]; } }
	MTRequestMessageService *service = receipt.service;
	if (!receipt || !service) {
		if (completion) completion(NO);
		return;
	}
	MTRequest *request = [[%c(MTRequest) alloc] init];
	request.ayBypass = @YES; // must be set before setPayload so the hook doesn't block it again
	[request setPayload:receipt.payload metadata:@"ayTELE.reveal" shortMetadata:@"ayTELE.reveal" responseParser:^id(NSData *data) {
		return data;
	}];
	request.completed = ^(id response, MTRequestResponseInfo *info, MTRpcError *error) {
		BOOL ok = error == nil;
		if (ok) {
			@synchronized (self) {
				if ([self held][key] == receipt) [[self held] removeObjectForKey:key];
			}
			[self postChanged];
		}
		if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
	};
	[service addRequest:request];
}
@end

%hook MTRequest
%property (nonatomic, strong) NSData *fakeData;
%property (nonatomic, strong) NSNumber *functionID;
%property (nonatomic, strong) NSData *receiptPayload;
%property (nonatomic, strong) NSNumber *ayBypass;

- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser {
	
	// Extract Function id 
	int32_t functionID;
	[payload getBytes:&functionID length:4];
	self.functionID = [NSNumber numberWithInt:functionID];

	// Learn which chat the user is in, so AYVoiceSend can target it (not Saved Messages).
	AYCaptureOutgoingPeer(payload);
	
	//customLog(@"Function id: %d", functionID);
	
	id(^hooked_block)(NSData *) = ^(NSData *inputData) {
		if (AYEditHistory.shouldObserve) {
			[AYEditHistory observe:inputData];
		}
		if (AYDeletedFilter.isEnabled) {
			NSData *filtered = [AYDeletedFilter filter:inputData];
			if (filtered) inputData = filtered;
		}
		if (!AYProtected.isEnabled) {
			return responseParser(inputData);
		}
		NSData *filtered = nil;
		@try {
			filtered = [AYProtected filter:inputData];
		} @catch (NSException *exception) {
			customLog2(@"Protected content filter failed: %@", exception);
		}
		return responseParser(filtered ?: inputData);
	};
	
	if (!self.ayBypass.boolValue) switch (functionID) {
		case kAccountUpdateOnlineStatus:
		   handleOnlineStatus(self, payload);
		   break;
		case kMessagesSetTypingAction:
		   handleSetTyping(self, payload);
		   break;
		case kMessagesReadHistory:
		   handleMessageReadReceipt(self, payload);
		   break;
		case kMessagesReadMessageContents:
		   handleReadMessageContents(self, payload);
		   break;
		case kChannelsReadMessageContents:
		   handleChannelsReadMessageContents(self, payload);
		   break;
		case kStoriesReadStories:
		   handleStoriesReadReceipt(self, payload);
		   break;
		case kStoriesIncrementStoryViews:
		   handleStoriesIncrementViews(self, payload);
		   break;
		case kGetSponsoredMessages:
		   handleGetSponsoredMessages(self, payload);
		   break;
		case kChannelsReadHistory:
		   handleChannelsReadReceipt(self, payload);
		   break;
		default:
		   break;
		   
	}

	if (self.fakeData && (functionID == kMessagesReadHistory || functionID == kChannelsReadHistory || functionID == kStoriesReadStories)) {
		self.receiptPayload = payload;
	}
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	if ([defaults boolForKey:kDisableForwardRestriction] || [defaults boolForKey:kKeepViewOnceMedia] || [defaults boolForKey:kKeepDeletedMessages] || [defaults boolForKey:kKeepEditHistory]) {
		%orig(payload, metadata, shortMetadata, hooked_block);
	} else {
		%orig(payload, metadata, shortMetadata, responseParser);
	}
}

%end


// Manager which handles requests
%hook MTRequestMessageService

- (void)addRequest:(MTRequest *)request {
    if (request.fakeData) {
        if (request.receiptPayload) [AYReceiptQueue holdPayload:request.receiptPayload service:self];
        @try {
             if (request.completed) {
                 NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];

                 MTRequestResponseInfo *info = [[%c(MTRequestResponseInfo) alloc] initWithNetworkType:1 
					     timestamp:currentTime 
						  duration:0.045
					   ];
						
						id result = request.responseParser(request.fakeData);
						request.completed(result, info, nil);
             }
         } @catch (NSException *exception) {
             customLog2(@"Exception in MTRequestMessageService hook: %@", exception);
         }
        return;
    }
    // Remember this live service so AYVoiceSend can push its own upload/send requests through it.
    AYCaptureRequestService(self);
    %orig;
}

%end


// Pushed updates (not RPC results) are decoded by TelegramCore's Serialization after MtProtoKit
// unwraps gzip and finds no internal MTProto message: -[MTProto ...] -> [serialization parseMessage:].
%hook _TtC12TelegramCore13Serialization

- (id)parseMessage:(NSData *)data {
	if (data && [[NSUserDefaults standardUserDefaults] boolForKey:kKeywordAlert]) {
		@try {
			[AYKeywordAlert scan:data];
		} @catch (NSException *exception) {
			customLog2(@"Keyword alert scan failed: %@", exception);
		}
	}
	if (data && AYEditHistory.shouldObserve) {
		@try {
			[AYEditHistory observe:data];
		} @catch (NSException *exception) {
			customLog2(@"Edit history observe failed: %@", exception);
		}
	}
	if (data && AYDeletedFilter.isEnabled) {
		@try {
			NSData *filtered = [AYDeletedFilter filter:data];
			if (filtered) data = filtered;
		} @catch (NSException *exception) {
			customLog2(@"Deleted messages filter failed: %@", exception);
		}
	}
	// Pushed stories / view-once media: re-serialized only when a protected flag was dropped.
	if (data && AYProtected.isEnabled) {
		@try {
			NSData *filtered = [AYProtected filter:data];
			if (filtered) data = filtered;
		} @catch (NSException *exception) {
			customLog2(@"Protected content filter failed: %@", exception);
		}
	}
	return %orig(data);
}

%end
