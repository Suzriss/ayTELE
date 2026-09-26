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
	private static let messageLimit = 4000   // distinct messages tracked
	private static let versionLimit = 40     // versions kept per message

	@objc static var isEnabled: Bool {
		return UserDefaults.standard.bool(forKey: "keepEditHistory")
	}

	// One stored version: the text as it was, and the server timestamp we saw it at.
	private struct Version: Codable, Equatable {
		let text: String
		let date: Int32
	}

	private static let lock = NSLock()
	private static var store: [String: [Version]] = load()
	private static var order: [String] = Array((load()).keys)

	private static func load() -> [String: [Version]] {
		guard let data = UserDefaults.standard.data(forKey: storageKey),
		      let decoded = try? JSONDecoder().decode([String: [Version]].self, from: data) else { return [:] }
		return decoded
	}

	private static func persist() {
		guard let data = try? JSONEncoder().encode(store) else { return }
		UserDefaults.standard.set(data, forKey: storageKey)
	}

	// Read-only scan of a decoded payload. Records every message text version it can reach.
	@objc static func observe(_ data: NSData) {
		guard isEnabled else { return }
		let buffer = Buffer(nsData: data)
		guard let object = Api.parse(buffer) else { return }
		var found: [(key: String, text: String, date: Int32)] = []
		collect(object, into: &found, depth: 0)
		guard !found.isEmpty else { return }
		record(found)
	}

	// Walks a parsed Api object with Mirror, pulling out every Api.Message.message it finds.
	private static func collect(_ value: Any, into found: inout [(String, String, Int32)], depth: Int) {
		guard depth < 10 else { return }
		let mirror = Mirror(reflecting: value)
		if mirror.displayStyle == .enum, let child = mirror.children.first, child.label == "message" {
			let tuple = Mirror(reflecting: child.value)
			let labels = Set(tuple.children.compactMap { $0.label })
			if labels.contains("id"), labels.contains("peerId"), labels.contains("message") {
				if let entry = messageEntry(tuple) { found.append(entry) }
			}
		}
		for child in mirror.children {
			collect(child.value, into: &found, depth: depth + 1)
		}
	}

	private static func messageEntry(_ tuple: Mirror) -> (String, String, Int32)? {
		var id: Int32?
		var text: String?
		var peer: Any?
		var date: Int32?
		var editDate: Int32?
		for child in tuple.children {
			switch child.label {
			case "id": id = child.value as? Int32
			case "message": text = child.value as? String
			case "peerId": peer = child.value
			case "date": date = child.value as? Int32
			case "editDate": editDate = unwrapInt32(child.value)
			default: break
			}
		}
		guard let id = id, let text = text, let peer = peer,
		      let key = peerKey(peer, messageId: id) else { return nil }
		return (key, text, editDate ?? date ?? 0)
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

	private static func record(_ entries: [(key: String, text: String, date: Int32)]) {
		lock.lock()
		var changed = false
		for entry in entries {
			var versions = store[entry.key] ?? []
			if versions.last?.text == entry.text { continue } // no change
			if versions.isEmpty { order.append(entry.key) }
			versions.append(Version(text: entry.text, date: entry.date))
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
		lock.lock(); defer { lock.unlock() }
		guard let versions = store[key] else { return [] }
		return versions.map { [$0.text, "\($0.date)"] }
	}
}
