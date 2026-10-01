#import "Headers.h"
#import <dlfcn.h>

// Raise the in-app account limit (kMoreAccounts, #77). Telegram keeps the cap in a Swift global
// `AccountUtils.maximumNumberOfAccounts: Int`, reachable through its exported unsafe addressor
// (found in the TelegramUIFramework export trie). We hook that addressor so every read returns a
// pointer to our own larger value. If substrate or the symbol isn't there, we simply do nothing —
// the app is untouched. Behind a default-off toggle; applying it restarts the app, so the hook is
// installed before Telegram reads the limit.

#if __has_include(<substrate.h>)
#import <substrate.h>
#define AY_HAVE_SUBSTRATE 1
#elif __has_include(<ellekit/ellekit.h>)
#import <ellekit/ellekit.h>
#define AY_HAVE_SUBSTRATE 1
#endif

#ifdef AY_HAVE_SUBSTRATE
// Swift Int is 64-bit on arm64; the addressor returns a pointer to it.
static intptr_t ayMaxAccounts = 10;
static intptr_t *(*orig_maxAccounts)(void);
static intptr_t *hooked_maxAccounts(void) { return &ayMaxAccounts; }
#endif

%ctor {
#ifdef AY_HAVE_SUBSTRATE
	if (![[NSUserDefaults standardUserDefaults] boolForKey:kMoreAccounts]) return;
	// dlsym drops the leading underscore of the mangled symbol.
	void *sym = dlsym(RTLD_DEFAULT, "$s12AccountUtils23maximumNumberOfAccountsSivau");
	if (sym) MSHookFunction(sym, (void *)hooked_maxAccounts, (void **)&orig_maxAccounts);
#endif
}
