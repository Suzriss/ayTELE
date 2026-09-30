#import "Headers.h"
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

// Dictation button for the chat text field (kSpeechToText): a small mic floats just above the
// trailing end of ChatInputTextView inside a chat. Tap to listen, tap again (or pause) to stop;
// the recognized text is inserted into the field. Long-press picks the recognition language.
// Telegram's Info.plist already carries the microphone and speech-recognition usage strings.

@interface ayTELELocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

// The mic button; holds its text view weakly (the text view owns the button).
@interface AYSpeechButton : UIButton
@property (nonatomic, weak) UITextView *textView;
@end
@implementation AYSpeechButton
@end

static Class chatControllerClass;
static const void *kSpeechButtonKey = &kSpeechButtonKey;

static NSString *AYLoc(NSString *key) { return [ayTELELocalization localizedStringForKey:key]; }

static UIViewController *owningController(UIView *view) {
	for (UIResponder *r = view.nextResponder; r; r = r.nextResponder) {
		if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
	}
	return nil;
}

// Stored choice, else Arabic when the device prefers Arabic, else the device locale.
static NSString *speechLocale(void) {
	NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kSpeechLocale];
	if (saved.length) return saved;
	NSString *preferred = NSLocale.preferredLanguages.firstObject ?: @"en-US";
	if ([preferred hasPrefix:@"ar"]) return @"ar-SA";
	return preferred;
}

@interface AYSpeechInput : NSObject
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *request;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, weak) UITextView *textView;
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, strong) UILabel *liveLabel;
@property (nonatomic, copy) NSString *transcript;
@property (nonatomic, strong) NSTimer *silenceTimer;
@property (nonatomic, copy) NSString *previousCategory;
@property (nonatomic, copy) NSString *previousMode;
@property (nonatomic) AVAudioSessionCategoryOptions previousOptions;
@property (nonatomic, readonly) BOOL listening;
+ (instancetype)shared;
- (void)finish;
- (void)relayoutLive;
@end

@implementation AYSpeechInput

+ (instancetype)shared {
	static AYSpeechInput *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [AYSpeechInput new]; });
	return shared;
}

- (BOOL)listening { return self.engine != nil; }

+ (void)tapped:(UIButton *)sender {
	AYSpeechInput *speech = [self shared];
	if (speech.listening) {
		[speech finish];
		return;
	}
	UITextView *textView = [sender isKindOfClass:[AYSpeechButton class]] ? ((AYSpeechButton *)sender).textView : nil;
	if (!textView) return;
	[speech authorizeThen:^{ [speech startWithTextView:textView button:sender]; }];
}

+ (void)longPressed:(UILongPressGestureRecognizer *)press {
	if (press.state != UIGestureRecognizerStateBegan) return;
	UIViewController *controller = owningController(press.view);
	if (!controller) return;
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:AYLoc(@"SPEECH_LANGUAGE_TITLE") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
	NSString *current = speechLocale();
	NSMutableOrderedSet<NSString *> *codes = [NSMutableOrderedSet orderedSetWithArray:@[@"ar-SA", @"en-US"]];
	NSString *device = NSLocale.preferredLanguages.firstObject;
	if (device) [codes addObject:device];
	NSSet *supported = [SFSpeechRecognizer.supportedLocales valueForKey:@"localeIdentifier"];
	for (NSString *code in codes) {
		NSString *normalized = [code stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
		if (supported.count && ![supported containsObject:normalized] && ![supported containsObject:[normalized stringByReplacingOccurrencesOfString:@"-" withString:@"_"]]) continue;
		NSString *name = [[NSLocale currentLocale] localizedStringForLocaleIdentifier:normalized] ?: normalized;
		if ([normalized isEqualToString:current]) name = [@"✓ " stringByAppendingString:name];
		[sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
			[[NSUserDefaults standardUserDefaults] setObject:normalized forKey:kSpeechLocale];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:AYLoc(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
	sheet.popoverPresentationController.sourceView = press.view;
	sheet.popoverPresentationController.sourceRect = press.view.bounds;
	[controller presentViewController:sheet animated:YES completion:nil];
}

- (void)authorizeThen:(void (^)(void))then {
	void (^denied)(void) = ^{ AYPresentToast(AYLoc(@"SPEECH_DENIED")); };
	[SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) { denied(); return; }
			[[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
				dispatch_async(dispatch_get_main_queue(), ^{
					if (granted) then(); else denied();
				});
			}];
		});
	}];
}

