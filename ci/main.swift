import Foundation

UserDefaults.standard.set(true, forKey: "keepDeletedMessages")
var failures = 0
func ser(_ o: Any) -> NSData { let b = Buffer(); Api.serializeObject(o, buffer: b, boxed: true); return b.makeData() as NSData }
func check(_ name: String, _ input: Any, _ expected: Any?) {
    let data = ser(input)
    let out = AYDeletedFilter.filter(data)
    let got: String
    if let out = out, let parsed = Api.parse(Buffer(nsData: out)) { got = "\(parsed)" } else { got = out == nil ? "nil" : "PARSE FAIL" }
    let want = expected.map { "\($0)" } ?? "nil"
    let ok = got == want
    if !ok { failures += 1 }
    print(ok ? "PASS" : "FAIL", name, ok ? "" : "\n  got:  \(got)\n  want: \(want)")
}

// Mirrors Postbox / ChatMessageItem shapes used by AYDeletedMarks.
struct PeerId { struct Namespace { let rawValue: Int32 }; struct Id { let rawValue: Int64 }; let namespace: Namespace; let id: Id }
struct MessageId { let peerId: PeerId; let namespace: Int32; let id: Int32 }
struct AuthorRef { let id: PeerId }
struct EditedMessageAttr { let date: Int32 }
final class Message {
	let stableId: UInt32 = 1
	let id: MessageId
	let timestamp: Int32
	let text: String
	let author: AuthorRef?
	let attributes: [Any]
	let media: [Any]
	init(_ id: MessageId, timestamp: Int32 = 0, text: String = "", author: AuthorRef? = nil, attributes: [Any] = [], media: [Any] = []) {
		self.id = id; self.timestamp = timestamp; self.text = text
		self.author = author; self.attributes = attributes; self.media = media
	}
}
enum ChatMessageItemContent { case message(message: Message, read: Bool); case group(messages: [(Message, Bool)]) }
final class ItemWithMessage { let context = 1; let message: Message; init(_ m: Message) { message = m } }
final class ItemWithContent { let content: ChatMessageItemContent; init(_ c: ChatMessageItemContent) { content = c } }
class ListViewItemNode: NSObject {}
class ChatMessageItemView: ListViewItemNode { var item: Any?; init(_ item: Any?) { self.item = item } }
final class BubbleNode: ChatMessageItemView { let backgroundNode = NSObject() }
func msg(_ ns: Int32, _ peer: Int64, _ id: Int32, mns: Int32 = 0) -> Message { Message(MessageId(peerId: PeerId(namespace: .init(rawValue: ns), id: .init(rawValue: peer)), namespace: mns, id: id)) }
func expect(_ name: String, _ v: Bool) { if !v { failures += 1 }; print(v ? "PASS" : "FAIL", name) }
let delP = Api.Update.updateDeleteMessages(messages: [5, 6, 7], pts: 100, ptsCount: 3)
let delP0 = Api.Update.updateDeleteMessages(messages: [], pts: 100, ptsCount: 3)
let delC = Api.Update.updateDeleteChannelMessages(channelId: 42, messages: [1, 2], pts: 10, ptsCount: 2)
let delC0 = Api.Update.updateDeleteChannelMessages(channelId: 42, messages: [], pts: 10, ptsCount: 2)
let other = Api.Update.updateChannelTooLong(flags: 1, channelId: 9, pts: 77)
let msg = Api.Message.messageEmpty(flags: 0, id: 3, peerId: nil)
let st = Api.updates.State.state(pts: 1, qts: 2, date: 3, seq: 4, unreadCount: 5)

check("updateShort", Api.Updates.updateShort(update: delP, date: 123), Api.Updates.updateShort(update: delP0, date: 123))
check("updates mixed", Api.Updates.updates(updates: [other, delC, other, delP, other], users: [], chats: [], date: 5, seq: 6),
      Api.Updates.updates(updates: [other, delC0, other, delP0, other], users: [], chats: [], date: 5, seq: 6))
check("updatesCombined", Api.Updates.updatesCombined(updates: [delP], users: [], chats: [], date: 5, seqStart: 1, seq: 6),
      Api.Updates.updatesCombined(updates: [delP0], users: [], chats: [], date: 5, seqStart: 1, seq: 6))
