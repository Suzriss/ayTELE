#import "Headers.h"
#import <objc/runtime.h>

// Formatting bar (kFormatBar): a floating pill of buttons just above the chat text field. Each
// button wraps the current selection in Telegram's markdown delimiters — **bold**, __italic__,
// `mono`, ~~strike~~, ||spoiler|| — which Telegram turns into real entities when the message is
// sent. With no selection it inserts the pair and drops the cursor between them. Everything goes
// through UITextInput (replaceRange:withText:) so Telegram's own editor sees an ordinary edit; we
// never touch the outgoing request. Sits on the chat controller's root view and is repositioned by
// the keyboard follower in SpeechInput.xm, one row above the mic / arrow buttons.

@interface AYFormatButton : UIButton
@property (nonatomic, weak) UITextView *textView;
@property (nonatomic, copy) NSString *openDelim;
@property (nonatomic, copy) NSString *closeDelim;
@end
@implementation AYFormatButton
@end

static const void *kFormatBarKey = &kFormatBarKey;

@interface AYFormatBarHandler : NSObject
+ (void)tapped:(AYFormatButton *)sender;
@end
@implementation AYFormatBarHandler
+ (void)tapped:(AYFormatButton *)sender {
	UITextView *textView = sender.textView;
	if (!textView) return;
	if (!textView.isFirstResponder) [textView becomeFirstResponder];
	UITextRange *range = textView.selectedTextRange;
	if (!range) {
		UITextPosition *end = textView.endOfDocument;
		range = [textView textRangeFromPosition:end toPosition:end];
	}
	if (!range) return;

	NSString *open = sender.openDelim ?: @"";
	NSString *close = sender.closeDelim ?: @"";
	NSString *selected = [textView textInRange:range] ?: @"";
	NSString *replacement = [NSString stringWithFormat:@"%@%@%@", open, selected, close];
	UITextPosition *start = range.start;
	[textView replaceRange:range withText:replacement];

	// Put the caret just inside the opening delimiter: around the selection if there was one,
	// otherwise between the two delimiters so the user can type the formatted text.
	UITextPosition *innerStart = [textView positionFromPosition:start offset:open.length];
	UITextPosition *innerEnd = [textView positionFromPosition:start offset:open.length + selected.length];
	if (innerStart && innerEnd) {
		textView.selectedTextRange = [textView textRangeFromPosition:innerStart toPosition:innerEnd];
	}
	[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}
@end

static AYFormatButton *makeFormatButton(UITextView *textView, NSString *symbol, NSString *open, NSString *close) {
	AYFormatButton *button = (AYFormatButton *)[AYFormatButton buttonWithType:UIButtonTypeCustom];
	button.textView = textView;
	button.openDelim = open;
	button.closeDelim = close;
	button.tintColor = [UIColor whiteColor];
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
	[button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
	[button addTarget:[AYFormatBarHandler class] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
	return button;
}

void AYUpdateFormatBar(UITextView *textView, Class chatControllerClass) {
	UIView *bar = objc_getAssociatedObject(textView, kFormatBarKey);
	BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kFormatBar];
	UIViewController *controller = nil;
	if (enabled && textView.window) {
		for (UIResponder *r = textView.nextResponder; r; r = r.nextResponder) {
			if ([r isKindOfClass:[UIViewController class]]) { controller = (UIViewController *)r; break; }
		}
	}
	if (controller && chatControllerClass && ![controller isKindOfClass:chatControllerClass]) controller = nil;
	if (!controller || textView.hidden || textView.bounds.size.width < 40 || !textView.isFirstResponder) {
		bar.hidden = YES;
		return;
	}

	CGFloat btn = 30, gap = 2, pad = 6;
	if (!bar) {
		NSArray *specs = @[
			@[@"bold", @"**", @"**"],
			@[@"italic", @"__", @"__"],
			@[@"chevron.left.forwardslash.chevron.right", @"`", @"`"],
			@[@"strikethrough", @"~~", @"~~"],
			@[@"eye.slash", @"||", @"||"],
		];
		bar = [[UIView alloc] init];
		bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
		bar.layer.cornerRadius = 16;
		bar.layer.zPosition = 1000;
		bar.layer.shadowColor = [UIColor blackColor].CGColor;
		bar.layer.shadowOpacity = 0.25;
		bar.layer.shadowRadius = 4;
		bar.layer.shadowOffset = CGSizeMake(0, 2);
		CGFloat x = pad;
		for (NSArray *spec in specs) {
			AYFormatButton *b = makeFormatButton(textView, spec[0], spec[1], spec[2]);
			b.frame = CGRectMake(x, pad, btn, btn);
			[bar addSubview:b];
			x += btn + gap;
		}
		bar.bounds = CGRectMake(0, 0, x - gap + pad, btn + 2 * pad);
		objc_setAssociatedObject(textView, kFormatBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	UIView *host = controller.view;
	if (bar.superview != host) [host addSubview:bar];
	CGRect field = [textView convertRect:textView.bounds toView:host];
	CGFloat barW = bar.bounds.size.width;
	CGFloat barH = bar.bounds.size.height;
	// Centered, one row above the mic / arrow buttons so they never overlap.
	CGFloat cx = CGRectGetMidX(field);
	cx = MAX(barW / 2 + 8, MIN(cx, host.bounds.size.width - barW / 2 - 8));
	CGFloat cy = CGRectGetMinY(field) - 14 - 34 - 8 - barH / 2;
	bar.center = CGPointMake(cx, cy);
	bar.hidden = NO;
	[host bringSubviewToFront:bar];
}
