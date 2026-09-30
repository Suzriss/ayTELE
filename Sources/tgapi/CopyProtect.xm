#import <Foundation/Foundation.h>
#import "fishhook/fishhook.h"
#import "Constants.h"

// Unlock saving of copy-protected media the way repackaged mods (e.g. Teledark) do — but at
// runtime instead of by patching the framework on disk.
//
// Telegram gates "Save to Gallery", forwarding and copy on Message.isCopyProtected() (defined in
// TelegramCore, called across the framework boundary from TelegramUI). Because it is an imported
// symbol, fishhook can rebind every call site to our own function. Returning false makes Telegram
// treat the media as unprotected, so its OWN save/download action appears and downloads the real
// file through the normal pipeline — no screenshot, no guessing.
//
// ABI: a Swift instance method takes self in the context register (x20) and returns its Bool in w0.
// A plain C function that ignores everything and returns false is a valid drop-in: w0 becomes 0.
// Forcing false is harmless for unprotected messages (they already return false); only protected
// ones change. We install it only when the user has turned on "allow saving from protected chats",
// so the default build behaves exactly as before. Like other load-time hooks it needs a relaunch.

static bool ay_isCopyProtected(void) { return false; }

// Message.isCopyProtected() -> Bool. fishhook matches the symbol name without its leading '_'.
static const char *kIsCopyProtectedSymbol =
	"$s7Postbox7MessageC12TelegramCoreE15isCopyProtectedSbyF";

__attribute__((constructor))
static void initCopyProtect(void) {
	if (![[NSUserDefaults standardUserDefaults] boolForKey:kDisableForwardRestriction]) return;
	rebind_symbols((struct rebinding[]){
		{kIsCopyProtectedSymbol, (void *)ay_isCopyProtected, NULL},
	}, 1);
}
