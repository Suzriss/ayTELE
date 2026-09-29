import Foundation

// Records old versions of edited messages.
// Edits reach the client as updateEditMessage / updateEditChannelMessage (pushed or inside
// getDifference / getChannelDifference). We also see the first version through
// updateNewMessage / updateNewChannelMessage and the newMessages vectors. Every time we observe a
// message body we keep it, so once someone edits a message we already hold the previous text.
// This is read-only: it never changes the bytes handed to the client, unlike AYDeletedFilter.
@objc(AYEditHistory)
class AYEditHistory: NSObject {
	@objc static let changedNotification = Notification.Name("ayTELEEditHistoryChanged")
	private static let storageKey = "ayTELEEditHistoryV1"
	private static let messageLimit = 10000  // distinct messages tracked
	private static let versionLimit = 40     // versions kept per message

	// The pencil badge and version viewer are gated on this.
	@objc static var isEnabled: Bool {
		return UserDefaults.standard.bool(forKey: "keepEditHistory")
	}

	// Text is captured whenever edit history OR deleted-message keeping is on, so the deleted
	// browse list (#56) has message text even without edit history enabled.
	@objc static var shouldObserve: Bool {
		let d = UserDefaults.standard
		return d.bool(forKey: "keepEditHistory") || d.bool(forKey: "keepDeletedMessages")
	}

	// One stored version: the text as it was, and the server timestamp we saw it at.
	// chat / from are peer keys ("u<id>", "g<id>", "c<id>", "me"); optional so older stores decode.
	private struct Version: Codable, Equatable {
		let text: String
		let date: Int32
		var chat: String? = nil
		var from: String? = nil
	}

	private static let lock = NSLock()
	private static var store: [String: [Version]] = load()
	private static var order: [String] = Array((load()).keys)

	private static func load() -> [String: [Version]] {
		guard let data = UserDefaults.standard.data(forKey: storageKey),
		      let decoded = try? JSONDecoder().decode([String: [Version]].self, from: data) else { return [:] }
		return decoded
	}

