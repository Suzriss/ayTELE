import Foundation

// Keeps messages that other people delete.
// Deletions reach the client as updateDeleteMessages / updateDeleteChannelMessages, either pushed
// (Updates) or inside updates.getDifference / getChannelDifference results. We empty the id vector
// of those updates in the raw TL bytes and leave pts / pts_count untouched, so the client's pts
// sequence stays consistent (no gap -> no refetch) while nothing gets deleted locally.
// Only the id bytes are removed; everything else is passed through byte for byte.
@objc(AYDeletedFilter)
class AYDeletedFilter: NSObject {
	private static let vectorID: Int32 = 481674261                 // vector#1cb5c415
	private static let updateDeleteMessages: Int32 = -1576161051    // updateDeleteMessages#a20db0e5
	private static let updateDeleteChannelMessages: Int32 = -1020437742 // updateDeleteChannelMessages#c32d5b12
	private static let updateShort: Int32 = 2027216577              // updateShort#78d4dec1
	private static let updates: Int32 = 1957577280                  // updates#74ae4240
	private static let updatesCombined: Int32 = 1918567619          // updatesCombined#725b04c3
	private static let difference: Int32 = 16030880                 // updates.difference#f49ca0
	private static let differenceSlice: Int32 = -1459938943         // updates.differenceSlice#a8fb1981
	private static let channelDifference: Int32 = 543450958         // updates.channelDifference#2064674e

	@objc static var isEnabled: Bool {
		return UserDefaults.standard.bool(forKey: "keepDeletedMessages")
	}

	// Returns filtered data, or nil when nothing was changed.
	@objc static func filter(_ data: NSData) -> NSData? {
		let bytes = data as Data
		guard bytes.count >= 8 else { return nil }
		let reader = BufferReader(Buffer(nsData: data))
		guard let signature = reader.readInt32() else { return nil }

		var cuts: [Range<Int>] = []
		switch signature {
		case updateShort:
			checkDeletion(at: 4, in: bytes, cuts: &cuts)
		case updates, updatesCombined:
			scanUpdates(reader, bytes: bytes, cuts: &cuts)
		case difference, differenceSlice:
			guard skipVector(reader, type: Api.Message.self),
			      skipVector(reader, type: Api.EncryptedMessage.self) else { break }
			scanUpdates(reader, bytes: bytes, cuts: &cuts)
		case channelDifference:
			guard let flags = reader.readInt32(), reader.readInt32() != nil else { break }
			if flags & (1 << 1) != 0 { reader.skip(4) }
			guard skipVector(reader, type: Api.Message.self) else { break }
			scanUpdates(reader, bytes: bytes, cuts: &cuts)
		default:
			return nil
		}

		if cuts.isEmpty { return nil }
		return apply(cuts, to: bytes) as NSData
	}

	// Walks a boxed Vector<Update>, recording deletions. Stops at the first element it cannot parse;
	// bytes after that point are left as they are.
	private static func scanUpdates(_ reader: BufferReader, bytes: Data, cuts: inout [Range<Int>]) {
		guard reader.readInt32() == vectorID, let count = reader.readInt32(), count >= 0 else { return }
		for _ in 0 ..< count {
			let start = Int(reader.offset)
			guard let signature = reader.readInt32() else { return }
			checkDeletion(at: start, in: bytes, cuts: &cuts)
			guard Api.parse(reader, signature: signature) != nil else { return }
		}
	}

	private static func skipVector<T>(_ reader: BufferReader, type: T.Type) -> Bool {
		guard reader.readInt32() == vectorID else { return false }
		return Api.parseVector(reader, elementSignature: 0, elementType: type) != nil
	}

	private static func checkDeletion(at offset: Int, in bytes: Data, cuts: inout [Range<Int>]) {
		guard let signature = int32(bytes, offset) else { return }
		let vectorOffset: Int
		switch signature {
		case updateDeleteMessages:
			vectorOffset = offset + 4
		case updateDeleteChannelMessages:
			vectorOffset = offset + 12 // after channel_id:long
		default:
			return
		}
		guard int32(bytes, vectorOffset) == vectorID,
		      let count = int32(bytes, vectorOffset + 4), count > 0, count < 100_000 else { return }
		let idsStart = vectorOffset + 8
		let idsEnd = idsStart + Int(count) * 4
		guard idsEnd + 8 <= bytes.count else { return } // pts + pts_count must follow
		cuts.append(idsStart ..< idsEnd)
	}

	// Removes each id range and zeroes the vector count stored just before it.
	private static func apply(_ cuts: [Range<Int>], to bytes: Data) -> Data {
		var out = Data(capacity: bytes.count)
		var cursor = 0
		for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) where cut.lowerBound >= cursor + 4 {
			out.append(bytes[cursor ..< cut.lowerBound - 4])
			var zero: Int32 = 0
			out.append(Data(bytes: &zero, count: 4))
			cursor = cut.upperBound
		}
		out.append(bytes[cursor ..< bytes.count])
		return out
	}

	private static func int32(_ bytes: Data, _ offset: Int) -> Int32? {
		guard offset >= 0, offset + 4 <= bytes.count else { return nil }
		var value: Int32 = 0
		withUnsafeMutableBytes(of: &value) { dst in
			bytes.copyBytes(to: dst.bindMemory(to: UInt8.self), from: bytes.startIndex + offset ..< bytes.startIndex + offset + 4)
		}
		return value
	}
}
