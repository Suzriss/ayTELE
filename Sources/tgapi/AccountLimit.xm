#import "Headers.h"

// Raise the in-app account limit (kMoreAccounts, #77) — DISABLED.
//
// The old implementation inline-hooked the Swift addressor for
// `AccountUtils.maximumNumberOfAccounts` with MSHookFunction, which rewrites the function prologue
// inside TelegramUIFramework's __TEXT. On iOS 26 the code-signing monitor flags that patched page
// as an "Invalid Page" and SIGKILLs the app at launch (CODESIGNING / KERN_PROTECTION_FAILURE the
// moment Telegram reads the limit during account setup). There is no clean alternative: the call
// is a direct intra-framework `bl`, so a __DATA/fishhook rebind can't intercept it either.
//
// The feature is therefore removed. The toggle is gone from the settings UI; any stored
// kMoreAccounts default is simply ignored. Nothing here touches __TEXT, so the tweak loads safely.
