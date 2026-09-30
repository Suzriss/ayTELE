import Foundation

// Finds the byte size of the video shown in a story / view-once viewer, so the Save button can
// match it against the exact file already sitting in the Postbox media cache (DeletedBadge.xm does
// the file lookup and the save). We only reflect — reading the real file path needs MediaBox, a
// free Swift API with no ObjC symbol to call. Matching on the exact byte size is safe: it either
// finds that one file or nothing, never someone else's video.
@objc(AYMediaFile)
class AYMediaFile: NSObject {

	// Breadth-first, depth- and count-bounded walk of a viewer object graph for a TelegramMediaFile
	// that is a video; returns its size in bytes, or nil if none is found.
	@objc static func videoByteSizeFrom(_ root: NSObject?) -> NSNumber? {
		guard let root = root else { return nil }
		var queue: [(Any, Int)] = [(root, 0)]
		var visited = 0
		while !queue.isEmpty && visited < 6000 {
			let (value, depth) = queue.removeFirst()
			visited += 1
			if depth > 9 { continue }
			let mirror = Mirror(reflecting: value)
			let typeName = String(describing: mirror.subjectType)
			if typeName.contains("TelegramMediaFile") {
				if let size = videoSize(value, mirror) { return NSNumber(value: size) }
			}
			for child in mirror.children {
				let cv = child.value
				switch Mirror(reflecting: cv).displayStyle {
				case .some(.class), .some(.struct), .some(.enum),
				     .some(.optional), .some(.collection), .some(.tuple), .some(.set), .some(.dictionary):
					queue.append((cv, depth + 1))
				default:
					break  // skip scalars/strings to keep the walk bounded
				}
			}
		}
		return nil
	}

	// Returns the byte size only when the media file looks like a video (mime or a video attribute).
	private static func videoSize(_ value: Any, _ mirror: Mirror) -> Int64? {
		var isVideo = false
		if let mime = child(mirror, "mimeType") as? String, mime.hasPrefix("video") { isVideo = true }
		if !isVideo, let attrs = child(mirror, "attributes") {
			for attr in Mirror(reflecting: attrs).children.map({ $0.value }) {
				if String(describing: type(of: attr)).contains("Video") { isVideo = true; break }
			}
		}
		guard isVideo else { return nil }
		if let size = integer(child(mirror, "size")), size > 0 { return size }
		if let resource = child(mirror, "resource"),
		   let size = integer(child(Mirror(reflecting: resource), "size")), size > 0 { return size }
		return nil
	}

	// Value of a named stored property, unwrapping one level of Optional.
	private static func child(_ mirror: Mirror, _ label: String) -> Any? {
		for c in mirror.children where c.label == label {
			let m = Mirror(reflecting: c.value)
			if m.displayStyle == .optional { return m.children.first?.value }
			return c.value
		}
		return nil
	}

	// A signed integer out of Int/Int32/Int64/UInt.. (also unwrapping Optionals).
	private static func integer(_ any: Any?) -> Int64? {
		guard var any = any else { return nil }
		let m = Mirror(reflecting: any)
		if m.displayStyle == .optional {
			guard let first = m.children.first?.value else { return nil }
			any = first
		}
		switch any {
		case let v as Int64: return v
		case let v as Int: return Int64(v)
		case let v as Int32: return Int64(v)
		case let v as UInt32: return Int64(v)
		case let v as UInt64: return Int64(bitPattern: v)
		case let v as UInt: return Int64(v)
		default: return nil
		}
	}
}
