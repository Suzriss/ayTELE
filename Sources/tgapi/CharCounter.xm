#import "Headers.h"
#import <objc/runtime.h>

// Live character counter (kCharCounter): a small label pinned to the top-leading corner of the
// chat text field. It shows how many characters are typed and, as the message approaches
// Telegram's length limit, flips to the remaining count in orange and then red. Pure UI that reads
// textView.text — it never touches what gets sent. Placed on the chat controller's root view (like
// the dictation mic and voice-file arrow) so the input panel can't clip it, and repositioned by the
// same keyboard follower in SpeechInput.xm.

// Telegram's plain-message limit for non-premium accounts. Captions are shorter, but a message
// counter that only warns near 4096 is a safe, useful default (it never blocks or trims anything).
#define AY_MESSAGE_LIMIT 4096
#define AY_WARN_WITHIN   200

static const void *kCharCounterKey = &kCharCounterKey;

void AYUpdateCharCounter(UITextView *textView, Class chatControllerClass) {
	UILabel *label = objc_getAssociatedObject(textView, kCharCounterKey);
	BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kCharCounter];
	UIViewController *controller = nil;
	if (enabled && textView.window) {
		for (UIResponder *r = textView.nextResponder; r; r = r.nextResponder) {
			if ([r isKindOfClass:[UIViewController class]]) { controller = (UIViewController *)r; break; }
		}
	}
	if (controller && chatControllerClass && ![controller isKindOfClass:chatControllerClass]) controller = nil;

	NSUInteger length = textView.text.length;
	// Only worth showing while the user is actually writing something.
	if (!controller || textView.hidden || textView.bounds.size.width < 40 || length == 0 || !textView.isFirstResponder) {
		label.hidden = YES;
		return;
	}

	if (!label) {
		label = [UILabel new];
		label.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
		label.textAlignment = NSTextAlignmentCenter;
		label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
		label.layer.cornerRadius = 8;
		label.clipsToBounds = YES;
		label.layer.zPosition = 1000;
		label.userInteractionEnabled = NO;
		objc_setAssociatedObject(textView, kCharCounterKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	NSInteger remaining = AY_MESSAGE_LIMIT - (NSInteger)length;
	if (length >= AY_MESSAGE_LIMIT - AY_WARN_WITHIN) {
		label.text = [NSString stringWithFormat:@"  %ld  ", (long)remaining];
		label.textColor = remaining < 0 ? [UIColor systemRedColor] : [UIColor systemOrangeColor];
	} else {
		label.text = [NSString stringWithFormat:@"  %lu  ", (unsigned long)length];
		label.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
	}

	UIView *host = controller.view;
	if (label.superview != host) [host addSubview:label];
	[label sizeToFit];
	CGRect bounds = label.bounds;
	CGFloat w = MAX(bounds.size.width, 26);
	CGFloat h = 18;
	CGRect field = [textView convertRect:textView.bounds toView:host];
	// Top-leading corner of the field (opposite the trailing mic / arrow buttons).
	CGFloat x = CGRectGetMinX(field) + 6;
	CGFloat y = CGRectGetMinY(field) - h - 6;
	label.frame = CGRectMake(x, y, w, h);
	label.hidden = NO;
	[host bringSubviewToFront:label];
}