check("no deletions", Api.Updates.updates(updates: [other], users: [], chats: [], date: 5, seq: 6), nil)
check("difference", Api.updates.Difference.difference(newMessages: [msg], newEncryptedMessages: [], otherUpdates: [delP, other, delC], chats: [], users: [], state: st),
      Api.updates.Difference.difference(newMessages: [msg], newEncryptedMessages: [], otherUpdates: [delP0, other, delC0], chats: [], users: [], state: st))
check("differenceSlice", Api.updates.Difference.differenceSlice(newMessages: [], newEncryptedMessages: [], otherUpdates: [delC], chats: [], users: [], intermediateState: st),
      Api.updates.Difference.differenceSlice(newMessages: [], newEncryptedMessages: [], otherUpdates: [delC0], chats: [], users: [], intermediateState: st))
check("channelDifference+timeout", Api.updates.ChannelDifference.channelDifference(flags: 2, pts: 9, timeout: 30, newMessages: [msg, msg], otherUpdates: [other, delC], chats: [], users: []),
      Api.updates.ChannelDifference.channelDifference(flags: 2, pts: 9, timeout: 30, newMessages: [msg, msg], otherUpdates: [other, delC0], chats: [], users: []))
check("channelDifference", Api.updates.ChannelDifference.channelDifference(flags: 0, pts: 9, timeout: nil, newMessages: [], otherUpdates: [delC], chats: [], users: []),
      Api.updates.ChannelDifference.channelDifference(flags: 0, pts: 9, timeout: nil, newMessages: [], otherUpdates: [delC0], chats: [], users: []))
// Unknown constructor mid-vector: deletion before it is filtered, bytes after it untouched.
do {
    let b = Buffer(); b.appendInt32(1957577280); b.appendInt32(481674261); b.appendInt32(2)
    delC.serialize(b, true); b.appendInt32(0x0badf00d); b.appendInt32(7)
    let out = AYDeletedFilter.filter(b.makeData() as NSData)! as Data
    let expect = Buffer(); expect.appendInt32(1957577280); expect.appendInt32(481674261); expect.appendInt32(2)
    delC0.serialize(expect, true); expect.appendInt32(0x0badf00d); expect.appendInt32(7)
    let ok = out == expect.makeData(); if !ok { failures += 1 }
    print(ok ? "PASS" : "FAIL", "unknown constructor tail")
}
check("unrelated object", Api.Bool.boolTrue, nil)
_ = AYDeletedFilter.filter(ser(Api.Updates.updates(updates: [delC, delP], users: [], chats: [], date: 1, seq: 1)))
expect("channel msg marked", AYDeletedMarks.isDeleted(node: BubbleNode(ItemWithMessage(msg(2, 42, 1)))))
expect("channel other id not marked", !AYDeletedMarks.isDeleted(node: BubbleNode(ItemWithMessage(msg(2, 42, 3)))))
expect("other channel not marked", !AYDeletedMarks.isDeleted(node: BubbleNode(ItemWithMessage(msg(2, 43, 1)))))
expect("private msg marked", AYDeletedMarks.isDeleted(node: BubbleNode(ItemWithMessage(msg(0, 777, 6)))))
expect("basic group msg marked", AYDeletedMarks.isDeleted(node: BubbleNode(ItemWithMessage(msg(1, 5, 7)))))
expect("local namespace not marked", !AYDeletedMarks.isDeleted(node: BubbleNode(ItemWithMessage(msg(0, 777, 6, mns: 1)))))
expect("content .message", AYDeletedMarks.isDeleted(node: BubbleNode(ItemWithContent(.message(message: msg(2, 42, 2), read: true)))))
expect("content .group", AYDeletedMarks.isDeleted(node: BubbleNode(ItemWithContent(.group(messages: [(msg(0, 1, 5), true)])))))
expect("nil item", !AYDeletedMarks.isDeleted(node: BubbleNode(nil)))
expect("persisted", (UserDefaults.standard.stringArray(forKey: "ayTELEDeletedMessageKeys") ?? []).contains("c42:1"))

