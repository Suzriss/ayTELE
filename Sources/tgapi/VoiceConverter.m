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
@end

// Telegram voice messages are 48 kHz mono Opus.
static const double kAYVoiceSampleRate = 48000.0;
static const int kAYWaveformBars = 100;

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

+ (void)performConversion:(NSURL *)url finish:(void (^)(NSData *, NSTimeInterval, NSData *, NSError *))finish {
	Class writerClass = objc_getClass("TGOggOpusWriter");
	Class dataItemClass = objc_getClass("TGDataItem");
	if (!writerClass || !dataItemClass) {
		finish(nil, 0, nil, [self errorWithReason:@"Opus encoder unavailable"]);
		return;
	}

	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
	AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
	if (!track) {
		finish(nil, 0, nil, [self errorWithReason:@"No audio track in file"]);
		return;
	}

	NSError *readerError = nil;
	AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
	if (!reader) {
		finish(nil, 0, nil, readerError ?: [self errorWithReason:@"Cannot read file"]);
		return;
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
		finish(nil, 0, nil, [self errorWithReason:@"Unsupported audio format"]);
		return;
	}
	[reader addOutput:output];

	TGDataItem *dataItem = [[dataItemClass alloc] init];
	TGOggOpusWriter *writer = [[writerClass alloc] init];
	if (![writer beginWithDataItem:dataItem]) {
		finish(nil, 0, nil, [self errorWithReason:@"Encoder init failed"]);
		return;
	}

	// Estimate bar width so we bucket the whole clip into ~100 waveform bars.
	double durationSeconds = CMTimeGetSeconds(asset.duration);
	if (!(durationSeconds > 0)) durationSeconds = 0;
	int64_t estimatedSamples = (int64_t)(durationSeconds * kAYVoiceSampleRate);
	int64_t samplesPerBar = MAX((int64_t)1, estimatedSamples / kAYWaveformBars);

	uint16_t bars[kAYWaveformBars] = {0};
	int barIndex = 0;
	int64_t samplesInBar = 0;
	uint16_t barPeak = 0;
	uint16_t overallPeak = 0;

	if (![reader startReading]) {
		finish(nil, 0, nil, reader.error ?: [self errorWithReason:@"Read failed"]);
		return;
	}

	while (reader.status == AVAssetReaderStatusReading) {
		CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
		if (!sampleBuffer) break;
		CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
		if (blockBuffer) {
			size_t length = CMBlockBufferGetDataLength(blockBuffer);
			if (length > 0) {
				NSMutableData *pcm = [NSMutableData dataWithLength:length];
				if (CMBlockBufferCopyDataBytes(blockBuffer, 0, length, pcm.mutableBytes) == kCMBlockBufferNoErr) {
					[writer writeFrame:(uint8_t *)pcm.mutableBytes frameByteCount:length];

					// Waveform: bucket the absolute sample peaks into bars.
					const int16_t *samples = (const int16_t *)pcm.bytes;
					NSUInteger count = length / sizeof(int16_t);
					for (NSUInteger i = 0; i < count; i++) {
						uint16_t magnitude = (uint16_t)ABS((int)samples[i]);
						if (magnitude > barPeak) barPeak = magnitude;
						if (++samplesInBar >= samplesPerBar && barIndex < kAYWaveformBars) {
							bars[barIndex++] = barPeak;
							if (barPeak > overallPeak) overallPeak = barPeak;
							barPeak = 0;
							samplesInBar = 0;
						}
					}
				}
			}
		}
		CFRelease(sampleBuffer);
	}

	if (reader.status == AVAssetReaderStatusFailed) {
		finish(nil, 0, nil, reader.error ?: [self errorWithReason:@"Decoding failed"]);
		return;
	}

	// Flush a trailing partial bar.
	if (barIndex < kAYWaveformBars && (samplesInBar > 0 || barPeak > 0)) {
		bars[barIndex++] = barPeak;
		if (barPeak > overallPeak) overallPeak = barPeak;
	}

	NSData *oggData = [dataItem data];
	if (oggData.length == 0) {
		finish(nil, 0, nil, [self errorWithReason:@"Empty encoded output"]);
		return;
	}
	NSTimeInterval encodedDuration = [writer encodedDuration];
	if (!(encodedDuration > 0)) encodedDuration = durationSeconds;

	NSData *waveform = [self waveformBitstreamFromBars:bars count:barIndex peak:overallPeak];
	finish(oggData, encodedDuration, waveform, nil);
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
