#import <UIKit/UIKit.h>
#import "Headers.h"

// Menu Open
@interface ASDisplayNode : NSObject
@property (atomic, assign, readonly) UIView *view;
@property (atomic, copy, readonly) NSArray *subnodes;
@property (atomic, copy, readwrite) NSString *accessibilityLabel;
@property (nonatomic, strong) UILongPressGestureRecognizer *longPressGesture;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
@property (nonatomic, strong) UITapGestureRecognizer *settingsTapGesture;
- (void)__handleSettingsTabLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)__handle5PleTap;
@end

static ThreeFingerGestureHandler *gestureHandler = nil;
static __weak TGLocalization *TGLocalizationShared = nil;

// NOTE: this hook must be armed *before* the app builds its localization,
// which happens very early at launch. It therefore lives in its own group
// that the constructor initialises synchronously (see hook() below) instead
// of inside the delayed %init used for the Swift UI nodes. If it were armed
// late, TGLocalizationShared would stay nil, every [TGLocalizationShared get:]
// would return nil, and the "ayTELE" Settings row + 5-tap Chats entry would
// silently fall back to hard-coded English and fail to match the real rows.
%group Localization
%hook TGLocalization

- (id)initWithVersion:(int)a code:(id)b dict:(id)c isActive:(BOOL)d {
    TGLocalization *instance = %orig;
    if (a != 96929692 && instance) {
        TGLocalizationShared = instance;
    }
    return instance;
}

%end
%end

void showUI() {
	ayTELE *ui = [ayTELE new];
	UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:ui];

	UIWindow *window = UIApplication.sharedApplication.keyWindow;
	UIViewController *rootVC = window.rootViewController;
	if (rootVC) {
	    [rootVC presentViewController:navVC animated:YES completion:nil];
	}
}

void handleThreeFingerLongPress(UILongPressGestureRecognizer *gesture) {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        showUI();
    }
}

@implementation ThreeFingerGestureHandler
- (void)handleThreeFingerLongPress:(UILongPressGestureRecognizer *)gesture {
    handleThreeFingerLongPress(gesture);
}
@end

// Rename the hijacked Settings row so it reads as a clear "ayTELE" button
// instead of masquerading as Telegram's own "Support" row. We walk the row's
// subnode tree and swap the visible text node whose string matches the row
// title, keeping its original font/colour so it blends with the native list.
static void ayRetitleRow(ASDisplayNode *node, NSString *fromTitle, NSString *toTitle) {
    if (!node) return;
    if ([node respondsToSelector:@selector(attributedText)] &&
        [node respondsToSelector:@selector(setAttributedText:)]) {
        NSAttributedString *attr = [(id)node attributedText];
        if (attr.length > 0 && [attr.string isEqualToString:fromTitle]) {
            NSDictionary *attrs = [attr attributesAtIndex:0 effectiveRange:NULL];
            NSAttributedString *replacement =
                [[NSAttributedString alloc] initWithString:toTitle attributes:attrs];
            [(id)node setAttributedText:replacement];
            node.accessibilityLabel = toTitle;
            if ([node respondsToSelector:@selector(setNeedsDisplay)]) {
                [(id)node setNeedsDisplay];
            }
        }
    }
    for (ASDisplayNode *child in node.subnodes) {
        ayRetitleRow(child, fromTitle, toTitle);
    }
}

%hook ASDisplayNode
%property (nonatomic, strong) UILongPressGestureRecognizer *longPressGesture;
%property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
%property (nonatomic, strong) UITapGestureRecognizer *settingsTapGesture;

%new
- (void)__handleSettingsTabLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
		showUI();
    }
}

%new
- (void)__handle5PleTap {
	showUI();
}

%end

%hook TabBarNode

- (void)didEnterHierarchy {
	%orig;

	ASDisplayNode *mainNode = self;

    for (ASDisplayNode *child in mainNode.subnodes) {
		NSString *localizedTitle = @"Chats";

		NSString *resultTitle = [TGLocalizationShared get:@"DialogList.TabTitle"];
		if (resultTitle.length > 0 && ![resultTitle isEqualToString:@"DialogList.TabTitle"]) {
			localizedTitle = resultTitle;
		}

        if ([child.accessibilityLabel isEqualToString:localizedTitle]) {

			if (!child.tapGesture) {
				child.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:child action:@selector(__handle5PleTap)];
				child.tapGesture.numberOfTapsRequired = 5;
			}

			if (![child.view.gestureRecognizers containsObject:child.tapGesture]) {
                [child.view addGestureRecognizer:child.tapGesture];
			}
        }
    }
}

%end

%hook PeerInfoScreenItemNode

- (void)didEnterHierarchy {
    %orig;

    ASDisplayNode *mainNode = self;

	if (!mainNode.longPressGesture) {
		 mainNode.longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:mainNode action:@selector(__handleSettingsTabLongPress:)];
	}

    // Check children for specific node
    for (ASDisplayNode *child in mainNode.subnodes) {
        if ([NSStringFromClass([child class]) isEqualToString:@"Display.AccessibilityAreaNode"]) {
			NSString *localizedTitle = @"Telegram Features";

			NSString *resultTitle = [TGLocalizationShared get:@"Settings.Support"];
			if (resultTitle.length > 0 && ![resultTitle isEqualToString:@"Settings.Support"]) {
				localizedTitle = resultTitle;
			}

            if ([child.accessibilityLabel isEqualToString:localizedTitle]) {

				// Relabel the row to "ayTELE" so it reads as an obvious, clearly named
				// button in Settings instead of a hidden tap on "Support".
				ayRetitleRow(mainNode, localizedTitle, @"ayTELE");

				if (![mainNode.view.gestureRecognizers containsObject:mainNode.longPressGesture]) {
					[mainNode.view addGestureRecognizer:mainNode.longPressGesture];
				}

				// A single tap on the ayTELE row opens the tool, so it's discoverable
				// straight from Telegram's own Settings (not only via the gestures).
				if (!mainNode.settingsTapGesture) {
					mainNode.settingsTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:mainNode action:@selector(__handle5PleTap)];
					mainNode.settingsTapGesture.numberOfTapsRequired = 1;
					mainNode.settingsTapGesture.cancelsTouchesInView = YES;
				}
				if (![mainNode.view.gestureRecognizers containsObject:mainNode.settingsTapGesture]) {
					[mainNode.view addGestureRecognizer:mainNode.settingsTapGesture];
				}
            }
        }
    }
}

%end

__attribute__((constructor))
static void hook() {
	// Arm the localization hook straight away — the app creates its
	// TGLocalization at launch, before the delayed %init below would run,
	// so capturing it must not wait.
	%init(Localization);

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
	 	%init(
		    TabBarNode = objc_getClass("TabBarUI.TabBarNode"),
            PeerInfoScreenItemNode = objc_getClass("PeerInfoScreen.PeerInfoScreenItemNode")
		);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *window = UIApplication.sharedApplication.keyWindow;
            if (window) {
                if (!gestureHandler) {
                    gestureHandler = [[ThreeFingerGestureHandler alloc] init];
                }

                UILongPressGestureRecognizer *threeFingerLongPress = [[UILongPressGestureRecognizer alloc]
                    initWithTarget:gestureHandler
                    action:@selector(handleThreeFingerLongPress:)];
                threeFingerLongPress.numberOfTouchesRequired = 3;
                threeFingerLongPress.minimumPressDuration = 0.5;

                [window addGestureRecognizer:threeFingerLongPress];
            }
        });
	});
}