	// Coalesced: busy accounts record many times a second, the JSON is written at most every 3s.
	private static var persistPending = false
	private static func persist() {
		guard !persistPending else { return }
		persistPending = true
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
			lock.lock()
			persistPending = false
			let data = try? JSONEncoder().encode(store)
			lock.unlock()
			if let data = data { UserDefaults.standard.set(data, forKey: storageKey) }
		}
	}

	private typealias Entry = (key: String, text: String, date: Int32, chat: String?, from: String?)

	// Read-only scan of a decoded payload. Records every message text version it can reach.
	@objc static func observe(_ data: NSData) {
		guard shouldObserve else { return }
		let buffer = Buffer(nsData: data)
		guard let object = Api.parse(buffer) else { return }
		var found: [Entry] = []
		var names: [String: String] = [:]
		collect(object, into: &found, names: &names, depth: 0)
		if !names.isEmpty { AYPeerNames.record(names) }
		guard !found.isEmpty else { return }
		record(found)
	}

	// Walks a parsed Api object with Mirror, pulling out every Api.Message.message it finds.
	private static func collect(_ value: Any, into found: inout [Entry], names: inout [String: String], depth: Int) {
		guard depth < 10 else { return }
		let mirror = Mirror(reflecting: value)
		if mirror.displayStyle == .enum, let child = mirror.children.first {
			let tuple = Mirror(reflecting: child.value)
			switch child.label {
			case "message":
				let labels = Set(tuple.children.compactMap { $0.label })
				if labels.contains("id"), labels.contains("peerId"), labels.contains("message") {
					if let entry = messageEntry(tuple) { found.append(entry) }
				}
			case "user":
				if let id = int64(tuple, "id") {
					let name = [string(tuple, "firstName"), string(tuple, "lastName")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
					let fallback = string(tuple, "username").map { "@" + $0 }
					if let n = name.isEmpty ? fallback : name { names["u\(id)"] = n }
				}
			case "chat":
				if let id = int64(tuple, "id"), let title = string(tuple, "title") { names["g\(id)"] = title }
			case "channel":
				if let id = int64(tuple, "id"), let title = string(tuple, "title") { names["c\(id)"] = title }
			default:
				break
			}
		}
		for child in mirror.children {
			collect(child.value, into: &found, names: &names, depth: depth + 1)
		}
	}

	private static func string(_ tuple: Mirror, _ label: String) -> String? {
		for c in tuple.children where c.label == label {
			return AYDeletedMarks.unwrap(c.value) as? String
		}
		return nil
	}

	private static func int64(_ tuple: Mirror, _ label: String) -> Int64? {
		for c in tuple.children where c.label == label {
			return AYDeletedMarks.unwrap(c.value) as? Int64
		}
		return nil
	}

	private static func messageEntry(_ tuple: Mirror) -> Entry? {
		var id: Int32?
		var text: String?
		var peer: Any?
		var fromId: Any?
		var flags: Int32 = 0
		var date: Int32?
		var editDate: Int32?
		for child in tuple.children {
			switch child.label {
			case "id": id = child.value as? Int32
			case "flags": flags = child.value as? Int32 ?? 0
			case "message": text = child.value as? String
			case "peerId": peer = child.value
			case "fromId": fromId = AYDeletedMarks.unwrap(child.value)
			case "date": date = child.value as? Int32
			case "editDate": editDate = unwrapInt32(child.value)
			default: break
			}
		}
		guard let id = id, let text = text, let peer = peer,
		      let key = peerKey(peer, messageId: id) else { return nil }
		let chat = chatKey(peer)
		// Private chats omit from_id: the sender is us (flags.1 = out) or the chat peer.
		let from = fromId.flatMap(chatKey) ?? ((flags & (1 << 1)) != 0 ? "me" : chat)
		return (key, text, editDate ?? date ?? 0, chat, from)
	}

	// Api.Peer -> "u<id>" / "g<id>" / "c<id>", the peer keys used by AYPeerNames.
	static func chatKey(_ peer: Any) -> String? {
		let mirror = Mirror(reflecting: peer)
		guard mirror.displayStyle == .enum, let child = mirror.children.first,
		      let id = firstInt64(child.value) else { return nil }
		switch child.label {
		case "peerUser": return "u\(id)"
		case "peerChat": return "g\(id)"
		case "peerChannel": return "c\(id)"
		default: return nil
		}
	}

	// Api.Peer -> the same key AYDeletedMarks uses: "u:<msgId>" for users/basic groups
	// (message ids are unique per account), "c<channelId>:<msgId>" for channels.
	private static func peerKey(_ peer: Any, messageId: Int32) -> String? {
		let mirror = Mirror(reflecting: peer)
		guard mirror.displayStyle == .enum, let child = mirror.children.first else { return nil }
		switch child.label {
		case "peerUser", "peerChat":
			return "u:\(messageId)"
		case "peerChannel":
			guard let cid = firstInt64(child.value) else { return nil }
			return "c\(cid):\(messageId)"
		default:
			return nil
		}
	}

	private static func unwrapInt32(_ value: Any) -> Int32? {
		if let v = value as? Int32 { return v }
		let mirror = Mirror(reflecting: value)
		guard mirror.displayStyle == .optional, let child = mirror.children.first else { return nil }
		return child.value as? Int32
	}

	private static func firstInt64(_ value: Any) -> Int64? {
		for child in Mirror(reflecting: value).children {
			if let v = child.value as? Int64 { return v }
		}
		return value as? Int64
	}

	private static func record(_ entries: [Entry]) {
		lock.lock()
		var changed = false
		for entry in entries {
			var versions = store[entry.key] ?? []
			if versions.last?.text == entry.text { continue } // no change
			if versions.isEmpty { order.append(entry.key) }
			versions.append(Version(text: entry.text, date: entry.date, chat: entry.chat, from: entry.from))
			if versions.count > versionLimit { versions.removeFirst(versions.count - versionLimit) }
			store[entry.key] = versions
			changed = true
		}
		if order.count > messageLimit {
			for key in order.prefix(order.count - messageLimit) { store[key] = nil }
			order.removeFirst(order.count - messageLimit)
		}
		guard changed else { lock.unlock(); return }
		persist()
		lock.unlock()
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: changedNotification, object: nil)
		}
	}

	// True when we hold more than one version, i.e. the message was edited while we watched.
	@objc static func isEdited(key: String) -> Bool {
		lock.lock(); defer { lock.unlock() }
		return (store[key]?.count ?? 0) > 1
	}

	// node is a ChatMessageItemView; resolve its key the same way the deleted badge does.
	@objc static func isEdited(node: NSObject) -> Bool {
		guard let key = AYDeletedMarks.key(node: node) else { return false }
		return isEdited(key: key)
	}

	// Returns [text, "date"] pairs oldest-first for the message under this node, for the viewer UI.
	@objc static func versions(node: NSObject) -> [[String]] {
		guard let key = AYDeletedMarks.key(node: node) else { return [] }
		return versions(key: key)
	}

	@objc static func versions(key: String) -> [[String]] {
		lock.lock(); defer { lock.unlock() }
		guard let versions = store[key] else { return [] }
		return versions.map { [$0.text, "\($0.date)"] }
	}

	// [text, chat, from] of the latest observed version, for freezing a deleted message.
	static func latest(forKey key: String) -> (text: String, chat: String?, from: String?)? {
		lock.lock(); defer { lock.unlock() }
		guard let v = store[key]?.last else { return nil }
		return (v.text, v.chat, v.from)
	}

	// The latest text we observed for a message, if any (used by the deleted browse list).
	@objc static func text(forKey key: String) -> String? {
		lock.lock(); defer { lock.unlock() }
		return store[key]?.last?.text
	}

	// Edited messages for the browse screen: [key, latestText, "versionCount"], newest first.
	@objc static func editedList() -> [[String]] {
		lock.lock(); defer { lock.unlock() }
		return store.filter { $0.value.count > 1 }
			.sorted { ($0.value.last?.date ?? 0) > ($1.value.last?.date ?? 0) }
			.map { [$0.key, $0.value.last?.text ?? "", "\($0.value.count)"] }
	}
}