- (void)startWithTextView:(UITextView *)textView button:(UIButton *)button {
	SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:speechLocale()]];
	if (!recognizer || !recognizer.isAvailable) {
		AYPresentToast(AYLoc(@"SPEECH_UNAVAILABLE"));
		return;
	}

	AVAudioSession *session = [AVAudioSession sharedInstance];
	self.previousCategory = session.category;
	self.previousMode = session.mode;
	self.previousOptions = session.categoryOptions;
	NSError *error = nil;
	[session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeMeasurement options:AVAudioSessionCategoryOptionDuckOthers | AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth error:&error];
	if (!error) [session setActive:YES withOptions:0 error:&error];
	if (error) {
		customLog2(@"Speech input: audio session failed: %@", error);
		[self restoreSession];
		AYPresentToast(AYLoc(@"SPEECH_UNAVAILABLE"));
		return;
	}

	SFSpeechAudioBufferRecognitionRequest *request = [SFSpeechAudioBufferRecognitionRequest new];
	request.shouldReportPartialResults = YES;
	AVAudioEngine *engine = [AVAudioEngine new];
	AVAudioInputNode *input = engine.inputNode;
	AVAudioFormat *format = [input outputFormatForBus:0];
	if (format.sampleRate <= 0 || format.channelCount == 0) {
		[self restoreSession];
		AYPresentToast(AYLoc(@"SPEECH_UNAVAILABLE"));
		return;
	}
	[input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
		[request appendAudioPCMBuffer:buffer];
	}];
	[engine prepare];
	if (![engine startAndReturnError:&error]) {
		customLog2(@"Speech input: engine failed: %@", error);
		[input removeTapOnBus:0];
		[self restoreSession];
		AYPresentToast(AYLoc(@"SPEECH_UNAVAILABLE"));
		return;
	}

	self.engine = engine;
	self.recognizer = recognizer;
	self.request = request;
	self.textView = textView;
	self.button = button;
	self.transcript = @"";
	[self setButtonListening:YES];
	[self showLive:AYLoc(@"SPEECH_LISTENING")];
	[self armSilenceTimer:8.0]; // give up if nothing is heard at all

	__weak AYSpeechInput *weakSelf = self;
	self.task = [recognizer recognitionTaskWithRequest:request resultHandler:^(SFSpeechRecognitionResult *result, NSError *taskError) {
		dispatch_async(dispatch_get_main_queue(), ^{
			AYSpeechInput *strongSelf = weakSelf;
			if (!strongSelf || strongSelf.request != request) return;
			if (result) {
				strongSelf.transcript = result.bestTranscription.formattedString ?: @"";
				if (strongSelf.transcript.length) [strongSelf showLive:strongSelf.transcript];
				[strongSelf armSilenceTimer:2.0]; // stop after a pause in speech
			}
			if (result.isFinal || taskError) [strongSelf finish];
		});
	}];
}

- (void)armSilenceTimer:(NSTimeInterval)seconds {
	[self.silenceTimer invalidate];
	__weak AYSpeechInput *weakSelf = self;
	self.silenceTimer = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:NO block:^(NSTimer *timer) {
		[weakSelf finish];
	}];
}

