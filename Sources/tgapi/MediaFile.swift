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
		return walk(root).0
	}

	// Same walk, but returns a human-readable trace of what it saw alongside the size, so the ObjC
	// save path can log why a story resolved to a photo (e.g. the media was never reached, or it was
	// reached but had size 0). Returns "size|debug".
	// Returns "size|fileId|dc|debug". fileId is the resource's file id (0 if unknown); the ObjC save
	// path uses it to find the cached file by name when a story video is not stored by its byte size.
	@objc static func videoByteSizeDebugFrom(_ root: NSObject?) -> String {
		let (size, fileId, dc, debug) = walk(root)
		return "\(size?.int64Value ?? 0)|\(fileId)|\(dc)|\(debug)"
	}

	private static func walk(_ root: NSObject?) -> (NSNumber?, Int64, Int64, String) {
		guard let root = root else { return (nil, 0, 0, "nil root") }
		var queue: [(Any, Int)] = [(root, 0)]
		var visited = 0
		var maxDepth = 0
		var mediaSeen = 0
		var firstAnyFileNote = ""
		// Walk a bit wider/deeper than before: the story media sits behind the per-item component
		// state, and the earlier 9/6000 bound could be exhausted by the view's own model first.
		while !queue.isEmpty && visited < 20000 {
			let (value, depth) = queue.removeFirst()
			visited += 1
			if depth > maxDepth { maxDepth = depth }
			if depth > 14 { continue }
			let mirror = Mirror(reflecting: value)
			let typeName = String(describing: mirror.subjectType)
			if typeName.contains("TelegramMediaFile") {
				mediaSeen += 1
				let mime = (child(mirror, "mimeType") as? String) ?? "-"
				let sz = integer(child(mirror, "size")) ?? integer(child(Mirror(reflecting: child(mirror, "resource") ?? 0), "size")) ?? 0
				if firstAnyFileNote.isEmpty { firstAnyFileNote = "file(mime=\(mime),size=\(sz))" }
				if let size = videoSize(value, mirror) {
					let (fileId, dc) = resourceIds(mirror)
					return (NSNumber(value: size), fileId, dc, "found video size=\(size) fileId=\(fileId) dc=\(dc) after \(visited) nodes, depth\(maxDepth)")
				}
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
		let debug = "no video: \(visited) nodes, depth\(maxDepth), mediaFiles=\(mediaSeen)\(firstAnyFileNote.isEmpty ? "" : ", first \(firstAnyFileNote)")"
		return (nil, 0, 0, debug)
	}

	// The resource's (fileId, datacenterId) for a media file, read by reflection. MediaBox names the
	// cached file from these, so they let us find a story video that is not stored by its byte size.
	private static func resourceIds(_ fileMirror: Mirror) -> (Int64, Int64) {
		guard let resource = child(fileMirror, "resource") else { return (0, 0) }
		let rm = Mirror(reflecting: resource)
		let fileId = integer(child(rm, "fileId")) ?? integer(child(rm, "id")) ?? 0
		let dc = integer(child(rm, "datacenterId")) ?? 0
		return (fileId, dc)
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
