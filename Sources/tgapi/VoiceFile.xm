#import "Headers.h"
#import <objc/runtime.h>
#import <PhotosUI/PhotosUI.h>

// Voice message from a file (kVoiceFromFile): an arrow button above the chat text field picks
// an audio/video file from Files or Photos and decodes it. The next time Telegram's own mic
// records, the file's audio goes into the recorder's Opus writer instead of the mic, so it is
// sent through Telegram's normal path as a real voice message. The waveform bars still come
// from the mic (Telegram draws them in Swift).

@interface ayTELELocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

@interface TGOggOpusWriter : NSObject
- (bool)writeFrame:(uint8_t *)framePcmBytes frameByteCount:(NSUInteger)frameByteCount;
@end

extern const void *AYVoiceOwnWriterKey;
static const void *kVoiceInjectedKey = &kVoiceInjectedKey;
static const void *kVoiceFileButtonKey = &kVoiceFileButtonKey;

static NSString *VFLoc(NSString *key) { return [ayTELELocalization localizedStringForKey:key]; }

// The decoded file waiting for the next recording, and the last one used (to send it again).
static NSData *armedPCM;
static NSData *lastPCM;
static NSHashTable<UIButton *> *voiceFileButtons;

static NSData *takeArmedPCM(void) {
	@synchronized ([UIButton class]) {
		NSData *pcm = armedPCM;
		armedPCM = nil;
		return pcm;
	}
}

static BOOL isArmed(void) {
	@synchronized ([UIButton class]) { return armedPCM != nil; }
}

static void refreshVoiceFileButton(UIButton *button) {
	BOOL armed = isArmed();
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold];
	[button setImage:[UIImage systemImageNamed:armed ? @"waveform" : @"arrow.up" withConfiguration:config] forState:UIControlStateNormal];
	button.backgroundColor = armed ? [UIColor colorWithRed:0.18 green:0.72 blue:0.35 alpha:0.95] : [UIColor colorWithRed:0.16 green:0.55 blue:0.96 alpha:0.9];
}

static void refreshAllVoiceFileButtons(void) {
	for (UIButton *button in voiceFileButtons.allObjects) refreshVoiceFileButton(button);
}

static void armPCM(NSData *pcm) {
	@synchronized ([UIButton class]) { armedPCM = pcm; }
	if (pcm) lastPCM = pcm;
	refreshAllVoiceFileButtons();
}

static UIViewController *voiceFileController(UIView *view) {
	for (UIResponder *r = view.nextResponder; r; r = r.nextResponder) {
		if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
	}
	return nil;
}

@interface AYVoiceFile : NSObject <UIDocumentPickerDelegate, PHPickerViewControllerDelegate>
@end

@implementation AYVoiceFile

+ (instancetype)shared {
	static AYVoiceFile *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [AYVoiceFile new]; });
	return shared;
}

+ (void)tapped:(UIButton *)sender {
	UIViewController *controller = voiceFileController(sender);
	if (!controller) return;
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:VFLoc(@"VOICE_FILE_TITLE") message:VFLoc(@"VOICE_FILE_HOWTO") preferredStyle:UIAlertControllerStyleActionSheet];
	AYVoiceFile *shared = [self shared];
	[sheet addAction:[UIAlertAction actionWithTitle:VFLoc(@"VOICE_FILE_FROM_FILES") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.audio", @"public.movie"] inMode:UIDocumentPickerModeImport];
		picker.delegate = shared;
		[controller presentViewController:picker animated:YES completion:nil];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:VFLoc(@"VOICE_FILE_FROM_PHOTOS") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		PHPickerConfiguration *config = [PHPickerConfiguration new];
		config.filter = [PHPickerFilter videosFilter];
		config.selectionLimit = 1;
		PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
		picker.delegate = shared;
		[controller presentViewController:picker animated:YES completion:nil];
	}]];
	if (lastPCM && !isArmed()) {
		[sheet addAction:[UIAlertAction actionWithTitle:VFLoc(@"VOICE_FILE_AGAIN") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
			armPCM(lastPCM);
			AYPresentToast(VFLoc(@"VOICE_FILE_READY"));
		}]];
	}
	if (isArmed()) {
		[sheet addAction:[UIAlertAction actionWithTitle:VFLoc(@"VOICE_FILE_DISARM") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
			armPCM(nil);
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:VFLoc(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
	sheet.popoverPresentationController.sourceView = sender;
	sheet.popoverPresentationController.sourceRect = sender.bounds;
	[controller presentViewController:sheet animated:YES completion:nil];
}

- (void)prepareURL:(NSURL *)url cleanup:(BOOL)cleanup {
	AYPresentToast(VFLoc(@"VOICE_CONVERTING"));
	[AYVoiceConverter decodeURL:url completion:^(NSData *pcm, NSError *error) {
		if (cleanup) [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
		if (!pcm) {
			AYPresentToast([NSString stringWithFormat:@"%@: %@", VFLoc(@"VOICE_CONVERT_FAILED"), error.localizedDescription ?: @""]);
			return;
		}
		armPCM(pcm);
		AYPresentToast(VFLoc(@"VOICE_FILE_READY"));
	}];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSURL *url = urls.firstObject;
	if (url) [self prepareURL:url cleanup:NO];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
	[picker dismissViewControllerAnimated:YES completion:nil];
	NSItemProvider *provider = results.firstObject.itemProvider;
	if (!provider) return;
	[provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *error) {
		// The file is deleted when this handler returns, so keep a copy.
		NSURL *copy = nil;
		if (url) {
			copy = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSString stringWithFormat:@"ayTELE-voice-%@.%@", [NSUUID UUID].UUIDString, url.pathExtension.length ? url.pathExtension : @"mov"]];
			if (![[NSFileManager defaultManager] copyItemAtURL:url toURL:copy error:&error]) copy = nil;
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (copy) {
				[self prepareURL:copy cleanup:YES];
			} else {
				AYPresentToast([NSString stringWithFormat:@"%@: %@", VFLoc(@"VOICE_CONVERT_FAILED"), error.localizedDescription ?: @""]);
			}
		});
	}];
}

