#import "Headers.h"
#import <Security/Security.h>
#import "fishhook/fishhook.h"

// Sideloaded (and cloned) installs are signed with someone else's team, so
// the entitlements Telegram was built for are gone:
//
// - App group: Telegram asks for "group.<bundle id>", which the profile
//   doesn't carry, and Telegram can't open its data at launch (black
//   screen or crash). Hand back a private folder inside the app's own container
//   instead, so every clone keeps its own data.
//
// - Keychain: Telegram passes its own access group ("C67CF9S4VU..."). The
//   new signature isn't allowed that group, the call fails and Telegram
//   crashes at launch. Swap in the group this install actually owns, but
//   only when the requested one isn't granted, so a properly signed install
//   (e.g. TrollStore with the original entitlements) is left untouched.

typedef struct __SecTask *SecTaskRef;
extern "C" SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern "C" CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);

static NSArray<NSString *> *grantedAccessGroups;
static NSArray<NSString *> *grantedAppGroups;
static NSString *ownAccessGroup;

static id copyEntitlement(SecTaskRef task, CFStringRef name) {
	if (!task) return nil;
	return CFBridgingRelease(SecTaskCopyValueForEntitlement(task, name, NULL));
}

static void loadEntitlements() {
	SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);

	NSMutableArray *accessGroups = [NSMutableArray array];
	NSArray *keychainGroups = copyEntitlement(task, CFSTR("keychain-access-groups"));
	if ([keychainGroups isKindOfClass:[NSArray class]]) {
		[accessGroups addObjectsFromArray:keychainGroups];
	}
	NSString *applicationIdentifier = copyEntitlement(task, CFSTR("application-identifier"));
	if ([applicationIdentifier isKindOfClass:[NSString class]]) {
		[accessGroups addObject:applicationIdentifier];
	}
	grantedAccessGroups = accessGroups;

	NSArray *appGroups = copyEntitlement(task, CFSTR("com.apple.security.application-groups"));
	grantedAppGroups = [appGroups isKindOfClass:[NSArray class]] ? appGroups : @[];

	if (task) CFRelease(task);
}

// Entitlements may use a trailing wildcard, e.g. "TEAMID.*".
static BOOL isGranted(NSArray<NSString *> *granted, NSString *requested) {
	if (![requested isKindOfClass:[NSString class]]) return NO;

	for (NSString *entry in granted) {
		if (![entry isKindOfClass:[NSString class]]) continue;
		if ([entry isEqualToString:requested]) return YES;
		if ([entry hasSuffix:@"*"] && [requested hasPrefix:[entry substringToIndex:entry.length - 1]]) return YES;
	}
	return NO;
}

// The default group of this signature: whatever a group-less item lands in.
static NSString *loadOwnAccessGroup() {
	NSDictionary *probe = @{
		(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrAccount: @"ayTELE.accessGroupProbe",
		(__bridge id)kSecAttrService: @"ayTELE",
		(__bridge id)kSecReturnAttributes: @YES,
	};

	CFTypeRef result = NULL;
	OSStatus status = orig_SecItemCopyMatching((__bridge CFDictionaryRef)probe, &result);
	if (status == errSecItemNotFound) {
		status = orig_SecItemAdd((__bridge CFDictionaryRef)probe, &result);
	}

	if (status != errSecSuccess || !result) return nil;

	NSDictionary *attributes = CFBridgingRelease(result);
	return attributes[(__bridge id)kSecAttrAccessGroup];
}

// Returns a retained copy with the access group swapped, or NULL to keep the
// query as is.
static CFDictionaryRef copyRemappedQuery(CFDictionaryRef query) {
	if (!query || !CFDictionaryContainsKey(query, kSecAttrAccessGroup)) return NULL;

	static dispatch_once_t token;
	dispatch_once(&token, ^{
		ownAccessGroup = loadOwnAccessGroup();
	});

	NSString *requested = (__bridge NSString *)CFDictionaryGetValue(query, kSecAttrAccessGroup);
	if (!ownAccessGroup || isGranted(grantedAccessGroups, requested)) return NULL;

	CFMutableDictionaryRef remapped = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
	CFDictionarySetValue(remapped, kSecAttrAccessGroup, (__bridge CFStringRef)ownAccessGroup);
	return remapped;
}

static OSStatus hook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
	CFDictionaryRef remapped = copyRemappedQuery(attributes);
	OSStatus status = orig_SecItemAdd(remapped ?: attributes, result);
	if (remapped) CFRelease(remapped);
	return status;
}

static OSStatus hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
	CFDictionaryRef remapped = copyRemappedQuery(query);
	OSStatus status = orig_SecItemCopyMatching(remapped ?: query, result);
	if (remapped) CFRelease(remapped);
	return status;
}

static OSStatus hook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
	CFDictionaryRef remapped = copyRemappedQuery(query);
	OSStatus status = orig_SecItemUpdate(remapped ?: query, attributesToUpdate);
	if (remapped) CFRelease(remapped);
	return status;
}

static OSStatus hook_SecItemDelete(CFDictionaryRef query) {
	CFDictionaryRef remapped = copyRemappedQuery(query);
	OSStatus status = orig_SecItemDelete(remapped ?: query);
	if (remapped) CFRelease(remapped);
	return status;
}

static NSURL *fallbackGroupURL(NSString *groupIdentifier) {
	NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/AppGroup"];
	NSString *path = [base stringByAppendingPathComponent:groupIdentifier];

	// Telegram expects the layout of a real group container.
	[[NSFileManager defaultManager] createDirectoryAtPath:[path stringByAppendingPathComponent:@"Library/Caches"]
	                          withIntermediateDirectories:YES
	                                           attributes:nil
	                                                error:nil];

	return [NSURL fileURLWithPath:path isDirectory:YES];
}

%hook NSFileManager

- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	// iOS may hand back a path even for a group the signature lacks; writing
	// there fails and Telegram crashes opening its database. Trust the
	// entitlements, not the return value.
	if (groupIdentifier.length == 0 || isGranted(grantedAppGroups, groupIdentifier)) {
		return %orig;
	}

	return fallbackGroupURL(groupIdentifier);
}

%end

__attribute__((constructor))
static void initCloneFix() {
	// Must be in place before Telegram's AppDelegate touches either.
	loadEntitlements();

	// Seed the originals so they're valid even if no image imports a symbol.
	orig_SecItemAdd = SecItemAdd;
	orig_SecItemCopyMatching = SecItemCopyMatching;
	orig_SecItemUpdate = SecItemUpdate;
	orig_SecItemDelete = SecItemDelete;

	rebind_symbols((struct rebinding[]){
		{"SecItemAdd", (void *)hook_SecItemAdd, (void **)&orig_SecItemAdd},
		{"SecItemCopyMatching", (void *)hook_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
		{"SecItemUpdate", (void *)hook_SecItemUpdate, (void **)&orig_SecItemUpdate},
		{"SecItemDelete", (void *)hook_SecItemDelete, (void **)&orig_SecItemDelete},
	}, 4);

	%init;
}
