#import "Headers.h"
#import <objc/runtime.h>

// Sends a voice message without the mic, the way iQTele does: upload the OGG/Opus bytes with
// upload.saveFilePart, then messages.sendMedia carrying a voice document. The payloads come from
// AYDirectSend (Swift, layer-229 exact); we issue them as real MTRequests through the live
// MTRequestMessageService captured from our existing addRequest: hook. The note is sent to the
// chat the user is in (matched by key via AYPeerForChatKey), falling back to Saved Messages.

void AYPresentToast(NSString *message);
@interface ayTELELocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

static __weak MTRequestMessageService *gService;
static __weak MTRequestMessageService *gHomeService;

void AYCaptureRequestService(MTRequestMessageService *service) {
	if (service) gService = service;
}

// The service that carries getHistory/sendMessage — i.e. the account's home datacenter. Our
// upload+sendMedia must ride this one; a download/CDN service gives back 303 USER_MIGRATE_X.
void AYCaptureHomeService(MTRequestMessageService *service) {
	if (service) gHomeService = service;
}

// Prefer the pinned home-DC service; fall back to the most recent one only if we never saw it.
static MTRequestMessageService *activeService(void) {
	return gHomeService ?: gService;
}

// InputPeers sniffed from outgoing getHistory/readHistory/sendMessage requests (peer is the first
// field, after a 4-byte flags word for sendMessage). We keep the most recent one AND one per chat
// keyed by "u<id>"/"g<id>"/"c<id>", so a voice note can target the exact chat the user is in instead
// of whichever getHistory fired last (background sync fires getHistory for other peers too).
static NSData *gCurrentPeer;
static NSTimeInterval gCurrentPeerTime;
static NSMutableDictionary<NSString *, NSData *> *gPeerByKey;

// Normalized chat key for a raw InputPeer (ctor + body), matching AYReceipts' keys. nil for self.
static NSString *keyForInputPeer(NSData *peer) {
	if (peer.length < 4) return nil;
	uint32_t ctor = 0;
	[peer getBytes:&ctor length:4];
	if (peer.length < 12) return nil;        // need an 8-byte id after the ctor
	long long pid = 0;
	[peer getBytes:&pid range:NSMakeRange(4, 8)];
	switch (ctor) {
		case 0x35a95cb9: return [NSString stringWithFormat:@"g%lld", pid]; // inputPeerChat
		case 0xdde8a54c: return [NSString stringWithFormat:@"u%lld", pid]; // inputPeerUser
		case 0x27bcbbfc: return [NSString stringWithFormat:@"c%lld", pid]; // inputPeerChannel
		default: return nil;
	}
}

void AYCaptureOutgoingPeer(NSData *payload) {
	if (payload.length < 8) return;
	uint32_t fid = 0;
	[payload getBytes:&fid length:4];
	// Where the InputPeer starts in the payload: right after the function id, plus a 4-byte flags
	// word for sendMessage (whose peer follows flags).
	NSUInteger peerOffset;
	if (fid == 0x4423e6c5 /* messages.getHistory */ || fid == 0x0e306d3a /* messages.readHistory */) {
		peerOffset = 4;
	} else if (fid == 0xfef48f62 /* messages.sendMessage: flags(4) then peer */) {
		peerOffset = 8;
	} else {
		return;
	}
	if (payload.length < peerOffset + 4) return;
	uint32_t ctor = 0;
	[payload getBytes:&ctor range:NSMakeRange(peerOffset, 4)];
	NSUInteger len;
	switch (ctor) {
		case 0x7da07ec9: len = 4; break;   // inputPeerSelf
		case 0x35a95cb9: len = 12; break;  // inputPeerChat
		case 0xdde8a54c: len = 20; break;  // inputPeerUser
		case 0x27bcbbfc: len = 20; break;  // inputPeerChannel
		default: return;
	}
	if (payload.length < peerOffset + len) return;
	NSData *peer = [payload subdataWithRange:NSMakeRange(peerOffset, len)];
	gCurrentPeer = peer;
	gCurrentPeerTime = [NSDate date].timeIntervalSince1970;
	NSString *key = keyForInputPeer(peer);
	if (key) {
		if (!gPeerByKey) gPeerByKey = [NSMutableDictionary dictionary];
		if (![gPeerByKey[key] isEqualToData:peer]) customLog(@"peer: learned %@ (%lu bytes, fn 0x%08x)", key, (unsigned long)peer.length, fid);
		gPeerByKey[key] = peer;
	}
}

