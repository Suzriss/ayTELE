import Foundation

// Keeps messages that other people delete.
// Deletions reach the client as updateDeleteMessages / updateDeleteChannelMessages, either pushed
// (Updates) or inside updates.getDifference / getChannelDifference results. We empty the id vector
// of those updates in the raw TL bytes and leave pts / pts_count untouched, so the client's pts
// sequence stays consistent (no gap -> no refetch) while nothing gets deleted locally.
// Only the id bytes are removed; everything else is passed through byte for byte.
@objc(AYDeletedFilter)
class AYDeletedFilter: NSObject {
	private static let vectorID: Int32 = 481674261                 // vector#1cb5c415
	private static let updateDeleteMessages: Int32 = -1576161051    // updateDeleteMessages#a20db0e5
	private static let updateDeleteChannelMessages: Int32 = -1020437742 // updateDeleteChannelMessages#c32d5b12
	private static let updateShort: Int32 = 2027216577              // updateShort#78d4dec1
	private static let updates: Int32 = 1957577280                  // updates#74ae4240
	private static let updatesCombined: Int32 = 1918567619          // updatesCombined#725b04c3
	private static let difference: Int32 = 16030880                 // updates.difference#f49ca0
	private static let differenceSlice: Int32 = -1459938943         // updates.differenceSlice#a8fb1981
	private static let channelDifference: Int32 = 543450958         // updates.channelDifference#2064674e

	private struct Cut {
		let range: Range<Int>
		let keys: [String]
	}

	@objc static var isEnabled: Bool {
		return UserDefaults.standard.bool(forKey: "keepDeletedMessages")
	}

	// Returns filtered data, or nil when nothing was changed.
	@objc static func filter(_ data: NSData) -> NSData? {
		let bytes = data as Data
		guard bytes.count >= 8 else { return nil }
		let reader = BufferReader(Buffer(nsData: data))
		guard let signature = reader.readInt32() else { return nil }

		var cuts: [Cut] = []
		switch signature {
		case updateShort:
			checkDeletion(at: 4, in: bytes, cuts: &cuts)
		case updates, updatesCombined:
			scanUpdates(reader, bytes: bytes, cuts: &cuts)
		case difference, differenceSlice:
			guard skipVector(reader, type: Api.Message.self),
			      skipVector(reader, type: Api.EncryptedMessage.self) else { break }
			scanUpdates(reader, bytes: bytes, cuts: &cuts)
		case channelDifference:
			guard let flags = reader.readInt32(), reader.readInt32() != nil else { break }
			if flags & (1 << 1) != 0 { reader.skip(4) }
			guard skipVector(reader, type: Api.Message.self) else { break }
			scanUpdates(reader, bytes: bytes, cuts: &cuts)
		default:
			return nil
		}

		if cuts.isEmpty { return nil }
		AYDeletedMarks.record(cuts.flatMap { $0.keys })
		return apply(cuts.map { $0.range }, to: bytes) as NSData
	}

	// Walks a boxed Vector<Update>, recording deletions. Stops at the first element it cannot parse;
	// bytes after that point are left as they are.
	private static func scanUpdates(_ reader: BufferReader, bytes: Data, cuts: inout [Cut]) {
		guard reader.readInt32() == vectorID, let count = reader.readInt32(), count >= 0 else { return }
		for _ in 0 ..< count {
			let start = Int(reader.offset)
			guard let signature = reader.readInt32() else { return }
			checkDeletion(at: start, in: bytes, cuts: &cuts)
			guard Api.parse(reader, signature: signature) != nil else { return }
		}
	}

	private static func skipVector<T>(_ reader: BufferReader, type: T.Type) -> Bool {
		guard reader.readInt32() == vectorID else { return false }
		return Api.parseVector(reader, elementSignature: 0, elementType: type) != nil
	}

	private static func checkDeletion(at offset: Int, in bytes: Data, cuts: inout [Cut]) {
		guard let signature = int32(bytes, offset) else { return }
		let vectorOffset: Int
		let prefix: String
		switch signature {
		case updateDeleteMessages:
			vectorOffset = offset + 4
			prefix = "u"
		case updateDeleteChannelMessages:
			vectorOffset = offset + 12 // after channel_id:long
			guard let channelId = int64(bytes, offset + 4) else { return }
			prefix = "c\(channelId)"
		default:
			return
		}
		guard int32(bytes, vectorOffset) == vectorID,
		      let count = int32(bytes, vectorOffset + 4), count > 0, count < 100_000 else { return }
		let idsStart = vectorOffset + 8
		let idsEnd = idsStart + Int(count) * 4
		guard idsEnd + 8 <= bytes.count else { return } // pts + pts_count must follow
		let keys = stride(from: idsStart, to: idsEnd, by: 4).compactMap { int32(bytes, $0) }.map { "\(prefix):\($0)" }
		cuts.append(Cut(range: idsStart ..< idsEnd, keys: keys))
	}