// ---- Edit history (AYEditHistory) ----
UserDefaults.standard.set(true, forKey: "keepEditHistory")
func tmsg(_ peer: Api.Peer, _ id: Int32, _ text: String, edit: Int32? = nil) -> Api.Message {
    let flags: Int32 = edit != nil ? (1 << 15) : 0
    return .message(flags: flags, flags2: 0, id: id, fromId: nil, fromBoostsApplied: nil, peerId: peer, savedPeerId: nil, fwdFrom: nil, viaBotId: nil, viaBusinessBotId: nil, replyTo: nil, date: 1000, message: text, media: nil, replyMarkup: nil, entities: nil, views: nil, forwards: nil, replies: nil, editDate: edit, postAuthor: nil, groupedId: nil, reactions: nil, restrictionReason: nil, ttlPeriod: nil, quickReplyShortcutId: nil, effect: nil, factcheck: nil, reportDeliveryUntilDate: nil, paidMessageStars: nil)
}
func obs(_ o: Any) { AYEditHistory.observe(ser(o)) }
func upd(_ u: Api.Update) -> Api.Updates { Api.Updates.updates(updates: [u], users: [], chats: [], date: 1, seq: 1) }
let peerU = Api.Peer.peerUser(userId: 555)
let peerC = Api.Peer.peerChannel(channelId: 99)

// A user message: seen new, then edited -> two versions, badge shown.
obs(upd(.updateNewMessage(message: tmsg(peerU, 30, "hello"), pts: 1, ptsCount: 1)))
expect("edit: single version -> not edited", !AYEditHistory.isEdited(key: "u:30"))
obs(upd(.updateEditMessage(message: tmsg(peerU, 30, "hello world", edit: 1100), pts: 2, ptsCount: 1)))
expect("edit: two versions -> edited", AYEditHistory.isEdited(key: "u:30"))
obs(upd(.updateEditMessage(message: tmsg(peerU, 30, "hello world", edit: 1100), pts: 3, ptsCount: 1)))
do {
    let node = BubbleNode(ItemWithMessage(msg(0, 555, 30)))
    let v = AYEditHistory.versions(node: node)
    let texts = v.map { $0.first ?? "" }
    expect("edit: version texts", texts == ["hello", "hello world"])
    expect("edit: dedup identical edit", v.count == 2)
}
// A channel message edited -> keyed by channel id.
obs(upd(.updateNewChannelMessage(message: tmsg(peerC, 7, "a"), pts: 1, ptsCount: 1)))
obs(upd(.updateEditChannelMessage(message: tmsg(peerC, 7, "b", edit: 1200), pts: 2, ptsCount: 1)))
expect("edit: channel edited", AYEditHistory.isEdited(key: "c99:7"))
expect("edit: channel node versions", AYEditHistory.versions(node: BubbleNode(ItemWithMessage(msg(2, 99, 7)))).map { $0.first ?? "" } == ["a", "b"])
expect("edit: unrelated not edited", !AYEditHistory.isEdited(key: "u:99999"))

// ---- Message details (AYMessageDetails, #30) ----
do {
	let author = AuthorRef(id: PeerId(namespace: .init(rawValue: 0), id: .init(rawValue: 55)))
	let m = Message(MessageId(peerId: PeerId(namespace: .init(rawValue: 0), id: .init(rawValue: 100)), namespace: 0, id: 7),
	                timestamp: 1000, text: "hi", author: author, attributes: [EditedMessageAttr(date: 1200)])
	let lines = AYMessageDetails.lines(node: BubbleNode(ItemWithMessage(m)))
	var d: [String: String] = [:]
	for l in lines where l.count >= 2 { d[l[0]] = l[1] }
	expect("info: id", d["MSG_INFO_ID"] == "7")
	expect("info: chat", d["MSG_INFO_CHAT"] == "user #100")
	expect("info: sender", d["MSG_INFO_SENDER"] == "55")
	expect("info: sent present", d["MSG_INFO_SENT"] != nil)
	expect("info: edited present", d["MSG_INFO_EDITED"] != nil)
	expect("info: empty node", AYMessageDetails.lines(node: BubbleNode(nil)).isEmpty)
}

// ---- Private notes (AYNotes, #27) ----
do {
	let node = BubbleNode(ItemWithMessage(Message(MessageId(peerId: PeerId(namespace: .init(rawValue: 0), id: .init(rawValue: 100)), namespace: 0, id: 9), text: "remember this message")))
	expect("note: none initially", !AYNotes.hasNote(node: node))
	AYNotes.setNote(node: node, text: "  reply later  ")
	expect("note: added", AYNotes.hasNote(node: node))
	expect("note: trimmed text", AYNotes.note(node: node) == "reply later")
	expect("note: listed with snippet", AYNotes.all().contains { $0.count >= 3 && $0[0] == "u:9" && $0[2].hasPrefix("remember") })
	AYNotes.setNote(node: node, text: "   ")
	expect("note: cleared by blank", !AYNotes.hasNote(node: node))
}

