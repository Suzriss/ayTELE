import Foundation

// Strips "protected" TL flags while Telegram's responses are re-parsed:
//   storyItem.noforwards (flags.10)             -> gated by "disableForwardRestriction"
//   message.noforwards (flags.26)               -> gated by "disableForwardRestriction"
//   messageMediaPhoto/Document.ttl_seconds (flags.2) -> gated by "keepViewOnceMedia"
// RPC results already get re-serialized by TLParser; pushed updates only when a flag
// was actually cleared, so untouched updates reach Telegram byte-for-byte.
@objc(AYProtected)
class AYProtected: NSObject {
	private static let clearedKey = "ayProtectedCleared"

	static var allowSave: Bool { UserDefaults.standard.bool(forKey: "disableForwardRestriction") }
	static var keepViewOnce: Bool { UserDefaults.standard.bool(forKey: "keepViewOnceMedia") }

	@objc static var isEnabled: Bool { allowSave || keepViewOnce }

	// Called by the Api parsers when they drop a flag, so filter(_:) knows to re-serialize.
	static func noteCleared() {
		Thread.current.threadDictionary[clearedKey] = true
	}

	@objc static func filter(_ data: NSData) -> NSData? {
		guard isEnabled else { return nil }
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
