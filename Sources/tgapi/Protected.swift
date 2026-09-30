import Foundation

// Strips "protected" TL flags from Telegram's responses and pushed updates:
//   message / storyItem / ephemeralMessage / chat / channel .noforwards
//   userFull.noforwards_my_enabled / noforwards_peer_enabled (private-chat protection)
//                                                   -> gated by "disableForwardRestriction"
//   messageMediaPhoto/Document.ttl_seconds (flags.2) -> gated by "keepViewOnceMedia"
// AYTLWalker does it on the raw bytes with Telegram's own layer. Only when it meets a
// constructor that layer doesn't have does the older Api parser get a try. Untouched data
// reaches Telegram byte-for-byte either way.
@objc(AYProtected)
class AYProtected: NSObject {
	private static let clearedKey = "ayProtectedCleared"

	static var allowSave: Bool { UserDefaults.standard.bool(forKey: "disableForwardRestriction") }
	static var keepViewOnce: Bool { UserDefaults.standard.bool(forKey: "keepViewOnceMedia") }

	@objc static var isEnabled: Bool { allowSave || keepViewOnce }

	private static let saveClears = [
		AYTLClear(constructor: "message", flags: "flags", bit: 26),
		AYTLClear(constructor: "storyItem", flags: "flags", bit: 10),
		AYTLClear(constructor: "ephemeralMessage", flags: "flags", bit: 12),
		AYTLClear(constructor: "chat", flags: "flags", bit: 25),
		AYTLClear(constructor: "channel", flags: "flags", bit: 27),
		AYTLClear(constructor: "userFull", flags: "flags2", bit: 23),
		AYTLClear(constructor: "userFull", flags: "flags2", bit: 24),
	]
	// Only while the photo/document is there (flags.0): an expired placeholder stays as is.
	private static let viewOnceClears = [
		AYTLClear(constructor: "messageMediaPhoto", flags: "flags", bit: 2, dropsField: "ttl_seconds", onlyIf: 0),
		AYTLClear(constructor: "messageMediaDocument", flags: "flags", bit: 2, dropsField: "ttl_seconds", onlyIf: 0),
	]

	// Called by the Api parsers when they drop a flag, so filter(_:) knows to re-serialize.
	static func noteCleared() {
		Thread.current.threadDictionary[clearedKey] = true
	}

	@objc static func filter(_ data: NSData) -> NSData? {
		guard isEnabled else { return nil }
		let clears = (allowSave ? saveClears : []) + (keepViewOnce ? viewOnceClears : [])
		switch AYTLWalker(clears: clears).walk(data as Data) {
		case .changed(let out): return out as NSData
		case .unchanged: return nil
		case .unknown: return legacyFilter(data)
		}
	}

	private static func legacyFilter(_ data: NSData) -> NSData? {
		let dict = Thread.current.threadDictionary
		dict[clearedKey] = false
		defer { dict.removeObject(forKey: clearedKey) }
		guard let parsed = Api.parse(Buffer(nsData: data)) else { return nil }
		guard (dict[clearedKey] as? Bool) == true else { return nil }
		let out = Buffer()
		Api.serializeObject(parsed, buffer: out, boxed: true)
		return out.makeData() as NSData
	}
}
