import Foundation

// Builds and reads the raw MTProto payload for messages.translateText (#25). Telegram's own
// translation runs server-side — we send the draft text and a target language, and read the
// translated string back. No Swift hooks: the ObjC side (AYTranslateRunner) issues the request
// through the same captured MTRequestMessageService the voice send uses. Layer-229 exact, from
// ci/api.tl:
//   messages.translateText#a5eec345 flags:# peer:flags.0?InputPeer id:flags.0?Vector<int>
//       text:flags.1?Vector<TextWithEntities> to_lang:string tone:flags.2?string = messages.TranslatedText;
//   textWithEntities#751f3146 text:string entities:Vector<MessageEntity> = TextWithEntities;
//   messages.translateResult#33db32f8 result:Vector<TextWithEntities> = messages.TranslatedText;
@objc(AYTranslate)
public class AYTranslate: NSObject {

	private static func fid(_ v: UInt32) -> Int32 { return Int32(bitPattern: v) }

	// Request payload: translate a free-standing text (no peer / no message id) to `toLang`.
	@objc public static func buildTranslateText(_ text: String, toLang: String) -> Data {
		let b = Buffer()
		b.appendInt32(fid(0xa5eec345))
		b.appendInt32(1 << 1)                         // flags: only `text` present
		// text: Vector<TextWithEntities> with a single element.
		b.appendInt32(fid(0x1cb5c415))                // vector
		b.appendInt32(1)                              // count
		b.appendInt32(fid(0x751f3146))                // textWithEntities
		serializeString(text, buffer: b, boxed: false)
		b.appendInt32(fid(0x1cb5c415))                // entities: empty vector
		b.appendInt32(0)
		serializeString(toLang, buffer: b, boxed: false) // to_lang
		return b.makeData()
	}

	// Pulls the first translated string out of a messages.translateResult response.
	@objc public static func parseTranslated(_ data: Data) -> String? {
		var pos = 0
		func u32() -> UInt32? {
			guard pos + 4 <= data.count else { return nil }
			let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt32.self) }
			pos += 4
			return v
		}
		guard let ctor = u32(), ctor == 0x33db32f8 else { return nil } // messages.translateResult
		guard let magic = u32(), magic == 0x1cb5c415 else { return nil } // vector
		guard let count = u32(), count >= 1 else { return nil }
		guard let elem = u32(), elem == 0x751f3146 else { return nil }    // textWithEntities
		// read string
		guard pos < data.count else { return nil }
		let first = Int(data[data.startIndex + pos])
		let contentStart: Int, contentLen: Int
		if first < 254 { contentStart = pos + 1; contentLen = first }
		else {
			let x = data.startIndex + pos
			contentStart = pos + 4
			contentLen = Int(data[x + 1]) | Int(data[x + 2]) << 8 | Int(data[x + 3]) << 16
		}
		let lo = data.startIndex + contentStart
		guard lo + contentLen <= data.endIndex else { return nil }
		return String(data: data.subdata(in: lo..<(lo + contentLen)), encoding: .utf8)
	}
}