// The captured peer if it's fresh enough, else inputPeerSelf (Saved Messages) as a safe fallback.
static NSData *currentPeerOrSelf(void) {
	if (gCurrentPeer && ([NSDate date].timeIntervalSince1970 - gCurrentPeerTime) < 3600) return gCurrentPeer;
	uint32_t self = 0x7da07ec9;  // inputPeerSelf
	return [NSData dataWithBytes:&self length:4];
}

NSData *AYPeerForChatKey(NSString *key) {
	return key ? gPeerByKey[key] : nil;
}

static void toast(NSString *key) {
	AYPresentToast([ayTELELocalization localizedStringForKey:key]);
}

// Files above this must use upload.saveBigFilePart + inputFileBig (Telegram's 10 MB rule).
static const NSUInteger kAYBigFileThreshold = 10 * 1024 * 1024;

static long long randomLong(void) {
	return ((long long)arc4random() << 32) | (long long)arc4random();
}

// Names the server's reply to messages.sendMedia and says whether it actually carries a new
// message. The completion only gets raw TL bytes (our responseParser passes them straight through),
// so without reading the constructor here a silently-empty `updates` looks the same as a real send.
// updateMessageID / updateNewMessage / updateShortSentMessage are the markers that a message was
// truly created; their absence means the server accepted the call but produced nothing.
static NSString *describeSendMediaResponse(NSData *resp) {
	if (resp.length < 4) return [NSString stringWithFormat:@"empty (%lu bytes)", (unsigned long)resp.length];
	uint32_t ctor = 0; [resp getBytes:&ctor length:4];
	const char *name = "?";
	switch (ctor) {
		case 0x74ae4240: name = "updates"; break;
		case 0x725b04c3: name = "updatesCombined"; break;
		case 0x78d4dec1: name = "updateShort"; break;
		case 0xe317af7e: name = "updatesTooLong"; break;
		case 0x9015e101: name = "updateShortSentMessage"; break;
		case 0x313bc7f8: name = "updateShortMessage"; break;
		case 0x4d6deea5: name = "updateShortChatMessage"; break;
		case 0xf35c6d01: name = "rpc_error?"; break;
	}
	// Scan for a new-message / sent-message update ctor anywhere in the reply. These ids are
	// distinctive enough that a false hit in a short reply is unlikely.
	BOOL hasMsg = (ctor == 0x9015e101 /* updateShortSentMessage is itself the proof */);
	const uint8_t *b = (const uint8_t *)resp.bytes;
	for (NSUInteger i = 0; !hasMsg && i + 4 <= resp.length; i++) {
		uint32_t w = (uint32_t)b[i] | ((uint32_t)b[i+1] << 8) | ((uint32_t)b[i+2] << 16) | ((uint32_t)b[i+3] << 24);
		if (w == 0x1f2b0afd /* updateNewMessage */ || w == 0x62ba04d9 /* updateNewChannelMessage */ ||
		    w == 0x4e90bfd6 /* updateMessageID */) { hasMsg = YES; break; }
	}
	return [NSString stringWithFormat:@"%s(0x%08x) len=%lu newMsg=%@", name, ctor,
		(unsigned long)resp.length, hasMsg ? @"YES" : @"NO"];
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
	MTRequestMessageService *service = activeService();
	if (!service || payload.length == 0) return NO;
	[service addRequest:makeRequest(payload, functionId, completed)];
	return YES;
}

NSData *AYCurrentPeerOrSelf(void) { return currentPeerOrSelf(); }

@implementation AYVoiceSend

