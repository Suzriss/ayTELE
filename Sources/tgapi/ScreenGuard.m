#import "Headers.h"
#import <UIKit/UIKit.h>

@interface ayTELELocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

// Screen-recording / mirroring privacy cover (kScreenBlur, #33): while the screen is being
// captured (screen recording, QuickTime capture, or AirPlay mirroring), a full-screen blurred
// cover is shown over everything so names, photos and messages don't leak into the recording.
// It lifts the moment capture stops. Pure UIKit on our own top-most window — it never touches
// Telegram's views, so it cannot crash the app; worst case it simply doesn't appear.

@interface AYScreenGuard : NSObject
@property (nonatomic, strong) UIWindow *coverWindow;
@end

@implementation AYScreenGuard

+ (instancetype)shared {
	static AYScreenGuard *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [AYScreenGuard new]; });
	return shared;
}

+ (void)load {
	// Register once the app object exists, so scenes are available.
	dispatch_async(dispatch_get_main_queue(), ^{
		AYScreenGuard *guard = [self shared];
		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		[center addObserver:guard selector:@selector(update) name:UIScreenCapturedDidChangeNotification object:nil];
		[center addObserver:guard selector:@selector(update) name:UIApplicationDidBecomeActiveNotification object:nil];
		[center addObserver:guard selector:@selector(update) name:UISceneDidActivateNotification object:nil];
		[guard update];
	});
}

- (BOOL)isCapturing {
	for (UIScreen *screen in UIScreen.screens) {
		if (screen.isCaptured) return YES;
	}
	return NO;
}

- (void)update {
	if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self update]; }); return; }
	BOOL want = [[NSUserDefaults standardUserDefaults] boolForKey:kScreenBlur] && [self isCapturing];
	if (!want) {
		self.coverWindow.hidden = YES;
		self.coverWindow = nil;
		return;
	}
	if (self.coverWindow) { self.coverWindow.hidden = NO; return; }

	UIWindowScene *scene = nil;
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
			scene = (UIWindowScene *)s; break;
		}
	}
	if (!scene) {
		for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
			if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
		}
	}
	if (!scene) return;

	UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
	window.windowLevel = UIWindowLevelAlert + 100;
	window.userInteractionEnabled = NO;
	window.backgroundColor = [UIColor blackColor];

	UIViewController *vc = [UIViewController new];
	vc.view.backgroundColor = [UIColor blackColor];
	UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
	blur.frame = vc.view.bounds;
	blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[vc.view addSubview:blur];

	UILabel *label = [UILabel new];
	label.text = [ayTELELocalization localizedStringForKey:@"SCREEN_BLUR_OVERLAY"];
	label.textColor = [UIColor whiteColor];
	label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
	label.textAlignment = NSTextAlignmentCenter;
	label.numberOfLines = 0;
	label.translatesAutoresizingMaskIntoConstraints = NO;
	[blur.contentView addSubview:label];
	UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"eye.slash.fill"]];
	icon.tintColor = [UIColor whiteColor];
	icon.contentMode = UIViewContentModeScaleAspectFit;
	icon.translatesAutoresizingMaskIntoConstraints = NO;
	[blur.contentView addSubview:icon];
	[NSLayoutConstraint activateConstraints:@[
		[icon.centerXAnchor constraintEqualToAnchor:blur.contentView.centerXAnchor],
		[icon.centerYAnchor constraintEqualToAnchor:blur.contentView.centerYAnchor constant:-28],
		[icon.widthAnchor constraintEqualToConstant:44],
		[icon.heightAnchor constraintEqualToConstant:44],
		[label.centerXAnchor constraintEqualToAnchor:blur.contentView.centerXAnchor],
		[label.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:16],
		[label.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor constant:32],
		[label.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor constant:-32],
	]];

	window.rootViewController = vc;
	window.hidden = NO;
	self.coverWindow = window;
}

@end