// ---- Archive browse lists (#56) ----
do {
	// editedList: only messages with >1 version, latest text + count.
	let edited = AYEditHistory.editedList()
	expect("archive: edited has u:30", edited.contains { $0.first == "u:30" && $0.count >= 3 && $0[1] == "hello world" && $0[2] == "2" })
	expect("archive: edited excludes single-version", !edited.contains { $0.first == "u:99999" })
	// text(forKey:) returns latest observed text.
	expect("archive: text for key", AYEditHistory.text(forKey: "c99:7") == "b")
	// deletedList carries captured text when we saw the message.
	obs(upd(.updateNewMessage(message: tmsg(peerU, 61, "to be deleted"), pts: 1, ptsCount: 1)))
	_ = AYDeletedFilter.filter(ser(Api.Updates.updates(updates: [Api.Update.updateDeleteMessages(messages: [61], pts: 1, ptsCount: 1)], users: [], chats: [], date: 1, seq: 1)))
	let deleted = AYDeletedMarks.deletedList()
	expect("archive: deleted lists u:61 with text", deleted.contains { $0.first == "u:61" && $0.count >= 2 && $0[1] == "to be deleted" })
}

// AYProtected: story noforwards (flags.10) and media ttl_seconds (flags.2).
do {
	let d = UserDefaults.standard
	let photo = Api.MessageMedia.messageMediaPhoto(flags: (1 << 0) | (1 << 2), photo: .photoEmpty(id: 1), ttlSeconds: 0x7FFFFFFF)
	let photoKept = Api.MessageMedia.messageMediaPhoto(flags: 1 << 0, photo: .photoEmpty(id: 1), ttlSeconds: nil)
	let expired = Api.MessageMedia.messageMediaPhoto(flags: 1 << 2, photo: nil, ttlSeconds: 10)
	let doc = Api.MessageMedia.messageMediaDocument(flags: (1 << 0) | (1 << 2), document: .documentEmpty(id: 2), altDocuments: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: 30)
	let docKept = Api.MessageMedia.messageMediaDocument(flags: 1 << 0, document: .documentEmpty(id: 2), altDocuments: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil)
	func story(_ flags: Int32) -> Api.StoryItem { .storyItem(flags: flags, id: 5, date: 1, fromId: nil, fwdFrom: nil, expireDate: 2, caption: nil, entities: nil, media: photoKept, mediaAreas: nil, privacy: nil, views: nil, sentReaction: nil) }
	let peer = Api.Peer.peerUser(userId: 7)
	func pushed(_ u: Api.Update) -> NSData { ser(Api.Updates.updates(updates: [u], users: [], chats: [], date: 1, seq: 1)) }
	func mediaMsg(_ m: Api.MessageMedia) -> Api.Update { .updateNewMessage(message: .message(flags: 1 << 9, flags2: 0, id: 1, fromId: nil, fromBoostsApplied: nil, peerId: peer, savedPeerId: nil, fwdFrom: nil, viaBotId: nil, viaBusinessBotId: nil, replyTo: nil, date: 1, message: "", media: m, replyMarkup: nil, entities: nil, views: nil, forwards: nil, replies: nil, editDate: nil, postAuthor: nil, groupedId: nil, reactions: nil, restrictionReason: nil, ttlPeriod: nil, quickReplyShortcutId: nil, effect: nil, factcheck: nil, reportDeliveryUntilDate: nil, paidMessageStars: nil), pts: 1, ptsCount: 1) }
	func reparsed(_ data: NSData?) -> String { data.flatMap { Api.parse(Buffer(nsData: $0)) }.map { "\($0)" } ?? "nil" }
	func str(_ u: Api.Update) -> String { "\(Api.Updates.updates(updates: [u], users: [], chats: [], date: 1, seq: 1))" }

	d.set(false, forKey: "disableForwardRestriction"); d.set(false, forKey: "keepViewOnceMedia")
	expect("protected: off -> untouched", AYProtected.filter(pushed(mediaMsg(photo))) == nil)

	d.set(true, forKey: "keepViewOnceMedia")
	expect("protected: photo ttl dropped", reparsed(AYProtected.filter(pushed(mediaMsg(photo)))) == str(mediaMsg(photoKept)))
	expect("protected: document ttl dropped", reparsed(AYProtected.filter(pushed(mediaMsg(doc)))) == str(mediaMsg(docKept)))
	expect("protected: expired placeholder untouched", AYProtected.filter(pushed(mediaMsg(expired))) == nil)
	expect("protected: plain media untouched", AYProtected.filter(pushed(mediaMsg(photoKept))) == nil)
	expect("protected: story kept protected without save toggle", AYProtected.filter(pushed(.updateStory(peer: peer, story: story(1 << 10)))) == nil)

	d.set(true, forKey: "disableForwardRestriction"); d.set(false, forKey: "keepViewOnceMedia")
	expect("protected: story noforwards dropped", reparsed(AYProtected.filter(pushed(.updateStory(peer: peer, story: story((1 << 10) | (1 << 5)))))) == str(.updateStory(peer: peer, story: story(1 << 5))))
	expect("protected: ttl kept without view-once toggle", AYProtected.filter(pushed(mediaMsg(photo))) == nil)
	// Chats pushed alongside updates: channel noforwards (flags.27), basic group noforwards (flags.25).
	func channel(_ flags: Int32) -> Api.Chat { .channel(flags: flags, flags2: 0, id: 9, accessHash: nil, title: "C", username: nil, photo: .chatPhotoEmpty, date: 1, restrictionReason: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, participantsCount: nil, usernames: nil, storiesMaxId: nil, color: nil, profileColor: nil, emojiStatus: nil, level: nil, subscriptionUntilDate: nil, botVerificationIcon: nil, sendPaidMessagesStars: nil) }
	func group(_ flags: Int32) -> Api.Chat { .chat(flags: flags, id: 8, title: "G", photo: .chatPhotoEmpty, participantsCount: 2, date: 1, version: 1, migratedTo: nil, adminRights: nil, defaultBannedRights: nil) }
	func withChats(_ chats: [Api.Chat]) -> Api.Updates { .updates(updates: [], users: [], chats: chats, date: 1, seq: 1) }
	expect("protected: channel noforwards dropped", reparsed(AYProtected.filter(ser(withChats([channel(1 << 27)])))) == "\(withChats([channel(0)]))")
	expect("protected: group noforwards dropped", reparsed(AYProtected.filter(ser(withChats([group(1 << 25)])))) == "\(withChats([group(0)]))")
	expect("protected: unprotected chats untouched", AYProtected.filter(ser(withChats([channel(0), group(0)]))) == nil)
	func textMsg(_ flags: Int32) -> Api.Update { .updateNewMessage(message: .message(flags: flags, flags2: 0, id: 1, fromId: nil, fromBoostsApplied: nil, peerId: peer, savedPeerId: nil, fwdFrom: nil, viaBotId: nil, viaBusinessBotId: nil, replyTo: nil, date: 1, message: "hi", media: nil, replyMarkup: nil, entities: nil, views: nil, forwards: nil, replies: nil, editDate: nil, postAuthor: nil, groupedId: nil, reactions: nil, restrictionReason: nil, ttlPeriod: nil, quickReplyShortcutId: nil, effect: nil, factcheck: nil, reportDeliveryUntilDate: nil, paidMessageStars: nil), pts: 1, ptsCount: 1) }
	expect("protected: message noforwards dropped", reparsed(AYProtected.filter(pushed(textMsg(1 << 26)))) == str(textMsg(0)))
	d.set(false, forKey: "disableForwardRestriction")
	expect("protected: channel kept protected without save toggle", AYProtected.filter(ser(withChats([channel(1 << 27)]))) == nil)
}

