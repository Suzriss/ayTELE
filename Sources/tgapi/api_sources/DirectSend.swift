import Foundation

// Builds raw MTProto request payloads for sending a voice message without the mic — the technique
// iQTele uses: upload the OGG/Opus bytes with upload.saveFilePart, then messages.sendMedia with an
// inputMediaUploadedDocument carrying the voice attributes. Serialization follows the layer-229
// schema in ci/api.tl exactly; the ObjC side (AYVoiceSend) issues these through a captured
// MTRequestMessageService. v1 targets Saved Messages (inputPeerSelf) to prove the pipeline.
@objc(AYDirectSend)
public class AYDirectSend: NSObject {

	private static func fid(_ v: UInt32) -> Int32 { return Int32(bitPattern: v) }

	// upload.saveFilePart#b304a621 file_id:long file_part:int bytes:bytes = Bool;
	@objc public static func saveFilePart(fileId: Int64, part: Int32, chunk: Data) -> Data {
		let b = Buffer()
		b.appendInt32(fid(0xb304a621))
		b.appendInt64(fileId)
		b.appendInt32(part)
		serializeBytes(Buffer(data: chunk), buffer: b, boxed: false)
		return b.makeData()
	}

	// messages.sendMedia to Saved Messages with the uploaded file as a voice document.
	@objc public static func sendVoiceToSelf(fileId: Int64, parts: Int32, duration: Int32, waveform: Data?, randomId: Int64) -> Data {
		let b = Buffer()
		// messages.sendMedia#330e77f flags:# peer:InputPeer media:InputMedia message:string random_id:long ...
		b.appendInt32(fid(0x0330e77f))
		b.appendInt32(0)                      // flags: none (no reply_to, silent, etc.)
		b.appendInt32(fid(0x7da07ec9))        // peer: inputPeerSelf#7da07ec9
		appendUploadedVoice(b, fileId: fileId, parts: parts, duration: duration, waveform: waveform)
		serializeString("", buffer: b, boxed: false)   // message
		b.appendInt64(randomId)               // random_id
		return b.makeData()
	}

	// inputMediaUploadedDocument#37c9330 ... file:InputFile mime_type:string attributes:Vector<DocumentAttribute>
	private static func appendUploadedVoice(_ b: Buffer, fileId: Int64, parts: Int32, duration: Int32, waveform: Data?) {
		b.appendInt32(fid(0x037c9330))
		b.appendInt32(0)                      // flags: no thumb/stickers/ttl/spoiler
		// file: inputFile#f52ff27f id:long parts:int name:string md5_checksum:string
		b.appendInt32(fid(0xf52ff27f))
		b.appendInt64(fileId)
		b.appendInt32(parts)
		serializeString("voice.ogg", buffer: b, boxed: false)
		serializeString("", buffer: b, boxed: false)
		serializeString("audio/ogg", buffer: b, boxed: false)   // mime_type
		// attributes: Vector<DocumentAttribute> = [documentAttributeAudio]
		b.appendInt32(fid(0x1cb5c415))        // vector
		b.appendInt32(1)                      // count
		// documentAttributeAudio#9852f9c6 flags:# voice:flags.10?true duration:int waveform:flags.2?bytes
		b.appendInt32(fid(0x9852f9c6))
		var flags: Int32 = (1 << 10)          // voice
		if waveform != nil { flags |= (1 << 2) }
		b.appendInt32(flags)
		b.appendInt32(duration)
		if let wf = waveform {
			serializeBytes(Buffer(data: wf), buffer: b, boxed: false)
		}
	}
}
