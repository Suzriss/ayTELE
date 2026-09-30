import Foundation

// Walks raw TL bytes with the layer schema embedded in TLSchemaData.swift (the layer Telegram
// actually speaks), copying them out and clearing chosen flag bits on the way. Unlike Api.parse,
// it knows every current constructor, and it never re-serializes: bytes it doesn't touch come
// out exactly as they went in.
final class AYTLSchema {
	indirect enum TypeRef {
		case int, long, double, bytes, flags
		case bareTrue                 // `true`: no bytes
		case boxed                    // any boxed type: constructor id + body
		case bare(UInt32)             // bare constructor, by id
		case vector(TypeRef, boxed: Bool)
	}

	struct Field {
		let name: String
		let type: TypeRef
		let condition: (flags: Int, bit: Int)? // index of the flags field in `fields`
	}

	struct Constructor {
		let name: String
		let fields: [Field]
	}

	static let shared = AYTLSchema(AYTLSchemaText)

	private(set) var constructors: [UInt32: Constructor] = [:]
	private var idsByName: [String: UInt32] = [:]

	init(_ text: String) {
		var pending: [(UInt32, String, [(String, String)])] = []
		for line in text.split(separator: "\n") {
			let parts = line.split(separator: " ")
			guard let head = parts.first, let hash = head.firstIndex(of: "#"),
				let id = UInt32(head[head.index(after: hash)...], radix: 16) else { continue }
			let name = String(head[..<hash])
			var fields: [(String, String)] = []
			for part in parts.dropFirst() {
				if part == "=" { break }
				guard let colon = part.firstIndex(of: ":") else { continue }
				fields.append((String(part[..<colon]), String(part[part.index(after: colon)...])))
			}
			idsByName[name] = id
			pending.append((id, name, fields))
		}
		for (id, name, raw) in pending {
			var fields: [Field] = []
			for (fieldName, rawType) in raw {
				var type = Substring(rawType)
				var condition: (Int, Int)?
				if let q = type.firstIndex(of: "?"), let dot = type.firstIndex(of: ".") {
					let flagsName = String(type[..<dot])
					let bit = Int(type[type.index(after: dot)..<q]) ?? 0
					let index = fields.firstIndex { $0.name == flagsName } ?? 0
					condition = (index, bit)
					type = type[type.index(after: q)...]
				}
				fields.append(Field(name: fieldName, type: resolve(type), condition: condition))
			}
			constructors[id] = Constructor(name: name, fields: fields)
		}
	}

	private func resolve(_ type: Substring) -> TypeRef {
		switch type {
		case "int": return .int
		case "long": return .long
		case "double": return .double
		case "string", "bytes": return .bytes
		case "#": return .flags
		case "true": return .bareTrue
		default: break
		}
		for (prefix, boxed) in [("Vector<", true), ("vector<", false)] where type.hasPrefix(prefix) {
			return .vector(resolve(type.dropFirst(prefix.count).dropLast()), boxed: boxed)
		}
		// messages.Messages is boxed, messages.messages bare: the case of the last part decides.
		let last = type.split(separator: ".").last ?? type
		if last.first?.isLowercase == true, let id = idsByName[String(type)] { return .bare(id) }
		return .boxed
	}

	func id(of name: String) -> UInt32? { idsByName[name] }
}

// A flag bit to clear on one constructor. dropsField: the field that bit guards, taken out
// with it. onlyIf: a bit (same flags field) that must be set too, or nothing is cleared.
struct AYTLClear {
	let constructor: String
	let flags: String
	let bit: Int
	var dropsField: String? = nil
	var onlyIf: Int? = nil
}

final class AYTLWalker {
	enum Result { case unchanged, changed(Data), unknown }

	private struct Rule { let flagsIndex: Int; let mask: UInt32; let drops: Int?; let onlyIf: UInt32? }

	private let schema: AYTLSchema
	private var rules: [UInt32: [Rule]] = [:]

	init(schema: AYTLSchema = .shared, clears: [AYTLClear]) {
		self.schema = schema
		for clear in clears {
			guard let id = schema.id(of: clear.constructor), let c = schema.constructors[id],
				let flagsIndex = c.fields.firstIndex(where: { $0.name == clear.flags }) else { continue }
			let drops = clear.dropsField.flatMap { name in c.fields.firstIndex { $0.name == name } }
			rules[id, default: []].append(Rule(flagsIndex: flagsIndex, mask: 1 << UInt32(clear.bit), drops: drops, onlyIf: clear.onlyIf.map { 1 << UInt32($0) }))
		}
	}

	private struct Unknown: Error {}

	private var input = Data()
	private var pos = 0
	private var out = Data()
	private var changed = false