// AYReceipts: chat key of a held readHistory / readStories payload.
do {
	func payload(_ function: Int32, _ object: Any, maxId: Int32 = 9) -> NSData {
		let b = Buffer(); b.appendInt32(function); Api.serializeObject(object, buffer: b, boxed: true); b.appendInt32(maxId); return b.makeData() as NSData
	}
	expect("receipts: user readHistory", AYReceipts.peerKey(payload: payload(238054714, Api.InputPeer.inputPeerUser(userId: 42, accessHash: 1))) == "u42")
	expect("receipts: chat readHistory", AYReceipts.peerKey(payload: payload(238054714, Api.InputPeer.inputPeerChat(chatId: 5))) == "g5")
	expect("receipts: channels readHistory", AYReceipts.peerKey(payload: payload(-871347913, Api.InputChannel.inputChannel(channelId: 77, accessHash: 3))) == "c77")
	expect("receipts: readStories", AYReceipts.peerKey(payload: payload(-1521034552, Api.InputPeer.inputPeerUser(userId: 42, accessHash: 1))) == "s:u42")
	expect("receipts: other function", AYReceipts.peerKey(payload: payload(1, Api.InputPeer.inputPeerSelf)) == nil)
	expect("receipts: node user", AYReceipts.peerKey(node: BubbleNode(ItemWithMessage(msg(0, 42, 1)))) == "u42")
	final class TelegramUserMock { let id: PeerId; init(_ id: PeerId) { self.id = id } }
	enum EnginePeerMock { case user(TelegramUserMock) }
	struct SliceMock { let peer: EnginePeerMock }
	struct ComponentMock { let context = TelegramUserMock(PeerId(namespace: .init(rawValue: 0), id: .init(rawValue: 1))); let slice: SliceMock }
	final class StoryViewMock: NSObject { var component: ComponentMock?; init(_ c: ComponentMock?) { component = c } }
	let storyPeer = PeerId(namespace: .init(rawValue: 0), id: .init(rawValue: 42))
	expect("receipts: story view peer", AYReceipts.storyKey(view: StoryViewMock(ComponentMock(slice: SliceMock(peer: .user(TelegramUserMock(storyPeer)))))) == "s:u42")
	expect("receipts: story view without component", AYReceipts.storyKey(view: StoryViewMock(nil)) == nil)
	expect("receipts: node channel", AYReceipts.peerKey(node: BubbleNode(ItemWithMessage(msg(2, 77, 1)))) == "c77")
}

