import Foundation
import UserNotifications
import UIKit

// Keyword alerts (#22): scans incoming updates for the user's words and raises a local
// notification (and an in-app banner when Telegram is in the foreground), even for muted chats.
//
// It walks the raw layer-229 bytes with the same schema AYTLWalker uses — read-only, it only reads
// the `message:string` field out of incoming `message` / `updateShortMessage` /
// `updateShortChatMessage` constructors and never changes a byte. Outgoing messages (the `out`
// flag) are ignored. Called from the parseMessage hook inside an @try, so any mis-parse is harmless.

@objc(AYKeywordAlert)
final class AYKeywordAlert: NSObject {

	// Words the user is watching for, lower-cased. Stored by the settings editor as one string.
	private static func keywords() -> [String] {
		guard let raw = UserDefaults.standard.string(forKey: "ayTELEKeywords") else { return [] }
		let separators = CharacterSet(charactersIn: ",،\n;")
		return raw.components(separatedBy: separators)
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
			.filter { !$0.isEmpty }
	}

	private static var authorizationAsked = false
	private static var lastSnippet = ""
	private static var lastTime: TimeInterval = 0

	@objc static func scan(_ data: Data) -> String? {
		let words = keywords()
		if words.isEmpty { return nil }
		requestAuthorizationOnce()

		let scanner = Scanner(schema: .shared)
		let texts = scanner.scan(data)
		if texts.isEmpty { return nil }

		for text in texts {
			let lower = text.lowercased()
			guard let hit = words.first(where: { lower.contains($0) }) else { continue }
			let snippet = String(text.prefix(140))
			// Collapse duplicate deliveries of the same message within a few seconds.
			let now = Date().timeIntervalSince1970
			if snippet == lastSnippet && now - lastTime < 5 { return snippet }
			lastSnippet = snippet
			lastTime = now
			notify(keyword: hit, snippet: snippet)
			return snippet
		}
		return nil
	}

	private static func requestAuthorizationOnce() {
		if authorizationAsked { return }
		authorizationAsked = true
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
	}

	private static func notify(keyword: String, snippet: String) {
		// Background: a real local notification.
		let content = UNMutableNotificationContent()
		content.title = "🔔 " + keyword
		content.body = snippet
		content.sound = .default
		let request = UNNotificationRequest(identifier: "ayTELE.keyword." + UUID().uuidString, content: content, trigger: nil)
		UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)

