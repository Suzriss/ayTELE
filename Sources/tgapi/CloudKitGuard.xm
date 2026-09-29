#import "Headers.h"
#import <objc/runtime.h>
#import <dlfcn.h>

// CloudKit launch-crash guard for sideloaded / re-signed Telegram.
//
// When Telegram is signed with a certificate that can't grant its iCloud/CloudKit
// entitlement (any sideload of `ph.telegra.Telegraph`), CloudKit throws an UNCAUGHT
// NSException the first time TelegramCore touches it — inside a dispatch_once during
// CloudKit's one-time init (CKSDKVersion) — which aborts the app ~0.2s after launch.
// The exception propagates up through Swift/dispatch frames that can't catch it, so it
// reaches std::terminate -> abort().
//
// We wrap the CKContainer entry points (the first CloudKit call TelegramCore makes) in
// @try/@catch. On a correctly-entitled install %orig never throws, so this is a pure
// no-op there — it CANNOT regress a working install. Only on the throwing sideload path
// do we swallow the exception and return nil, letting the app finish launching. Telegram's
// CloudKit paths are async and nil/error-tolerant, so losing (an already-broken) CloudKit
// is far better than aborting at launch.

@interface CKContainer : NSObject
+ (instancetype)containerWithIdentifier:(NSString *)identifier;
+ (instancetype)defaultContainer;
@end

#define kCloudKitGuard @"ayTELECloudKitGuard"   // defaults to ON

static BOOL cloudKitGuardEnabled(void) {
	id v = [[NSUserDefaults standardUserDefaults] objectForKey:kCloudKitGuard];
	return v ? [v boolValue] : YES;   // opt-out, default enabled
}

%group CloudKitGuard

%hook CKContainer

+ (instancetype)containerWithIdentifier:(NSString *)identifier {
	if (!cloudKitGuardEnabled()) return %orig;
	@try {
		return %orig;
	} @catch (NSException *e) {
		customLog2(@"[ayTELE] CloudKit guard swallowed exception: %@", e);
		return nil;
	}
}

+ (instancetype)defaultContainer {
	if (!cloudKitGuardEnabled()) return %orig;
	@try {
		return %orig;
	} @catch (NSException *e) {
		customLog2(@"[ayTELE] CloudKit guard swallowed exception: %@", e);
		return nil;
	}
}

%end

%end

%ctor {
	// Make sure CloudKit is present before we resolve the class; it is normally already
	// loaded by Telegram, but dlopen is harmless if so and never calls a throwing API.
	dlopen("/System/Library/Frameworks/CloudKit.framework/CloudKit", RTLD_LAZY);
	Class ck = objc_getClass("CKContainer");
	if (ck) {
		%init(CloudKitGuard, CKContainer = ck);
	}
}