	// Removes each id range and zeroes the vector count stored just before it.
	private static func apply(_ cuts: [Range<Int>], to bytes: Data) -> Data {
		var out = Data(capacity: bytes.count)
		var cursor = 0
		for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) where cut.lowerBound >= cursor + 4 {
			out.append(bytes[cursor ..< cut.lowerBound - 4])
			var zero: Int32 = 0
			out.append(Data(bytes: &zero, count: 4))
			cursor = cut.upperBound
		}
		out.append(bytes[cursor ..< bytes.count])
		return out
	}

	private static func int64(_ bytes: Data, _ offset: Int) -> Int64? {
		guard let low = int32(bytes, offset), let high = int32(bytes, offset + 4) else { return nil }
		return Int64(high) << 32 | Int64(UInt32(bitPattern: low))
	}

	private static func int32(_ bytes: Data, _ offset: Int) -> Int32? {
		guard offset >= 0, offset + 4 <= bytes.count else { return nil }
		var value: Int32 = 0
		withUnsafeMutableBytes(of: &value) { dst in
			bytes.copyBytes(to: dst.bindMemory(to: UInt8.self), from: bytes.startIndex + offset ..< bytes.startIndex + offset + 4)
		}
		return value
	}
}

// Remembers which messages were deleted remotely so the chat can mark them.
// Keys: "u:<id>" for private chats / basic groups (ids are per account), "c<channelId>:<id>" for channels.
@objc(AYDeletedMarks)
class AYDeletedMarks: NSObject {
	@objc static let changedNotification = Notification.Name("ayTELEDeletedMessagesChanged")
	private static let storageKey = "ayTELEDeletedMessageKeys"
	private static let limit = 5000
	private static let lock = NSLock()
	private static var order: [String] = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
	private static var keys = Set(order)

	static func record(_ newKeys: [String]) {
		lock.lock()
		var added = false
		for key in newKeys where !keys.contains(key) {
			keys.insert(key)
			order.append(key)
			added = true
		}
		if order.count > limit {
			for key in order.prefix(order.count - limit) { keys.remove(key) }
			order.removeFirst(order.count - limit)
		}
		let snapshot = order
		lock.unlock()
		guard added else { return }
		UserDefaults.standard.set(snapshot, forKey: storageKey)
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: changedNotification, object: nil)
		}
	}

	private static func contains(_ key: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return keys.contains(key)
	}

	// node is a ChatMessageItemView; its Swift `item` holds the Postbox Message.
	@objc static func isDeleted(node: NSObject) -> Bool {
		guard let key = messageKey(node) else { return false }
		return contains(key)
	}

	// Shared with AYEditHistory so both badges resolve a node to the same message key.
	@objc static func key(node: NSObject) -> String? {
		return messageKey(node)
	}

	private static func messageKey(_ node: NSObject) -> String? {
		var mirror: Mirror? = Mirror(reflecting: node)
		var item: Any?
		while let current = mirror, item == nil {
			item = child(current, "item")
			mirror = current.superclassMirror
		}
		guard let item = item else { return nil }
		let itemMirror = Mirror(reflecting: item)
		guard let message = child(itemMirror, "message") ?? firstMessage(in: child(itemMirror, "content")),
		      let messageId = child(Mirror(reflecting: message), "id") else { return nil }
		let idMirror = Mirror(reflecting: messageId)
		guard let peerId = child(idMirror, "peerId"),
		      let namespace = integer(child(idMirror, "namespace")), namespace == 0, // Namespaces.Message.Cloud
		      let id = integer(child(idMirror, "id")) else { return nil }
		let peerMirror = Mirror(reflecting: peerId)
		guard let peerNamespace = integer(child(peerMirror, "namespace")) else { return nil }
		switch peerNamespace {
		case 0, 1: // CloudUser, CloudGroup
			return "u:\(id)"
		case 2: // CloudChannel
			guard let channelId = integer(child(peerMirror, "id")) else { return nil }
			return "c\(channelId):\(id)"
		default:
			return nil
		}
	}

	// ChatMessageItemContent is .message(message:...) or .group(messages: [(Message, ...)]).
	private static func firstMessage(in content: Any?) -> Any? {
		guard let content = content else { return nil }
		var queue: [(Any, Int)] = [(content, 0)]
		while !queue.isEmpty {
			let (value, depth) = queue.removeFirst()
			let mirror = Mirror(reflecting: value)
			if mirror.displayStyle == .class, let id = child(mirror, "id"), child(Mirror(reflecting: id), "peerId") != nil {
				return value
			}
			if depth < 5 {
				queue.append(contentsOf: mirror.children.map { ($0.value, depth + 1) })
			}
		}
		return nil
	}

	private static func child(_ mirror: Mirror, _ label: String) -> Any? {
		for c in mirror.children where c.label == label {
			return unwrap(c.value)
		}
		return nil
	}

	private static func unwrap(_ value: Any) -> Any? {
		let mirror = Mirror(reflecting: value)
		guard mirror.displayStyle == .optional else { return value }
		return mirror.children.first.flatMap { unwrap($0.value) }
	}

	// Int32 / Int64 or a wrapper struct around one (PeerId.Namespace, PeerId.Id).
	private static func integer(_ value: Any?, depth: Int = 0) -> Int64? {
		guard let value = value else { return nil }
		switch value {
		case let v as Int32: return Int64(v)
		case let v as Int64: return v
		case let v as UInt32: return Int64(v)
		case let v as Int: return Int64(v)
		default: break
		}
		guard depth < 3 else { return nil }
		for c in Mirror(reflecting: value).children {
			if let v = integer(c.value, depth: depth + 1) { return v }
		}
		return nil
	}
}
