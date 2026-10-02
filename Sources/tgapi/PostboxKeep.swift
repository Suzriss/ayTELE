import Foundation

// Reads the Swift `[Postbox.MessageId]` that the Postbox-layer delete hook (PostboxKeepDeleted.xm)
// intercepts, and records each id into AYDeletedMarks so the chat shows the deleted badge even for
// deletions that never arrive as a strippable network update — the case that matters when Telegram
// was closed and comes back to a `differenceTooLong` full resync.
//
// This is best-effort cosmetics: the message is kept in Postbox by the hook itself (by not calling
// the original), regardless of whether we manage to decode the array here. So every read is guarded
// and a wrong guess only costs a missing badge, never the message and never a crash we can avoid.
//
// Memory layout we rely on (arm64, standard Swift ABI):
//   * A `[Element]` value is a single pointer to its _ContiguousArrayStorage header:
//       +0x10: count    (Int, 8 bytes)
//       +0x20: first element
//   * Postbox.MessageId == { peerId: PeerId; namespace: Int32; id: Int32 }, where
//     PeerId == { namespace: Int32; id: Int64 } -> 16 bytes (Int32 @0, pad, Int64 @8).
//     So MessageId is 24 bytes: peer.namespace@0, peer.id@8, msg.namespace@16, msg.id@20.
// Keys match AYDeletedMarks.messageKey: "u:<id>" for user/basic-group cloud messages,
// "c<channelId>:<id>" for channel cloud messages; non-cloud namespaces are ignored.
@objc(AYPostboxKeep)
class AYPostboxKeep: NSObject {
	private static let countOffset = 0x10
	private static let firstElementOffset = 0x20
	private static let elementStride = 24
	private static let sanityLimit = 100_000

	@objc static func recordArray(_ pointer: UInt) {
		guard pointer != 0, let base = UnsafeRawPointer(bitPattern: pointer) else { return }
		let count = base.load(fromByteOffset: countOffset, as: Int.self)
		guard count > 0, count < sanityLimit else { return }

		var keys: [String] = []
		keys.reserveCapacity(count)
		for index in 0 ..< count {
			let element = base + firstElementOffset + index * elementStride
			let peerNamespace = element.load(fromByteOffset: 0, as: Int32.self)
			let peerId = element.load(fromByteOffset: 8, as: Int64.self)
			let msgNamespace = element.load(fromByteOffset: 16, as: Int32.self)
			let msgId = element.load(fromByteOffset: 20, as: Int32.self)
			guard msgNamespace == 0 else { continue } // Namespaces.Message.Cloud
			switch peerNamespace {
			case 0, 1: // CloudUser, CloudGroup — message ids are per account
				keys.append("u:\(msgId)")
			case 2: // CloudChannel — ids are per channel
				keys.append("c\(peerId):\(msgId)")
			default:
				break
			}
		}
		guard !keys.isEmpty else { return }
		AYDeletedMarks.record(keys)
	}
}
