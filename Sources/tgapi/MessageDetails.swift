import Foundation

// Full message info (#30). Reads the Postbox Message behind a chat node via reflection and returns
// label/value pairs for the info sheet. Labels are localization keys resolved on the ObjC side.
@objc(AYMessageDetails)
class AYMessageDetails: NSObject {

	// Returns [[localizationKey, value], ...] describing the message under this node.
	@objc static func lines(node: NSObject) -> [[String]] {
		guard let message = AYDeletedMarks.messageObject(node) else { return [] }
		let mirror = Mirror(reflecting: message)
		var out: [[String]] = []

		if let idValue = AYDeletedMarks.child(mirror, "id") {
			let idMirror = Mirror(reflecting: idValue)
			if let id = AYDeletedMarks.integer(AYDeletedMarks.child(idMirror, "id")) {
				out.append(["MSG_INFO_ID", "\(id)"])
			}
			if let peerId = AYDeletedMarks.child(idMirror, "peerId") {
				let peerMirror = Mirror(reflecting: peerId)
				let ns = AYDeletedMarks.integer(AYDeletedMarks.child(peerMirror, "namespace"))
				if let pid = AYDeletedMarks.integer(AYDeletedMarks.child(peerMirror, "id")) {
					out.append(["MSG_INFO_CHAT", peerLabel(ns) + "\(pid)"])
				}
			}
		}

		if let author = AYDeletedMarks.child(mirror, "author") {
			let authorMirror = Mirror(reflecting: author)
			let idValue = AYDeletedMarks.child(authorMirror, "id") ?? author
			if let aid = AYDeletedMarks.integer(AYDeletedMarks.child(Mirror(reflecting: idValue), "id"))
				?? AYDeletedMarks.integer(idValue) {
				out.append(["MSG_INFO_SENDER", "\(aid)"])
			}
		}

		if let ts = AYDeletedMarks.integer(AYDeletedMarks.child(mirror, "timestamp")) {
			out.append(["MSG_INFO_SENT", format(ts)])
		}

		// Edit date from a TelegramCore.EditedMessageAttribute in the attributes array.
		if let attributes = AYDeletedMarks.child(mirror, "attributes") {
			for attr in Mirror(reflecting: attributes).children.map({ $0.value }) {
				let typeName = String(describing: type(of: attr))
				if typeName.contains("Edited"),
				   let date = AYDeletedMarks.integer(AYDeletedMarks.child(Mirror(reflecting: attr), "date")) {
					out.append(["MSG_INFO_EDITED", format(date)])
				}
			}
		}

		// Media: file datacenter, size, type.
		if let media = AYDeletedMarks.child(mirror, "media") {
			for item in Mirror(reflecting: media).children.map({ $0.value }) {
				appendMedia(item, into: &out)
			}
		}

		return out
	}

	private static func appendMedia(_ media: Any, into out: inout [[String]]) {
		let mirror = Mirror(reflecting: media)
		if let mime = AYDeletedMarks.child(mirror, "mimeType") as? String {
			out.append(["MSG_INFO_MIME", mime])
		}
		if let name = AYDeletedMarks.child(mirror, "fileName") as? String {
			out.append(["MSG_INFO_FILENAME", name])
		}
		if let size = AYDeletedMarks.integer(AYDeletedMarks.child(mirror, "size")) {
			out.append(["MSG_INFO_SIZE", byteString(size)])
		}
		if let resource = AYDeletedMarks.child(mirror, "resource") {
			let rMirror = Mirror(reflecting: resource)
			if let dc = AYDeletedMarks.integer(AYDeletedMarks.child(rMirror, "datacenterId")) {
				out.append(["MSG_INFO_DC", "DC\(dc)"])
			}
			if AYDeletedMarks.child(mirror, "size") == nil,
			   let size = AYDeletedMarks.integer(AYDeletedMarks.child(rMirror, "size")) {
				out.append(["MSG_INFO_SIZE", byteString(size)])
			}
		}
	}

	private static func peerLabel(_ namespace: Int64?) -> String {
		switch namespace {
		case 2: return "channel #"
		case 1: return "group #"
		default: return "user #"
		}
	}

	private static func format(_ ts: Int64) -> String {
		let df = DateFormatter()
		df.dateStyle = .medium
		df.timeStyle = .medium
		return df.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
	}

	private static func byteString(_ bytes: Int64) -> String {
		let units = ["B", "KB", "MB", "GB"]
		var value = Double(bytes)
		var i = 0
		while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
		return i == 0 ? "\(bytes) B" : String(format: "%.2f %@", value, units[i])
	}
}