// Deleted archive: text, chat title and sender name survive the deletion.
do {
	let user = Api.User.user(flags: (1 << 1) | (1 << 2), flags2: 0, id: 777, accessHash: nil, firstName: "Ali", lastName: "Hasan", username: nil, phone: nil, photo: nil, status: nil, botInfoVersion: nil, restrictionReason: nil, botInlinePlaceholder: nil, langCode: nil, emojiStatus: nil, usernames: nil, storiesMaxId: nil, color: nil, profileColor: nil, botActiveUsers: nil, botVerificationIcon: nil, sendPaidMessagesStars: nil)
	let channel = Api.Chat.channel(flags: 0, flags2: 0, id: 4242, accessHash: nil, title: "Friends", username: nil, photo: .chatPhotoEmpty, date: 1, restrictionReason: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil, participantsCount: nil, usernames: nil, storiesMaxId: nil, color: nil, profileColor: nil, emojiStatus: nil, level: nil, subscriptionUntilDate: nil, botVerificationIcon: nil, sendPaidMessagesStars: nil)
	let groupMsg = Api.Message.message(flags: 1 << 8, flags2: 0, id: 70, fromId: .peerUser(userId: 777), fromBoostsApplied: nil, peerId: .peerChannel(channelId: 4242), savedPeerId: nil, fwdFrom: nil, viaBotId: nil, viaBusinessBotId: nil, replyTo: nil, date: 1, message: "secret", media: nil, replyMarkup: nil, entities: nil, views: nil, forwards: nil, replies: nil, editDate: nil, postAuthor: nil, groupedId: nil, reactions: nil, restrictionReason: nil, ttlPeriod: nil, quickReplyShortcutId: nil, effect: nil, factcheck: nil, reportDeliveryUntilDate: nil, paidMessageStars: nil)
	obs(Api.Updates.updates(updates: [.updateNewChannelMessage(message: groupMsg, pts: 1, ptsCount: 1)], users: [user], chats: [channel], date: 1, seq: 1))
	_ = AYDeletedFilter.filter(ser(Api.Updates.updates(updates: [.updateDeleteChannelMessages(channelId: 4242, messages: [70], pts: 1, ptsCount: 1)], users: [], chats: [], date: 1, seq: 1)))
	let row = AYDeletedMarks.deletedList().first { $0.first == "c4242:70" } ?? []
	expect("deleted archive: text/chat/sender \(row)", row == ["c4242:70", "secret", "Friends", "Ali Hasan"])
	// Private chat, incoming: sender is the chat peer.
	obs(Api.Updates.updates(updates: [.updateNewMessage(message: tmsg(.peerUser(userId: 777), 71, "hi"), pts: 1, ptsCount: 1)], users: [user], chats: [], date: 1, seq: 1))
	_ = AYDeletedFilter.filter(ser(Api.Updates.updates(updates: [.updateDeleteMessages(messages: [71], pts: 1, ptsCount: 1)], users: [], chats: [], date: 1, seq: 1)))
	let row2 = AYDeletedMarks.deletedList().first { $0.first == "u:71" } ?? []
	expect("deleted archive: private \(row2)", row2 == ["u:71", "hi", "Ali Hasan", "Ali Hasan"])
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
