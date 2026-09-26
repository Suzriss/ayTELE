#import "Headers.h"

// Cloned installs get a new bundle id, so Telegram asks for
// "group.<new id>", which the signing profile doesn't carry. iOS returns nil
// and Telegram stops at launch on a black screen. Hand back a private folder
// inside the app's own container instead, so every clone keeps its own data.

static NSURL *fallbackGroupURL(NSString *groupIdentifier) {
	NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/AppGroup"];
	NSString *path = [base stringByAppendingPathComponent:groupIdentifier];

	NSFileManager *manager = [NSFileManager defaultManager];
	if (![manager fileExistsAtPath:path]) {
		[manager createDirectoryAtPath:path
		   withIntermediateDirectories:YES
		                    attributes:nil
		                         error:nil];
	}

	return [NSURL fileURLWithPath:path isDirectory:YES];
}

%hook NSFileManager

- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	NSURL *url = %orig;
	if (url || groupIdentifier.length == 0) {
		return url;
	}

	return fallbackGroupURL(groupIdentifier);
}

%end

__attribute__((constructor))
static void initCloneFix() {
	// Must be in place before Telegram's AppDelegate resolves the group.
	%init;
}
