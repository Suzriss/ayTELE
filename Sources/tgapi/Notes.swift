import Foundation

// Private per-message notes (#27). A note is stored locally, keyed the same way as deleted/edited
// marks, and never sent anywhere. The other party can't see it. One screen lists every note.
@objc(AYNotes)
class AYNotes: NSObject {
	@objc static let changedNotification = Notification.Name("ayTELENotesChanged")
	private static let storageKey = "ayTELENotesV1"

	private struct Note: Codable {
		var text: String
		var snippet: String
		var date: Double
	}

	private static let lock = NSLock()
	private static var store: [String: Note] = load()

	private static func load() -> [String: Note] {
		guard let data = UserDefaults.standard.data(forKey: storageKey),
		      let decoded = try? JSONDecoder().decode([String: Note].self, from: data) else { return [:] }
		return decoded
	}

	private static func persist() {
		guard let data = try? JSONEncoder().encode(store) else { return }
		UserDefaults.standard.set(data, forKey: storageKey)
	}

	@objc static func hasNote(node: NSObject) -> Bool {
		guard let key = AYDeletedMarks.key(node: node) else { return false }
		lock.lock(); defer { lock.unlock() }
		return store[key] != nil
	}

	@objc static func note(node: NSObject) -> String? {
		guard let key = AYDeletedMarks.key(node: node) else { return nil }
		lock.lock(); defer { lock.unlock() }
		return store[key]?.text
	}

	// Empty / whitespace text removes the note.
	@objc static func setNote(node: NSObject, text: String) {
		guard let key = AYDeletedMarks.key(node: node) else { return }
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		lock.lock()
		if trimmed.isEmpty {
			store[key] = nil
		} else {
			store[key] = Note(text: trimmed, snippet: snippet(node), date: Date().timeIntervalSince1970)
		}
		persist()
		lock.unlock()
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: changedNotification, object: nil)
		}
	}

	// All notes as [[key, text, snippet, dateString]], newest first, for the list screen.
	@objc static func all() -> [[String]] {
		lock.lock(); defer { lock.unlock() }
		return store.sorted { $0.value.date > $1.value.date }.map {
			[$0.key, $0.value.text, $0.value.snippet, "\(Int($0.value.date))"]
		}
	}

	private static func snippet(_ node: NSObject) -> String {
		guard let message = AYDeletedMarks.messageObject(node),
		      let text = AYDeletedMarks.child(Mirror(reflecting: message), "text") as? String else { return "" }
		let oneLine = text.replacingOccurrences(of: "\n", with: " ")
		return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
	}
}