+ (void)sendOGG:(NSData *)ogg duration:(int)duration waveform:(NSData *)waveform chatKey:(NSString *)chatKey {
	MTRequestMessageService *service = activeService();
	if (ogg.length == 0 || !service) {
		customLog(@"voice: cannot send (ogg=%lu bytes, service=%@)", (unsigned long)ogg.length, service ? @"yes" : @"none captured yet");
		toast(@"VOICE_SEND_FAILED");
		return;
	}
	// Prefer the InputPeer captured for this exact chat; fall back to the most recent chat, then self.
	NSData *exact = AYPeerForChatKey(chatKey);
	NSData *peer = exact ?: currentPeerOrSelf();
	customLog(@"voice: sending %lu bytes, %ds, chat=%@ -> %@ (%@), known chats=%lu", (unsigned long)ogg.length, duration,
		chatKey ?: @"?", keyForInputPeer(peer) ?: @"self", exact ? @"exact" : (peer.length > 4 ? @"latest chat" : @"Saved Messages fallback"),
		(unsigned long)gPeerByKey.count);
	long long fileId = randomLong();
	NSUInteger partSize = 512 * 1024;
	int parts = (int)((ogg.length + partSize - 1) / partSize);
	[self uploadPart:0 ofTotal:parts fileId:fileId ogg:ogg partSize:partSize
		duration:duration waveform:waveform peer:peer service:service];
}

+ (void)uploadPart:(int)index ofTotal:(int)parts fileId:(long long)fileId ogg:(NSData *)ogg
		partSize:(NSUInteger)partSize duration:(int)duration waveform:(NSData *)waveform
		peer:(NSData *)peer service:(MTRequestMessageService *)service {
	if (index >= parts) {
		[self sendMediaWithFileId:fileId parts:parts big:ogg.length > kAYBigFileThreshold duration:duration
			waveform:waveform peer:peer service:service];
		return;
	}
	NSUInteger offset = (NSUInteger)index * partSize;
	NSUInteger len = MIN(partSize, ogg.length - offset);
	NSData *chunk = [ogg subdataWithRange:NSMakeRange(offset, len)];
	// Telegram rejects saveFilePart for files over 10 MB; those go up as a "big" file instead.
	BOOL big = ogg.length > kAYBigFileThreshold;
	NSData *payload = big
		? [AYDirectSend saveBigFilePartWithFileId:fileId part:index totalParts:parts chunk:chunk]
		: [AYDirectSend saveFilePartWithFileId:fileId part:index chunk:chunk];
	MTRequest *req = makeRequest(payload, big ? (int)0xde7b673d : (int)0xb304a621, ^(id result, MTRpcError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (error) {
				customLog(@"voice: upload part %d/%d failed: %@", index + 1, parts, error);
				toast(@"VOICE_SEND_FAILED");
				return;
			}
			[self uploadPart:index + 1 ofTotal:parts fileId:fileId ogg:ogg partSize:partSize
				duration:duration waveform:waveform peer:peer service:service];
		});
	});
	[service addRequest:req];
}

+ (void)sendMediaWithFileId:(long long)fileId parts:(int)parts big:(BOOL)big duration:(int)duration
		waveform:(NSData *)waveform peer:(NSData *)peer service:(MTRequestMessageService *)service {
	NSData *payload = [AYDirectSend sendVoiceWithFileId:fileId parts:parts big:big duration:duration
		waveform:waveform randomId:randomLong() peer:(peer ?: currentPeerOrSelf())];
	MTRequest *req = makeRequest(payload, (int)0x0330e77f, ^(id result, MTRpcError *error) {
		NSData *resp = [result isKindOfClass:[NSData class]] ? result : nil;
		NSString *desc = error ? nil : describeSendMediaResponse(resp);
		dispatch_async(dispatch_get_main_queue(), ^{
			if (error) customLog(@"voice: sendMedia failed: %@", error);
			else customLog(@"voice: sendMedia reply %@ (%d part(s))", desc, parts);
			// Only call it a success when the server's reply actually carries a new message; an
			// accepted-but-empty reply means nothing was created, so tell the user it failed.
			BOOL created = !error && [desc hasSuffix:@"newMsg=YES"];
			toast(created ? @"VOICE_SEND_DONE" : @"VOICE_SEND_FAILED");
		});
	});
	[service addRequest:req];
}

@end