	// Walks one boxed object (a pushed update or an RPC result) that must fill all of data.
	func walk(_ data: Data) -> Result {
		input = data
		pos = 0
		out = Data()
		out.reserveCapacity(data.count)
		changed = false
		defer { input = Data(); out = Data() }
		do {
			let id = try peekId()
			if id == 0x1cb5c415 {
				// A top-level vector's element type isn't in the bytes: walk it only as boxed objects.
				try vector(of: .boxed, boxed: true)
			} else {
				try boxed()
			}
		} catch {
			return .unknown
		}
		guard pos == input.count else { return .unknown }
		return changed ? .changed(out) : .unchanged
	}

	private func peekId() throws -> UInt32 {
		guard pos + 4 <= input.count else { throw Unknown() }
		return input.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt32.self) }
	}

	private func copy(_ count: Int) throws {
		guard count >= 0, pos + count <= input.count else { throw Unknown() }
		out.append(input[(input.startIndex + pos)..<(input.startIndex + pos + count)])
		pos += count
	}

	private func skip(_ count: Int) throws {
		guard pos + count <= input.count else { throw Unknown() }
		pos += count
	}

	private func readUInt32() throws -> UInt32 {
		let value = try peekId()
		pos += 4
		return value
	}

	private func write(_ value: UInt32) {
		withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
	}

	private func bytesLength() throws -> Int {
		guard pos < input.count else { throw Unknown() }
		let first = Int(input[input.startIndex + pos])
		if first < 254 {
			return (1 + first + 3) & ~3
		}
		guard pos + 4 <= input.count else { throw Unknown() }
		let b = input.startIndex + pos
		let length = Int(input[b + 1]) | Int(input[b + 2]) << 8 | Int(input[b + 3]) << 16
		return (4 + length + 3) & ~3
	}

	private func value(_ type: AYTLSchema.TypeRef, emit: Bool) throws {
		let move: (Int) throws -> Void = emit ? self.copy : self.skip
		switch type {
		case .int, .flags: try move(4)
		case .long, .double: try move(8)
		case .bytes: try move(try bytesLength())
		case .bareTrue: break
		case .boxed:
			if emit { try boxed() } else { try skipBoxed() }
		case .bare(let id):
			if emit { try body(id) } else { try skipBody(id) }
		case .vector(let element, let boxed):
			if emit { try vector(of: element, boxed: boxed) } else { try skipVector(of: element, boxed: boxed) }
		}
	}

	private func vector(of element: AYTLSchema.TypeRef, boxed: Bool) throws {
		if boxed {
			guard try readUInt32() == 0x1cb5c415 else { throw Unknown() }
			write(0x1cb5c415)
		}
		let count = try readUInt32()
		guard count <= UInt32(input.count - pos) else { throw Unknown() } // every element is at least a byte
		write(count)
		for _ in 0..<count { try value(element, emit: true) }
	}

	private func skipVector(of element: AYTLSchema.TypeRef, boxed: Bool) throws {
		if boxed { guard try readUInt32() == 0x1cb5c415 else { throw Unknown() } }
		let count = try readUInt32()
		guard count <= UInt32(input.count - pos) else { throw Unknown() }
		for _ in 0..<count { try value(element, emit: false) }
	}

	private func boxed() throws {
		let id = try readUInt32()
		write(id)
		try body(id)
	}

	private func skipBoxed() throws {
		try skipBody(try readUInt32())
	}

	private func body(_ id: UInt32) throws {
		guard let c = schema.constructors[id] else { throw Unknown() }
		guard let rules = rules[id] else {
			var flags: [Int: UInt32] = [:]
			for (i, field) in c.fields.enumerated() {
				if let cond = field.condition, (flags[cond.flags] ?? 0) & (1 << UInt32(cond.bit)) == 0 { continue }
				if case .flags = field.type {
					flags[i] = try peekId()
				}
				try value(field.type, emit: true)
			}
			return
		}
		var flags: [Int: UInt32] = [:]
		var dropped = Set<Int>()
		for (i, field) in c.fields.enumerated() {
			if let cond = field.condition, (flags[cond.flags] ?? 0) & (1 << UInt32(cond.bit)) == 0 { continue }
			if case .flags = field.type {
				let original = try readUInt32()
				flags[i] = original
				var cleared = original
				for rule in rules where rule.flagsIndex == i && original & rule.mask != 0 {
					if let onlyIf = rule.onlyIf, original & onlyIf == 0 { continue }
					cleared &= ~rule.mask
					if let drops = rule.drops { dropped.insert(drops) }
				}
				if cleared != original { changed = true }
				write(cleared)
				continue
			}
			try value(field.type, emit: !dropped.contains(i))
		}
	}

	private func skipBody(_ id: UInt32) throws {
		guard let c = schema.constructors[id] else { throw Unknown() }
		var flags: [Int: UInt32] = [:]
		for (i, field) in c.fields.enumerated() {
			if let cond = field.condition, (flags[cond.flags] ?? 0) & (1 << UInt32(cond.bit)) == 0 { continue }
			if case .flags = field.type { flags[i] = try peekId() }
			try value(field.type, emit: false)
		}
	}
}