@end

// Places (or removes) the arrow just above the text field, left of the dictation mic if that's on.
void AYUpdateVoiceFileButton(UITextView *textView, Class chatControllerClass) {
	UIButton *button = objc_getAssociatedObject(textView, kVoiceFileButtonKey);
	BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kVoiceFromFile];
	UIViewController *controller = (enabled && textView.window) ? voiceFileController(textView) : nil;
	if (controller && chatControllerClass && ![controller isKindOfClass:chatControllerClass]) controller = nil;
	if (!controller || textView.hidden || textView.bounds.size.width < 40) {
		[button removeFromSuperview];
		return;
	}
	if (!button) {
		button = [UIButton buttonWithType:UIButtonTypeCustom];
		button.tintColor = [UIColor whiteColor];
		button.bounds = CGRectMake(0, 0, 34, 34);
		button.layer.cornerRadius = 17;
		button.layer.zPosition = 1000;
		button.layer.shadowColor = [UIColor blackColor].CGColor;
		button.layer.shadowOpacity = 0.25;
		button.layer.shadowRadius = 4;
		button.layer.shadowOffset = CGSizeMake(0, 2);
		button.accessibilityLabel = VFLoc(@"VOICE_FILE_TITLE");
		[button addTarget:[AYVoiceFile class] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
		objc_setAssociatedObject(textView, kVoiceFileButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[voiceFileButtons addObject:button];
		refreshVoiceFileButton(button);
	}
	UIView *host = controller.view;
	if (button.superview != host) [host addSubview:button];
	CGRect field = [textView convertRect:textView.bounds toView:host];
	CGFloat size = button.bounds.size.width;
	CGFloat x = MIN(CGRectGetMaxX(field) - size / 2, host.bounds.size.width - size / 2 - 8);
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kSpeechToText]) x -= size + 10;
	CGFloat y = CGRectGetMinY(field) - size / 2 - 14;
	button.center = CGPointMake(x, y);
	[host bringSubviewToFront:button];
}

%group VoiceFile
%hook TGOggOpusWriter
// Telegram's recorder calls this with one 20 ms mic frame at a time, and NULL to finish.
- (bool)writeFrame:(uint8_t *)framePcmBytes frameByteCount:(NSUInteger)frameByteCount {
	if (!framePcmBytes || objc_getAssociatedObject(self, AYVoiceOwnWriterKey)) return %orig;
	if (objc_getAssociatedObject(self, kVoiceInjectedKey)) return true; // the file is in; drop the mic
	NSData *pcm = takeArmedPCM();
	if (!pcm) return %orig;
	objc_setAssociatedObject(self, AYVoiceOwnWriterKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	BOOL ok = [AYVoiceConverter writePCM:pcm toWriter:self];
	objc_setAssociatedObject(self, AYVoiceOwnWriterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(self, kVoiceInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	dispatch_async(dispatch_get_main_queue(), ^{
		refreshAllVoiceFileButtons();
		AYPresentToast(VFLoc(ok ? @"VOICE_FILE_INSERTED" : @"VOICE_CONVERT_FAILED"));
	});
	return ok;
}
%end
%end

%ctor {
	Class writer = objc_getClass("TGOggOpusWriter");
	if (!writer) return;
	voiceFileButtons = [NSHashTable weakObjectsHashTable];
	%init(VoiceFile, TGOggOpusWriter = writer);
}
