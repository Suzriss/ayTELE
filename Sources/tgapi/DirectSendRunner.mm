#import "Headers.h"
#import <objc/runtime.h>

// Sends a voice message without the mic, the way iQTele does: upload the OGG/Opus bytes with
// upload.saveFilePart, then messages.sendMedia carrying a voice document. The payloads come from
// AYDirectSend (Swift, layer-229 exact); we issue them as real MTRequests through the live
// MTRequestMessageService captured from our existing addRequest: hook. v1 sends to Saved Messages
// so the whole pipeline (serialize → upload → send) can be verified before we target a chat.

void AYPresentToast(NSString *message);
@interface ayTELELocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

static __weak MTRequestMessageService *gService;

void AYCaptureRequestService(MTRequestMessageService *service) {
	if (service) gService = service;
}

// The InputPeer of the chat the user is most likely looking at, sniffed from outgoing
// getHistory/readHistory requests (peer is their first field). Raw serialized InputPeer bytes.
static NSData *gCurrentPeer;
static NSTimeInterval gCurrentPeerTime;

void AYCaptureOutgoingPeer(NSData *payload) {
	if (payload.length < 8) return;
	uint32_t fid = 0;
	[payload getBytes:&fid length:4];
	if (fid != 0x4423e6c5 /* messages.getHistory */ && fid != 0x0e306d3a /* messages.readHistory */) return;
	uint32_t ctor = 0;
	[payload getBytes:&ctor range:NSMakeRange(4, 4)];
	NSUInteger len;
	switch (ctor) {
		case 0x7da07ec9: len = 4; break;   // inputPeerSelf
		case 0x35a95cb9: len = 12; break;  // inputPeerChat
		case 0xdde8a54c: len = 20; break;  // inputPeerUser
		case 0x27bcbbfc: len = 20; break;  // inputPeerChannel
		default: return;
	}
	if (payload.length < 4 + len) return;
	gCurrentPeer = [payload subdataWithRange:NSMakeRange(4, len)];
	gCurrentPeerTime = [NSDate date].timeIntervalSince1970;
}

// The captured peer if it's fresh enough, else inputPeerSelf (Saved Messages) as a safe fallback.
static NSData *currentPeerOrSelf(void) {
	if (gCurrentPeer && ([NSDate date].timeIntervalSince1970 - gCurrentPeerTime) < 3600) return gCurrentPeer;
	uint32_t self = 0x7da07ec9;  // inputPeerSelf
	return [NSData dataWithBytes:&self length:4];
}

static void toast(NSString *key) {
	AYPresentToast([ayTELELocalization localizedStringForKey:key]);
}

static long long randomLong(void) {
	return ((long long)arc4random() << 32) | (long long)arc4random();
}

// A fresh MTRequest carrying our serialized payload; completed(result, error) fires on response.
static MTRequest *makeRequest(NSData *payload, int functionId, void (^completed)(id result, MTRpcError *error)) {
	Class reqCls = objc_getClass("MTRequest");
	MTRequest *req = [[reqCls alloc] init];
	req.functionID = @(functionId);
	[req setPayload:payload metadata:@(functionId) shortMetadata:@(functionId) responseParser:^id(NSData *response) {
		return response ?: [NSData data];
	}];
	req.completed = ^(id boxedResponse, MTRequestResponseInfo *info, MTRpcError *error) {
		if (completed) completed(boxedResponse, error);
	};
	return req;
}

// Shared plumbing so other raw-MTProto features (e.g. translate) reuse the live service, the
// sniffed current peer, and the request builder instead of duplicating any of it.
BOOL AYIssueRequest(NSData *payload, int functionId, void (^completed)(id result, MTRpcError *error)) {
	MTRequestMessageService *service = gService;
	if (!service || payload.length == 0) return NO;
	[service addRequest:makeRequest(payload, functionId, completed)];
	return YES;
}

NSData *AYCurrentPeerOrSelf(void) { return currentPeerOrSelf(); }

@implementation AYVoiceSend

+ (void)sendOGG:(NSData *)ogg duration:(int)duration waveform:(NSData *)waveform {
	MTRequestMessageService *service = gService;
	if (ogg.length == 0 || !service) { toast(@"VOICE_SEND_FAILED"); return; }
	long long fileId = randomLong();
	NSUInteger partSize = 512 * 1024;
	int parts = (int)((ogg.length + partSize - 1) / partSize);
	[self uploadPart:0 ofTotal:parts fileId:fileId ogg:ogg partSize:partSize
		duration:duration waveform:waveform service:service];
}

+ (void)uploadPart:(int)index ofTotal:(int)parts fileId:(long long)fileId ogg:(NSData *)ogg
		partSize:(NSUInteger)partSize duration:(int)duration waveform:(NSData *)waveform
		service:(MTRequestMessageService *)service {
	if (index >= parts) {
		[self sendMediaWithFileId:fileId parts:parts duration:duration waveform:waveform service:service];
		return;
	}
	NSUInteger offset = (NSUInteger)index * partSize;
	NSUInteger len = MIN(partSize, ogg.length - offset);
	NSData *chunk = [ogg subdataWithRange:NSMakeRange(offset, len)];
	NSData *payload = [AYDirectSend saveFilePartWithFileId:fileId part:index chunk:chunk];
	MTRequest *req = makeRequest(payload, (int)0xb304a621, ^(id result, MTRpcError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (error) { toast(@"VOICE_SEND_FAILED"); return; }
			[self uploadPart:index + 1 ofTotal:parts fileId:fileId ogg:ogg partSize:partSize
				duration:duration waveform:waveform service:service];
		});
	});
	[service addRequest:req];
}

+ (void)sendMediaWithFileId:(long long)fileId parts:(int)parts duration:(int)duration
		waveform:(NSData *)waveform service:(MTRequestMessageService *)service {
	NSData *payload = [AYDirectSend sendVoiceWithFileId:fileId parts:parts duration:duration
		waveform:waveform randomId:randomLong() peer:currentPeerOrSelf()];
	MTRequest *req = makeRequest(payload, (int)0x0330e77f, ^(id result, MTRpcError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			toast(error ? @"VOICE_SEND_FAILED" : @"VOICE_SEND_DONE");
		});
	});
	[service addRequest:req];
}

@end
