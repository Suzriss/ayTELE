#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// Converts any audio/video file into a Telegram voice message: OGG/Opus data + duration + waveform.
// Uses Telegram's own LegacyComponents encoders (present in TelegramUIFramework at runtime), fed
// 48 kHz mono 16-bit PCM decoded from the source with AVAssetReader.

// --- Telegram runtime classes (signatures verified from the app binary) ---
@interface TGDataItem : NSObject
- (instancetype)init;
- (void)appendData:(NSData *)data;
- (NSData *)data;
@end

@interface TGOggOpusWriter : NSObject
- (instancetype)init;
- (bool)beginWithDataItem:(TGDataItem *)dataItem;
- (bool)writeFrame:(uint8_t *)framePcmBytes frameByteCount:(NSUInteger)frameByteCount;
- (NSUInteger)encodedBytes;
- (NSTimeInterval)encodedDuration;
@end

@interface TGAudioWaveform : NSObject
- (instancetype)initWithSamples:(NSData *)samples peak:(int32_t)peak;
- (NSData *)bitstream;
@end

@interface AYVoiceConverter : NSObject
// oggOpusData: the encoded voice file; duration: seconds; waveform: 5-bit bitstream for the
// documentAttributeAudio waveform field. Any failure returns a non-nil error.
+ (void)convertURL:(NSURL *)url
        completion:(void (^)(NSData *oggOpusData, NSTimeInterval duration, NSData *waveform, NSError *error))completion;
+ (void)decodeURL:(NSURL *)url completion:(void (^)(NSData *pcm, NSError *error))completion;
+ (BOOL)writePCM:(NSData *)pcm toWriter:(TGOggOpusWriter *)writer;
@end

// Telegram voice messages are 48 kHz mono Opus.
static const double kAYVoiceSampleRate = 48000.0;
static const int kAYWaveformBars = 100;
#define kAYVoiceFrameSamples 960

// Marks writers that are ours, so the voice-file hook never feeds them a file.
const void *AYVoiceOwnWriterKey = &AYVoiceOwnWriterKey;

@implementation AYVoiceConverter

+ (NSError *)errorWithReason:(NSString *)reason {
	return [NSError errorWithDomain:@"ayTELE.VoiceConverter" code:1 userInfo:@{NSLocalizedDescriptionKey: reason ?: @"conversion failed"}];
}

+ (void)convertURL:(NSURL *)url
        completion:(void (^)(NSData *, NSTimeInterval, NSData *, NSError *))completion {
	void (^finish)(NSData *, NSTimeInterval, NSData *, NSError *) = ^(NSData *data, NSTimeInterval dur, NSData *wave, NSError *err) {
		dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(data, dur, wave, err); });
	};
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		@autoreleasepool {
			[self performConversion:url finish:finish];
		}
	});
}

// Decodes the first audio track of url to 48 kHz mono 16-bit PCM.
+ (NSData *)decodePCMFromURL:(NSURL *)url error:(NSError **)error {
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
	AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
	if (!track) {
		*error = [self errorWithReason:@"No audio track in file"];
		return nil;
	}
	NSError *readerError = nil;
	AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
	if (!reader) {
		*error = readerError ?: [self errorWithReason:@"Cannot read file"];
		return nil;
	}
	NSDictionary *settings = @{
		AVFormatIDKey: @(kAudioFormatLinearPCM),
		AVSampleRateKey: @(kAYVoiceSampleRate),
		AVNumberOfChannelsKey: @1,
		AVLinearPCMBitDepthKey: @16,
		AVLinearPCMIsFloatKey: @NO,
		AVLinearPCMIsBigEndianKey: @NO,
		AVLinearPCMIsNonInterleaved: @NO,
	};
	AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
	output.alwaysCopiesSampleData = NO;
	if (![reader canAddOutput:output]) {
		*error = [self errorWithReason:@"Unsupported audio format"];
		return nil;
	}
	[reader addOutput:output];
	if (![reader startReading]) {
		*error = reader.error ?: [self errorWithReason:@"Read failed"];
		return nil;
	}
	NSMutableData *pcm = [NSMutableData data];
	while (reader.status == AVAssetReaderStatusReading) {
		CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
		if (!sampleBuffer) break;
		CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
		size_t length = blockBuffer ? CMBlockBufferGetDataLength(blockBuffer) : 0;
		if (length > 0) {
			NSUInteger start = pcm.length;
			[pcm increaseLengthBy:length];
			if (CMBlockBufferCopyDataBytes(blockBuffer, 0, length, (uint8_t *)pcm.mutableBytes + start) != kCMBlockBufferNoErr) {
				pcm.length = start;
			}
		}
		CFRelease(sampleBuffer);
	}
	if (reader.status == AVAssetReaderStatusFailed) {
		*error = reader.error ?: [self errorWithReason:@"Decoding failed"];
		return nil;
	}
	if (pcm.length < 2) {
		*error = [self errorWithReason:@"No audio in file"];
		return nil;
	}
	return pcm;
}