// Stops listening and inserts whatever was recognized.
- (void)finish {
	if (!self.listening) return;
	[self.silenceTimer invalidate];
	self.silenceTimer = nil;
	[self.engine stop];
	[self.engine.inputNode removeTapOnBus:0];
	[self.request endAudio];
	[self.task cancel];
	self.engine = nil;
	self.request = nil;
	self.task = nil;
	self.recognizer = nil;
	[self restoreSession];
	[self setButtonListening:NO];
	[self hideLive];

	NSString *text = [self.transcript stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	self.transcript = nil;
	UITextView *textView = self.textView;
	if (text.length == 0) {
		AYPresentToast(AYLoc(@"SPEECH_NOTHING"));
		return;
	}
	if (!textView.window) return;
	// Separate from text already before the cursor.
	NSRange selection = textView.selectedRange;
	NSString *existing = textView.text ?: @"";
	if (selection.location != NSNotFound && selection.location > 0 && selection.location <= existing.length) {
		unichar before = [existing characterAtIndex:selection.location - 1];
		if (![NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:before]) text = [@" " stringByAppendingString:text];
	}
	if (!textView.isFirstResponder) [textView becomeFirstResponder];
	// insertText: goes through UITextInput, so Telegram's delegate sees an ordinary edit.
	[textView insertText:text];
}

- (void)restoreSession {
	AVAudioSession *session = [AVAudioSession sharedInstance];
	NSError *error = nil;
	[session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
	if (self.previousCategory) {
		[session setCategory:self.previousCategory mode:self.previousMode ?: AVAudioSessionModeDefault options:self.previousOptions error:&error];
	}
	self.previousCategory = nil;
	self.previousMode = nil;
}

- (void)setButtonListening:(BOOL)listening {
	UIButton *button = self.button;
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
	[button setImage:[UIImage systemImageNamed:listening ? @"stop.fill" : @"mic.fill" withConfiguration:config] forState:UIControlStateNormal];
	button.backgroundColor = listening ? [UIColor systemRedColor] : [UIColor colorWithRed:0.16 green:0.55 blue:0.96 alpha:0.9];
}

// Live transcript bubble just above the button while listening.
- (void)showLive:(NSString *)text {
	UIButton *button = self.button;
	UIView *host = button.superview;
	if (!host) return;
	if (!self.liveLabel) {
		UILabel *label = [UILabel new];
		label.textColor = [UIColor whiteColor];
		label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
		label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
		label.numberOfLines = 3;
		label.textAlignment = NSTextAlignmentNatural;
		label.layer.cornerRadius = 12;
		label.clipsToBounds = YES;
		label.layer.zPosition = 1000;
		label.userInteractionEnabled = NO;
		self.liveLabel = label;
	}
	UILabel *label = self.liveLabel;
	if (label.superview != host) [host addSubview:label];
	label.text = [NSString stringWithFormat:@"  %@  ", text];
	CGFloat maxW = MIN(host.bounds.size.width - 32, 420);
	CGSize fit = [label sizeThatFits:CGSizeMake(maxW, 200)];
	CGFloat w = MIN(maxW, fit.width + 8);
	CGFloat h = fit.height + 12;
	CGFloat x = MAX(16, MIN(CGRectGetMaxX(button.frame) - w, host.bounds.size.width - 16 - w));
	label.frame = CGRectMake(x, CGRectGetMinY(button.frame) - h - 8, w, h);
	[host bringSubviewToFront:label];
}

- (void)relayoutLive {
	if (self.liveLabel.superview && self.liveLabel.text.length) [self showLive:[self.liveLabel.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
}

- (void)hideLive {
	[self.liveLabel removeFromSuperview];
}

@end

static NSHashTable<UITextView *> *speechTextViews;

// Places (or removes) the mic for this text view. It lives on the chat controller's root view,
// so the input panel doesn't clip it or swallow its touches, just above the field's trailing end.
static void updateSpeechButton(UITextView *textView) {
	AYSpeechButton *button = objc_getAssociatedObject(textView, kSpeechButtonKey);
	BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kSpeechToText];
	UIViewController *controller = (enabled && textView.window) ? owningController(textView) : nil;
	if (controller && chatControllerClass && ![controller isKindOfClass:chatControllerClass]) controller = nil;
	if (!controller || textView.hidden || textView.bounds.size.width < 40) {
		if ([AYSpeechInput shared].textView == textView) [[AYSpeechInput shared] finish];
		[button removeFromSuperview];
		return;
	}
	if (!button) {
		button = (AYSpeechButton *)[AYSpeechButton buttonWithType:UIButtonTypeCustom];
		button.textView = textView;
		button.tintColor = [UIColor whiteColor];
		button.bounds = CGRectMake(0, 0, 34, 34);
		button.layer.cornerRadius = 17;
		button.layer.zPosition = 1000;
		button.layer.shadowColor = [UIColor blackColor].CGColor;
		button.layer.shadowOpacity = 0.25;
		button.layer.shadowRadius = 4;
		button.layer.shadowOffset = CGSizeMake(0, 2);
		button.accessibilityLabel = AYLoc(@"SPEECH_TO_TEXT_TITLE");
		[button addTarget:[AYSpeechInput class] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
		[button addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:[AYSpeechInput class] action:@selector(longPressed:)]];
		UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
		[button setImage:[UIImage systemImageNamed:@"mic.fill" withConfiguration:config] forState:UIControlStateNormal];
		button.backgroundColor = [UIColor colorWithRed:0.16 green:0.55 blue:0.96 alpha:0.9];
		objc_setAssociatedObject(textView, kSpeechButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[speechTextViews addObject:textView];
	}
	UIView *host = controller.view;
	if (button.superview != host) [host addSubview:button];
	CGRect field = [textView convertRect:textView.bounds toView:host];
	CGFloat size = button.bounds.size.width;
	CGFloat x = MIN(CGRectGetMaxX(field) - size / 2, host.bounds.size.width - size / 2 - 8);
	CGFloat y = CGRectGetMinY(field) - size / 2 - 14;
	button.center = CGPointMake(x, y);
	[host bringSubviewToFront:button];
	if ([AYSpeechInput shared].button == button) [[AYSpeechInput shared] relayoutLive];
}

// The input panel moves with the keyboard without re-laying out the text view, so follow it
// frame by frame for a short while after keyboard changes instead of polling all the time.
@interface AYSpeechFollower : NSObject
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) CFTimeInterval until;
@end
@implementation AYSpeechFollower
+ (instancetype)shared {
	static AYSpeechFollower *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [AYSpeechFollower new]; });
	return shared;
}
- (void)followFor:(CFTimeInterval)seconds {
	if (speechTextViews.count == 0) return;
	self.until = MAX(self.until, CACurrentMediaTime() + seconds);
	if (!self.link) {
		self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
		[self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	}
}
- (void)tick:(CADisplayLink *)link {
	for (UITextView *textView in speechTextViews.allObjects) {
		if (textView.window) updateSpeechButton(textView);
	}
	if (CACurrentMediaTime() > self.until) {
		[self.link invalidate];
		self.link = nil;
	}
}
@end

%group SpeechInput
%hook ChatInputTextView
- (void)didMoveToWindow {
	%orig;
	updateSpeechButton((UITextView *)self);
	if (((UITextView *)self).window) [[AYSpeechFollower shared] followFor:0.6];
}
- (void)layoutSubviews {
	%orig;
	updateSpeechButton((UITextView *)self);
}
%end
%end

%ctor {
	chatControllerClass = objc_getClass("_TtC10TelegramUI18ChatControllerImpl");
	Class textView = objc_getClass("_TtC17ChatInputTextNode17ChatInputTextView");
	if (!textView || ![textView isSubclassOfClass:[UITextView class]]) return;
	speechTextViews = [NSHashTable weakObjectsHashTable];
	%init(SpeechInput, ChatInputTextView = textView);
	void (^follow)(NSNotification *) = ^(NSNotification *note) {
		NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
		[[AYSpeechFollower shared] followFor:MAX(duration, 0.25) + 0.35];
	};
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserverForName:UIKeyboardWillChangeFrameNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:follow];
	[center addObserverForName:UIKeyboardDidChangeFrameNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:follow];
}
