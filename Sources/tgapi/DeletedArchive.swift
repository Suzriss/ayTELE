import Foundation

// Display names for peer keys ("u<id>", "g<id>", "c<id>"), learned from the users/chats vectors
// that travel with every message payload AYEditHistory observes.
@objc(AYPeerNames)
class AYPeerNames: NSObject {
	private static let storageKey = "ayTELEPeerNamesV1"
	private static let limit = 5000
	private static let lock = NSLock()
	private static var names: [String: String] = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
	private static var persistPending = false

	static func record(_ new: [String: String]) {
		lock.lock()
		var changed = false
		for (key, name) in new where names[key] != name {
			names[key] = name
			changed = true
		}
		if names.count > limit {
			// No recency order kept for names; dropping arbitrary ones is fine, they're re-learned.
			for key in names.keys.prefix(names.count - limit) { names[key] = nil }
		}
		let schedule = changed && !persistPending
		if schedule { persistPending = true }
		lock.unlock()
		guard schedule else { return }
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
			lock.lock()
			persistPending = false
			let snapshot = names
			lock.unlock()
			UserDefaults.standard.set(snapshot, forKey: storageKey)
		}
	}

	static func name(_ key: String?) -> String? {
		guard let key = key else { return nil }
		lock.lock(); defer { lock.unlock() }
		return names[key]
	}
}

// Frozen details of deleted messages. The edit-history text store is bounded and busy groups
// roll it over quickly, so the moment a deletion is seen we copy what we know about the message.
@objc(AYDeletedArchive)
class AYDeletedArchive: NSObject {
	private static let storageKey = "ayTELEDeletedDetailsV1"
	private static let limit = 5000
	private static let lock = NSLock()

	private struct Detail: Codable {
		var text: String
		var chat: String?      // peer key
		var from: String?      // peer key or "me"
		var chatName: String?  // resolved names, kept even if AYPeerNames forgets them
		var fromName: String?
	}

	private static var store: [String: Detail] = {
		guard let data = UserDefaults.standard.data(forKey: storageKey),
		      let decoded = try? JSONDecoder().decode([String: Detail].self, from: data) else { return [:] }
		return decoded
	}()

	private static func persistLocked() {
		if store.count > limit {
			let live = Set(AYDeletedMarks.deletedKeys())
			store = store.filter { live.contains($0.key) }
		}
		if let data = try? JSONEncoder().encode(store) {
			UserDefaults.standard.set(data, forKey: storageKey)
		}
	}

	// "c123:9" -> "c123" (channels carry their chat in the key; private/basic-group keys don't).
	private static func chatFromKey(_ key: String) -> String? {
		guard key.hasPrefix("c"), let colon = key.firstIndex(of: ":") else { return nil }
		return String(key[..<colon])
	}

	static func freeze(_ keys: [String]) {
		var details: [String: Detail] = [:]
		for key in keys {
			let seen = AYEditHistory.latest(forKey: key)
			let chat = seen?.chat ?? chatFromKey(key)
			let from = seen?.from
			details[key] = Detail(text: seen?.text ?? "", chat: chat, from: from,
			                      chatName: AYPeerNames.name(chat), fromName: AYPeerNames.name(from))
		}
		lock.lock()
		for (key, detail) in details where store[key] == nil || store[key]?.text.isEmpty == true {
			store[key] = detail
		}
		persistLocked()
		lock.unlock()
	}

	// Fill gaps from a deleted message the user is looking at in the chat (Postbox still has it).
	private static var tried = Set<String>() // once per key per launch; layout calls this a lot
	@objc static func backfill(node: NSObject) {
		guard let key = AYDeletedMarks.key(node: node) else { return }
		lock.lock()
		let current = store[key]
		let first = tried.insert(key).inserted
		lock.unlock()
		guard first else { return }
		if let c = current, !c.text.isEmpty, c.chatName != nil, c.fromName != nil { return }
		guard let message = AYDeletedMarks.messageObject(node) else { return }
		let mirror = Mirror(reflecting: message)
		var detail = current ?? Detail(text: "", chat: chatFromKey(key), from: nil, chatName: nil, fromName: nil)
		if detail.text.isEmpty, let text = AYDeletedMarks.child(mirror, "text") as? String {
			detail.text = text
		}
		if detail.fromName == nil, let author = AYDeletedMarks.child(mirror, "author") {
			detail.fromName = peerDisplayName(author)
		}
		if detail.chatName == nil, let peers = AYDeletedMarks.child(mirror, "peers"),
		   let messageId = AYDeletedMarks.child(mirror, "id"),
		   let peerId = AYDeletedMarks.child(Mirror(reflecting: messageId), "peerId") {
			let wanted = "\(peerId)"
			detail.chatName = findPeer(in: peers, id: wanted).flatMap(peerDisplayName)
		}
		lock.lock()
		store[key] = detail
		persistLocked()
		lock.unlock()
	}

	// TelegramUser (firstName/lastName/username) or TelegramChannel/TelegramGroup (title).
	static func peerDisplayName(_ peer: Any) -> String? {
		let m = Mirror(reflecting: peer)
		if let title = AYDeletedMarks.child(m, "title") as? String, !title.isEmpty { return title }
		let parts = [AYDeletedMarks.child(m, "firstName") as? String, AYDeletedMarks.child(m, "lastName") as? String]
			.compactMap { $0 }.filter { !$0.isEmpty }
		if !parts.isEmpty { return parts.joined(separator: " ") }
		if let username = AYDeletedMarks.child(m, "username") as? String, !username.isEmpty { return "@" + username }
		return nil
	}

	// Message.peers is a SimpleDictionary<PeerId, Peer>; find the peer whose id matches.
	private static func findPeer(in container: Any, id: String) -> Any? {
		var queue: [(Any, Int)] = [(container, 0)]
		while !queue.isEmpty {
			let (value, depth) = queue.removeFirst()
			let m = Mirror(reflecting: value)
			if m.displayStyle == .class, let pid = AYDeletedMarks.child(m, "id"), "\(pid)" == id,
			   peerDisplayName(value) != nil {
				return value
			}
			if depth < 4 {
				queue.append(contentsOf: m.children.compactMap { c in AYDeletedMarks.unwrap(c.value).map { ($0, depth + 1) } })
			}
		}
		return nil
	}

	// [key, text, chat name, sender name] for the browse screen.
	static func row(forKey key: String) -> [String] {
		lock.lock()
		let d = store[key]
		lock.unlock()
		let seen = AYEditHistory.latest(forKey: key)
		let text = (d?.text.isEmpty == false ? d?.text : nil) ?? seen?.text ?? ""
		let chatKey = d?.chat ?? seen?.chat ?? chatFromKey(key)
		let fromKey = d?.from ?? seen?.from
		let chatName = d?.chatName ?? AYPeerNames.name(chatKey) ?? ""
		let fromName = fromKey == "me" ? "me" : (d?.fromName ?? AYPeerNames.name(fromKey) ?? "")
		return [key, text, chatName, fromName]
	}
}
