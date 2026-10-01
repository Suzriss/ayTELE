#import "Headers.h"
#import <objc/runtime.h>

// Translate the draft before sending (kTranslateOutgoing, #25): a globe button above the chat text
// field. Tap it and the text in the field is sent to Telegram's own translateText and replaced with
// the translation, so you review/edit and send it yourself. Long-press picks the target language.
// Pure raw MTProto (AYTranslate + AYIssueRequest) — no outgoing message is touched until you send.

@interface ayTELELocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

@interface AYTranslateButton : UIButton
@property (nonatomic, weak) UITextView *textView;
@end
@implementation AYTranslateButton
@end

static const void *kTranslateButtonKey = &kTranslateButtonKey;
static NSString *TRLoc(NSString *key) { return [ayTELELocalization localizedStringForKey:key]; }

// Target language: the saved choice, else English for Arabic text and the device language otherwise.
static NSString *targetLang(NSString *sample) {
	NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kTranslateLang];
	if (saved.length) return saved;
	for (NSUInteger i = 0; i < sample.length; i++) {
		unichar c = [sample characterAtIndex:i];
		if (c >= 0x0600 && c <= 0x06FF) return @"en";
	}
	NSString *dev = [[NSLocale preferredLanguages].firstObject componentsSeparatedByString:@"-"].firstObject;
	return dev.length ? dev : @"en";
}

@interface AYTranslateHandler : NSObject
@end
@implementation AYTranslateHandler

+ (void)tapped:(AYTranslateButton *)sender {
	UITextView *tv = sender.textView;
	NSString *text = [tv.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (text.length == 0) { AYPresentToast(TRLoc(@"TRANSLATE_EMPTY")); return; }

	NSString *lang = targetLang(text);
	NSData *payload = [AYTranslate buildTranslateText:text toLang:lang];
	AYPresentToast(TRLoc(@"TRANSLATE_WORKING"));
	BOOL issued = AYIssueRequest(payload, (int)0xa5eec345, ^(id result, MTRpcError *error) {
		NSString *translated = nil;
		if ([result isKindOfClass:[NSData class]]) translated = [AYTranslate parseTranslated:(NSData *)result];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (error || translated.length == 0) { AYPresentToast(TRLoc(@"TRANSLATE_FAILED")); return; }
			UITextView *field = sender.textView;
			if (!field) return;
			if (!field.isFirstResponder) [field becomeFirstResponder];
			UITextRange *all = [field textRangeFromPosition:field.beginningOfDocument toPosition:field.endOfDocument];
			if (all) [field replaceRange:all withText:translated];
			[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
		});
	});
	if (!issued) AYPresentToast(TRLoc(@"TRANSLATE_FAILED"));
}

+ (void)longPressed:(UILongPressGestureRecognizer *)press {
	if (press.state != UIGestureRecognizerStateBegan) return;
	UIViewController *controller = nil;
	for (UIResponder *r = press.view.nextResponder; r; r = r.nextResponder) {
		if ([r isKindOfClass:[UIViewController class]]) { controller = (UIViewController *)r; break; }
	}
	if (!controller) return;
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:TRLoc(@"TRANSLATE_LANG_TITLE") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
	NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:kTranslateLang];
	for (NSString *code in @[@"en", @"ar", @"tr", @"fr", @"es", @"de", @"ru", @"fa"]) {
		NSString *name = [[NSLocale currentLocale] localizedStringForLanguageCode:code] ?: code;
		if ([code isEqualToString:current]) name = [@"✓ " stringByAppendingString:name];
		[sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
			[[NSUserDefaults standardUserDefaults] setObject:code forKey:kTranslateLang];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:TRLoc(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
	sheet.popoverPresentationController.sourceView = press.view;
	sheet.popoverPresentationController.sourceRect = press.view.bounds;
	[controller presentViewController:sheet animated:YES completion:nil];
}

@end

void AYUpdateTranslateButton(UITextView *textView, Class chatControllerClass) {
	AYTranslateButton *button = objc_getAssociatedObject(textView, kTranslateButtonKey);
	BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kTranslateOutgoing];
	UIViewController *controller = nil;
	if (enabled && textView.window) {
		for (UIResponder *r = textView.nextResponder; r; r = r.nextResponder) {
			if ([r isKindOfClass:[UIViewController class]]) { controller = (UIViewController *)r; break; }
		}
	}
	if (controller && chatControllerClass && ![controller isKindOfClass:chatControllerClass]) controller = nil;
	if (!controller || textView.hidden || textView.bounds.size.width < 40 || !textView.isFirstResponder) {
		button.hidden = YES;
		return;
	}
	if (!button) {
		button = (AYTranslateButton *)[AYTranslateButton buttonWithType:UIButtonTypeCustom];
		button.textView = textView;
		button.tintColor = [UIColor whiteColor];
		button.bounds = CGRectMake(0, 0, 34, 34);
		button.layer.cornerRadius = 17;
		button.layer.zPosition = 1000;
		button.backgroundColor = [UIColor colorWithRed:0.16 green:0.55 blue:0.96 alpha:0.9];
		UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
		[button setImage:[UIImage systemImageNamed:@"globe" withConfiguration:config] forState:UIControlStateNormal];
		button.accessibilityLabel = TRLoc(@"TRANSLATE_TITLE");
		[button addTarget:[AYTranslateHandler class] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
		[button addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:[AYTranslateHandler class] action:@selector(longPressed:)]];
		objc_setAssociatedObject(textView, kTranslateButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	UIView *host = controller.view;
	if (button.superview != host) [host addSubview:button];
	CGRect field = [textView convertRect:textView.bounds toView:host];
	CGFloat size = button.bounds.size.width;
	CGFloat x = MIN(CGRectGetMaxX(field) - size / 2, host.bounds.size.width - size / 2 - 8);
	// Sit left of the dictation mic and voice-file arrow if those are on.
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	if ([d boolForKey:kSpeechToText]) x -= size + 10;
	if ([d boolForKey:kVoiceFromFile]) x -= size + 10;
	CGFloat y = CGRectGetMinY(field) - size / 2 - 14;
	button.center = CGPointMake(x, y);
	button.hidden = NO;
	[host bringSubviewToFront:button];
}
