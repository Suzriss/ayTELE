#import "Headers.h"
#import "fishhook/fishhook.h"
#import <stdatomic.h>
#import <time.h>

// Keep messages that OTHER people delete, at the database layer — the robust half of "keep deleted".
//
// AYDeletedFilter (DeletedMessages.swift) already strips remote deletions out of the raw MTProto
// stream, which covers live updates and the ordinary getDifference. But it cannot cover the case the
// user actually hits: Telegram is closed for a while, deletions pile up on the server, and on relaunch
// the client gets `differenceTooLong` and does a full resync. There is no deletion UPDATE to strip
// then — the client simply reconciles its local store by calling Postbox to delete the messages that
// are gone. The same is true for any local, non-network deletion path. All of those funnel through one
// cross-framework call:
//
//     Postbox.Transaction.deleteMessages(_: [MessageId], forEachMedia:)
//     $s7Postbox11TransactionC14deleteMessages_12forEachMediaySayAA9MessageIdVG_yAA0G0_pcSgtF
//
// TelegramCore calls it across the framework boundary, so it resolves through the GOT and fishhook can
// rebind it — exactly like CopyProtect.xm rebinds Message.isCopyProtected(). We rebind it to a function
// that, for deletions the user did NOT start, records the ids for the badge and then simply does not
// forward the call, so the rows stay in the on-disk Postbox and survive every relaunch.
//
// Telling "someone else deleted it" from "I deleted it" is the whole policy ("keep others' only").
// The user's own deletions enter through one cross-framework call too:
//
//     TelegramEngine.Messages.deleteMessagesInteractively(messageIds:type:deleteAllInGroup:)
//     $s12TelegramCore0A6EngineC8MessagesC06deleteD13Interactively10messageIds4type0E10AllInGroup...
//
// TelegramUI calls it the instant the user confirms a delete, before the Postbox transaction runs. We
// rebind it only to open a short time window and forward unchanged; while that window is open, the
// Postbox hook lets deletions through so the user's own delete (for me / for everyone) works normally.
//
// ABI: both are Swift instance methods, so `self` arrives in the context register (x20) and the other
// arguments in x0.. — we let the compiler handle that with `swiftcall` + `swift_context` instead of
// hand-written assembly, which also keeps arm64e pointer-auth correct. (Telegram itself ships as arm64,
// so our arm64e slice is never loaded into it, but the attribute route is correct either way.)
//
// Everything is gated on the existing "Keep deleted messages" switch and fails open: if the feature is
// off, or we are inside the user's own delete window, the original delete runs untouched. Turning the
// switch off (and relaunching) removes the hook entirely.

// ---- the user's own-delete window --------------------------------------------------------------

static _Atomic(uint64_t) gUserDeleteUntilNs = 0;
static const uint64_t kUserDeleteWindowNs = 4ull * 1000000000ull; // 4s: confirm -> transaction commit

static inline uint64_t ay_now_ns(void) {
	return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}

static inline BOOL ay_keep_enabled(void) {
	return [[NSUserDefaults standardUserDefaults] boolForKey:kKeepDeletedMessages];
}

// Called from the Postbox hook: 1 = run the real delete, 0 = suppress it (keep the message).
static int ay_should_delete(void) {
	if (!ay_keep_enabled()) return 1;                        // feature off -> behave normally
	if (ay_now_ns() <= atomic_load(&gUserDeleteUntilNs)) return 1; // the user just asked for it
	return 0;                                                // someone else deleted it -> keep
}

static void ay_record_deleted(const void *messageIdArray) {
	if (!messageIdArray) return;
	@try { [AYPostboxKeep recordArray:(NSUInteger)(uintptr_t)messageIdArray]; }
	@catch (__unused NSException *e) {}
}

// ---- hook: Postbox.Transaction.deleteMessages(_:forEachMedia:) ---------------------------------
// swiftcall lowering: x0 = messageIds array, (x1,x2) = the optional forEachMedia closure (fn,ctx),
// x20 = self (the Transaction). Returns Void.

typedef void (*ay_deleteMessages_t)(const void *messageIds,
                                    void *forEachMediaFn, void *forEachMediaCtx,
                                    void *txn __attribute__((swift_context)))
	__attribute__((swiftcall));

static ay_deleteMessages_t ay_deleteMessages_orig = NULL;

__attribute__((swiftcall))
static void ay_deleteMessages_repl(const void *messageIds,
                                   void *forEachMediaFn, void *forEachMediaCtx,
                                   void *txn __attribute__((swift_context))) {
	if (ay_should_delete()) {
		if (ay_deleteMessages_orig)
			ay_deleteMessages_orig(messageIds, forEachMediaFn, forEachMediaCtx, txn);
		return;
	}
	ay_record_deleted(messageIds); // keep: record for the badge, do NOT call the original
}

// ---- hook: TelegramEngine.Messages.deleteMessagesInteractively(messageIds:type:deleteAllInGroup:)
// swiftcall lowering: x0 = messageIds array, x1 = type (no-payload enum), x2 = deleteAllInGroup (Bool),
// x20 = self (the Messages instance). Returns a Signal (a reference, in x0). We only mark the window
// and forward unchanged.

typedef void *(*ay_deleteInteractively_t)(const void *messageIds,
                                          uint64_t type, bool deleteAllInGroup,
                                          void *messages __attribute__((swift_context)))
	__attribute__((swiftcall));

static ay_deleteInteractively_t ay_deleteInteractively_orig = NULL;

__attribute__((swiftcall))
static void *ay_deleteInteractively_repl(const void *messageIds,
                                         uint64_t type, bool deleteAllInGroup,
                                         void *messages __attribute__((swift_context))) {
	atomic_store(&gUserDeleteUntilNs, ay_now_ns() + kUserDeleteWindowNs);
	if (ay_deleteInteractively_orig)
		return ay_deleteInteractively_orig(messageIds, type, deleteAllInGroup, messages);
	return NULL;
}

// fishhook matches each symbol name without its leading '_'.
static const char *kDeleteMessagesSymbol =
	"$s7Postbox11TransactionC14deleteMessages_12forEachMediaySayAA9MessageIdVG_yAA0G0_pcSgtF";
static const char *kDeleteInteractivelySymbol =
	"$s12TelegramCore0A6EngineC8MessagesC06deleteD13Interactively10messageIds4type0E10AllInGroup14SwiftSignalKit0N0CyytAJ7NoErrorOGSay7Postbox9MessageIdVG_AA011InteractiveD12DeletionTypeOSbtF";

__attribute__((constructor))
static void initPostboxKeepDeleted(void) {
	if (!ay_keep_enabled()) return; // off at launch -> install nothing, zero risk
	rebind_symbols((struct rebinding[]){
		{kDeleteInteractivelySymbol, (void *)ay_deleteInteractively_repl, (void **)&ay_deleteInteractively_orig},
		{kDeleteMessagesSymbol, (void *)ay_deleteMessages_repl, (void **)&ay_deleteMessages_orig},
	}, 2);
}
