import Foundation

// Peer keys shared by the held read-receipt queue (Hooks.xm) and the "reveal" action,
// so a blocked messages/channels.readHistory can be matched to the chat it belongs to.
//   "u<id>" user · "g<id>" basic group · "c<id>" channel/supergroup · "s:<peer>" stories
@objc(AYReceipts)
class AYReceipts: NSObject {
	private static let messagesReadHistory: Int32 = 238054714
	private static let channelsReadHistory: Int32 = -871347913
	private static let storiesReadStories: Int32 = -1521034552

	@objc static func peerKey(payload: NSData) -> String? {
		let reader = BufferReader(Buffer(nsData: payload))
		guard let function = reader.readInt32(), let signature = reader.readInt32() else { return nil }
		let object = Api.parse(reader, signature: signature)
		switch function {
		case messagesReadHistory:
			return (object as? Api.InputPeer).flatMap(key)
		case channelsReadHistory:
			if case let .inputChannel(channelId, _)? = object as? Api.InputChannel { return "c\(channelId)" }
			if case let .inputChannelFromMessage(_, _, channelId)? = object as? Api.InputChannel { return "c\(channelId)" }
			return nil
		case storiesReadStories:
			return (object as? Api.InputPeer).flatMap(key).map { "s:\($0)" }
		default:
			return nil
		}
	}

	private static func key(_ peer: Api.InputPeer) -> String? {
		switch peer {
		case let .inputPeerUser(userId, _), let .inputPeerUserFromMessage(_, _, userId):
			return "u\(userId)"
		case let .inputPeerChat(chatId):
			return "g\(chatId)"
		case let .inputPeerChannel(channelId, _), let .inputPeerChannelFromMessage(_, _, channelId):
			return "c\(channelId)"
		default:
			return nil
		}
	}

	// Chat key for the message behind a ChatMessageItemView node.
	@objc static func peerKey(node: NSObject) -> String? {
		guard let message = AYDeletedMarks.messageObject(node),
		      let messageId = AYDeletedMarks.child(Mirror(reflecting: message), "id"),
		      let peerId = AYDeletedMarks.child(Mirror(reflecting: messageId), "peerId") else { return nil }
		let peerMirror = Mirror(reflecting: peerId)
		guard let namespace = AYDeletedMarks.integer(AYDeletedMarks.child(peerMirror, "namespace")),
		      let id = AYDeletedMarks.integer(AYDeletedMarks.child(peerMirror, "id")) else { return nil }
		switch namespace {
		case 0: return "u\(id)" // CloudUser
		case 1: return "g\(id)" // CloudGroup
		case 2: return "c\(id)" // CloudChannel
		default: return nil
		}
	}
}