+ (void)decodeURL:(NSURL *)url completion:(void (^)(NSData *pcm, NSError *error))completion {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		@autoreleasepool {
			NSError *error = nil;
			NSData *pcm = [self decodePCMFromURL:url error:&error];
			dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(pcm, error); });
		}
	});
}

+ (void)performConversion:(NSURL *)url finish:(void (^)(NSData *, NSTimeInterval, NSData *, NSError *))finish {
	Class writerClass = objc_getClass("TGOggOpusWriter");
	Class dataItemClass = objc_getClass("TGDataItem");
	if (!writerClass || !dataItemClass) {
		finish(nil, 0, nil, [self errorWithReason:@"Opus encoder unavailable"]);
		return;
	}
	NSError *error = nil;
	NSData *pcm = [self decodePCMFromURL:url error:&error];
	if (!pcm) {
		finish(nil, 0, nil, error);
		return;
	}

	TGDataItem *dataItem = [[dataItemClass alloc] init];
	TGOggOpusWriter *writer = [[writerClass alloc] init];
	objc_setAssociatedObject(writer, AYVoiceOwnWriterKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	if (![writer beginWithDataItem:dataItem]) {
		finish(nil, 0, nil, [self errorWithReason:@"Encoder init failed"]);
		return;
	}
	if (![self writePCM:pcm toWriter:writer]) {
		finish(nil, 0, nil, [self errorWithReason:@"Encoding failed"]);
		return;
	}
	[writer writeFrame:NULL frameByteCount:0]; // end of stream, as Telegram's recorder does

	NSData *oggData = [dataItem data];
	if (oggData.length == 0) {
		finish(nil, 0, nil, [self errorWithReason:@"Empty encoded output"]);
		return;
	}
	NSTimeInterval encodedDuration = [writer encodedDuration];
	if (!(encodedDuration > 0)) encodedDuration = pcm.length / 2 / kAYVoiceSampleRate;
	finish(oggData, encodedDuration, [self waveformFromPCM:pcm], nil);
}

// The writer encodes exactly one 20 ms frame (960 samples at 48 kHz) per call, and a shorter
// frame marks the end of the stream, so feed whole frames and zero-pad the last one.
+ (BOOL)writePCM:(NSData *)pcm toWriter:(TGOggOpusWriter *)writer {
	const NSUInteger frameBytes = kAYVoiceFrameSamples * 2;
	const uint8_t *bytes = pcm.bytes;
	uint8_t padded[kAYVoiceFrameSamples * 2];
	for (NSUInteger offset = 0; offset < pcm.length; offset += frameBytes) {
		NSUInteger count = MIN(frameBytes, pcm.length - offset);
		const uint8_t *frame = bytes + offset;
		if (count < frameBytes) {
			memset(padded, 0, frameBytes);
			memcpy(padded, frame, count);
			frame = padded;
		}
		if (![writer writeFrame:(uint8_t *)frame frameByteCount:frameBytes]) return NO;
	}
	return YES;
}

// Telegram's 5-bit waveform: the peak of each of 100 equal slices.
+ (NSData *)waveformFromPCM:(NSData *)pcm {
	const int16_t *samples = pcm.bytes;
	NSUInteger count = pcm.length / 2;
	uint16_t bars[kAYWaveformBars] = {0};
	uint16_t peak = 0;
	for (NSUInteger i = 0; i < count; i++) {
		int bar = (int)(i * kAYWaveformBars / count);
		uint16_t magnitude = (uint16_t)ABS((int)samples[i]);
		if (magnitude > bars[bar]) bars[bar] = magnitude;
		if (magnitude > peak) peak = magnitude;
	}
	return [self waveformBitstreamFromBars:bars count:kAYWaveformBars peak:peak];
}

// Packs per-bar peaks into Telegram's 5-bit waveform bitstream via TGAudioWaveform.
+ (NSData *)waveformBitstreamFromBars:(uint16_t *)bars count:(int)count peak:(uint16_t)peak {
	Class waveformClass = objc_getClass("TGAudioWaveform");
	if (!waveformClass || count <= 0 || peak == 0) return nil;
	NSData *samples = [NSData dataWithBytes:bars length:count * sizeof(uint16_t)];
	TGAudioWaveform *waveform = [[waveformClass alloc] initWithSamples:samples peak:(int32_t)peak];
	return [waveform bitstream];
}

@end
