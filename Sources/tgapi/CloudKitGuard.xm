#import "Headers.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <Security/Security.h>

// CloudKit launch-crash guard for sideloaded / re-signed Telegram.
//
// When Telegram is signed with a certificate that can't grant its iCloud entitlement
// (any sideload of `ph.telegra.Telegraph`), the first time TelegramCore's iCloud file
// support touches CloudKit — `+[CKContainer defaultContainer]` — CloudKit runs its
// one-time init inside a dispatch_once and throws NSInternalInconsistencyException
// (CKSDKVersion) because there is no icloud-container-identifiers entitlement. The throw
// happens INSIDE _dispatch_client_callout, which is compiled -fno-exceptions, so it can't
// unwind: std::terminate fires there and aborts ~0.2s after launch. A @try/@catch around
// the call is therefore useless — terminate runs below our frame before we can catch it.
//
// So we must stop the call from reaching the throw. We read the process's real granted
// entitlements with SecTask: if `com.apple.developer.icloud-container-identifiers` is
// present and non-empty (App Store / TrollStore-with-original-entitlements), CloudKit is
// usable, we call %orig, and this is a pure no-op — zero regression. Only when that
// entitlement is entirely absent (the sideload case, where %orig is guaranteed to throw)
// do we return nil instead of calling it. The caller is Telegram's Objective-C
// LegacyICloudFileController, which tolerates a nil container, so the app just launches
// without its (already non-functional) iCloud file feature.

typedef struct __SecTask *SecTaskRef;
extern "C" SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern "C" CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

@interface CKContainer : NSObject
+ (instancetype)containerWithIdentifier:(NSString *)identifier;
+ (instancetype)defaultContainer;
@end

#define kCloudKitGuard @"ayTELECloudKitGuard"   // defaults to ON

static BOOL cloudKitGuardEnabled(void) {
	id v = [[NSUserDefaults standardUserDefaults] objectForKey:kCloudKitGuard];
	return v ? [v boolValue] : YES;   // opt-out, default enabled
}

// YES when the app has no usable iCloud container entitlement, i.e. CloudKit would throw.
// Computed once: entitlements don't change during the process lifetime.
static BOOL appLacksICloudContainers(void) {
	static BOOL lacks = NO;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
		id ids = task ? CFBridgingRelease(SecTaskCopyValueForEntitlement(
			task, CFSTR("com.apple.developer.icloud-container-identifiers"), NULL)) : nil;
		if (task) CFRelease(task);
		lacks = !([ids isKindOfClass:[NSArray class]] && [(NSArray *)ids count] > 0);
	});
	return lacks;
}

static BOOL shouldBypassCloudKit(void) {
	return cloudKitGuardEnabled() && appLacksICloudContainers();
}

%group CloudKitGuard

%hook CKContainer

+ (instancetype)containerWithIdentifier:(NSString *)identifier {
	if (shouldBypassCloudKit()) {
		customLog2(@"[ayTELE] CloudKit guard: bypassing containerWithIdentifier: (no iCloud entitlement)");
		return nil;
	}
	return %orig;
}

+ (instancetype)defaultContainer {
	if (shouldBypassCloudKit()) {
		customLog2(@"[ayTELE] CloudKit guard: bypassing defaultContainer (no iCloud entitlement)");
		return nil;
	}
	return %orig;
}

%end

%end

%ctor {
	// CloudKit is normally already loaded by Telegram; dlopen is harmless otherwise and
	// never calls a throwing API. Only hook once the class actually exists.
	dlopen("/System/Library/Frameworks/CloudKit.framework/CloudKit", RTLD_LAZY);
	Class ck = objc_getClass("CKContainer");
	if (ck) {
		%init(CloudKitGuard, CKContainer = ck);
	}
}
