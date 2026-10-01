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
	NSData *payload = [AYDirectSend sendVoiceToSelfWithFileId:fileId parts:parts duration:duration
		waveform:waveform randomId:randomLong()];
	MTRequest *req = makeRequest(payload, (int)0x0330e77f, ^(id result, MTRpcError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			toast(error ? @"VOICE_SEND_FAILED" : @"VOICE_SEND_DONE");
		});
	});
	[service addRequest:req];
}

@end