		// Foreground: iOS lets the host app suppress banners, so show our own lightweight one.
		DispatchQueue.main.async {
			if UIApplication.shared.applicationState == .active {
				banner("🔔 " + keyword + " — " + snippet)
			}
		}
	}

	// Self-dismissing banner at the top of the key window (Swift-only, no ObjC dependency).
	private static func banner(_ text: String) {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		guard let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })
			?? scenes.flatMap({ $0.windows }).first else { return }
		let label = PaddedLabel()
		label.text = text
		label.textColor = .white
		label.backgroundColor = UIColor(white: 0, alpha: 0.85)
		label.font = .systemFont(ofSize: 14, weight: .medium)
		label.numberOfLines = 2
		label.layer.cornerRadius = 14
		label.clipsToBounds = true
		label.alpha = 0
		let maxW = window.bounds.width - 32
		let fit = label.sizeThatFits(CGSize(width: maxW, height: 200))
		let w = min(maxW, fit.width)
		let h = fit.height
		let top = window.safeAreaInsets.top + 8
		label.frame = CGRect(x: (window.bounds.width - w) / 2, y: top, width: w, height: h)
		window.addSubview(label)
		UIView.animate(withDuration: 0.25, animations: { label.alpha = 1 }) { _ in
			UIView.animate(withDuration: 0.3, delay: 2.2, options: [], animations: { label.alpha = 0 }) { _ in
				label.removeFromSuperview()
			}
		}
	}

	private final class PaddedLabel: UILabel {
		private let inset = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
		override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
		override var intrinsicContentSize: CGSize {
			let s = super.intrinsicContentSize
			return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
		}
		override func sizeThatFits(_ size: CGSize) -> CGSize {
			let inner = CGSize(width: size.width - inset.left - inset.right, height: size.height)
			let s = super.sizeThatFits(inner)
			return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
		}
	}

	// -- Read-only TL walk ---------------------------------------------------

	private final class Scanner {
		private struct Unknown: Error {}
		private let schema: AYTLSchema
		private let targets: Set<UInt32>
		private var input = Data()
		private var pos = 0
		private var found: [String] = []

		init(schema: AYTLSchema) {
			self.schema = schema
			var ids = Set<UInt32>()
			for name in ["message", "updateShortMessage", "updateShortChatMessage"] {
				if let id = schema.id(of: name) { ids.insert(id) }
			}
			targets = ids
		}

		func scan(_ data: Data) -> [String] {
			input = data; pos = 0; found = []
			defer { input = Data() }
			do {
				let id = try peekId()
				if id == 0x1cb5c415 { try vector(of: .boxed, boxed: true) } else { try boxed() }
			} catch {
				// Best-effort: whatever was read at correct offsets before the error still stands.
			}
			return found
		}

		private func peekId() throws -> UInt32 {
			guard pos + 4 <= input.count else { throw Unknown() }
			return input.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt32.self) }
		}
		private func readUInt32() throws -> UInt32 { let v = try peekId(); pos += 4; return v }
		private func skip(_ count: Int) throws {
			guard count >= 0, pos + count <= input.count else { throw Unknown() }
			pos += count
		}
		private func bytesLength() throws -> Int {
			guard pos < input.count else { throw Unknown() }
			let first = Int(input[input.startIndex + pos])
			if first < 254 { return (1 + first + 3) & ~3 }
			guard pos + 4 <= input.count else { throw Unknown() }
			let b = input.startIndex + pos
			let length = Int(input[b + 1]) | Int(input[b + 2]) << 8 | Int(input[b + 3]) << 16
			return (4 + length + 3) & ~3
		}
		private func readString() throws -> String? {
			guard pos < input.count else { throw Unknown() }
			let total = try bytesLength()
			guard pos + total <= input.count else { throw Unknown() }
			let first = Int(input[input.startIndex + pos])
			let contentStart: Int, contentLen: Int
			if first < 254 { contentStart = pos + 1; contentLen = first }
			else {
				let b = input.startIndex + pos
				contentStart = pos + 4
				contentLen = Int(input[b + 1]) | Int(input[b + 2]) << 8 | Int(input[b + 3]) << 16
			}
			let lo = input.startIndex + contentStart
			let str = String(data: input.subdata(in: lo..<(lo + contentLen)), encoding: .utf8)
			pos += total
			return str
		}

		private func value(_ type: AYTLSchema.TypeRef) throws {
			switch type {
			case .int, .flags: try skip(4)
			case .long, .double: try skip(8)
			case .bytes: try skip(try bytesLength())
			case .bareTrue: break
			case .boxed: try body(try readUInt32())
			case .bare(let id): try body(id)
			case .vector(let element, let boxed): try vector(of: element, boxed: boxed)
			}
		}

		private func vector(of element: AYTLSchema.TypeRef, boxed: Bool) throws {
			if boxed { guard try readUInt32() == 0x1cb5c415 else { throw Unknown() } }
			let count = try readUInt32()
			guard count <= UInt32(input.count - pos) else { throw Unknown() }
			for _ in 0..<count { try value(element) }
		}

		private func boxed() throws { try body(try readUInt32()) }

		private func body(_ id: UInt32) throws {
			guard let c = schema.constructors[id] else { throw Unknown() }
			let isTarget = targets.contains(id)
			var flags: [Int: UInt32] = [:]
			var outSet = false
			for (i, field) in c.fields.enumerated() {
				if let cond = field.condition, (flags[cond.flags] ?? 0) & (1 << UInt32(cond.bit)) == 0 { continue }
				if case .flags = field.type {
					let f = try readUInt32()
					flags[i] = f
					if isTarget && field.name == "flags" { outSet = (f & 0x2) != 0 } // out = flags.1
					continue
				}
				if isTarget && field.name == "message", case .bytes = field.type {
					let s = try readString()
					if !outSet, let s = s, !s.isEmpty { found.append(s) }
					continue
				}
				try value(field.type)
			}
		}
	}
}
