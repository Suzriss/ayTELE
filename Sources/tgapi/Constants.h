#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define kAccountUpdateOnlineStatus 1713919532
#define kMessagesSetTypingAction 1486110434
#define kMessagesReadHistory 238054714
#define kStoriesReadStories -1521034552
// stories.incrementStoryViews#b2028afb -> Bool (Api38)
#define kStoriesIncrementStoryViews -1308456197
#define kGetSponsoredMessages -1680673735

#define kActionIDTyping                 381645902                       // .sendMessageTypingAction
#define kActionIDRecordingVideo        -1584933265                     // .sendMessageRecordVideoAction
#define kActionIDUploadingVideo        -378127636                      // .sendMessageUploadVideoAction
#define kActionIDRecordingAudio        -718310409                      // .sendMessageRecordAudioAction
#define kActionIDUploadingVoice        -212740181                      // .sendMessageUploadAudioAction
#define kActionIDUploadingPhoto        -774682074                      // .sendMessageUploadPhotoAction
#define kActionIDUploadingFile         -1441998364                     // .sendMessageUploadDocumentAction
#define kActionIDChoosingLocation      393186209                       // .sendMessageGeoLocationAction
#define kActionIDChoosingContact       1653390447                      // .sendMessageChooseContactAction
#define kActionIDPlayingGame           -580219064                      // .sendMessageGamePlayAction
#define kActionIDRecordingRoundVideo   -1997373508                     // .sendMessageRecordRoundAction
#define kActionIDUploadingRoundVideo   608050278                       // .sendMessageUploadRoundAction
#define kActionIDSpeakingInGroupCall   -651419003                      // .speakingInGroupCallAction
#define kActionIDReserverHistoryImport -606432698                      // .sendMessageHistoryImportAction
#define kActionIDChoosingSticker       -1336228175                     // .sendMessageChooseStickerAction
#define kActionIDEmojiInteraction      630664139                       // .sendMessageEmojiInteraction
#define kActionIDEmojiAcknowledgement -1234857938                      // .sendMessageEmojiInteractionSeen

#define kDisableOnlineStatus @"disableOnlineStatus"

#define kDisableTypingStatus @"disableTypingStatus"
#define kDisableRecordingVideoStatus @"disableRecordingVideoStatus"
#define kDisableUploadingVideoStatus @"disableUploadingVideoStatus"
#define kDisableRecordingVoiceStatus @"disableRecordingVoiceStatus"
#define kDisableUploadingVoiceStatus @"disableUploadingVoiceStatus"
#define kDisableUploadingPhotoStatus @"disableUploadingPhotoStatus"
#define kDisableUploadingFileStatus @"disableUploadingFileStatus"
#define kDisableChoosingLocationStatus @"disableChoosingLocationStatus"
#define kDisableChoosingContactStatus @"disableChoosingContactStatus"
#define kDisablePlayingGameStatus @"disablePlayingGameStatus"
#define kDisableRecordingRoundVideoStatus @"disableRecordingRoundVideoStatus"
#define kDisableUploadingRoundVideoStatus @"disableUploadingRoundVideoStatus"
#define kDisableSpeakingInGroupCallStatus @"disableSpeakingInGroupCallStatus"
#define kDisableChoosingStickerStatus @"disableChoosingStickerStatus"
#define kDisableEmojiInteractionStatus @"disableEmojiInteractionStatus"
#define kDisableEmojiAcknowledgementStatus @"disableEmojiAcknowledgementStatus"


#define kDisableMessageReadReceipt @"disableMessageReadReceipt"
#define kDisableStoriesReadReceipt @"disableStoriesReadReceipt"

// Content-view receipts: sent when you play a voice/video note, watch a round
// video, or open a view-once media. Blocking these lets you view/play silently.
// Verified against the repo's own TL schema (Api38):
//   messages.readMessageContents#369e4f38  -> constructor 916930423  (messages.AffectedMessages)
//   channels.readMessageContents#eab5dc38  -> constructor -357180360 (Bool)
#define kMessagesReadMessageContents 916930423
#define kChannelsReadMessageContents -357180360
#define kDisableReadMessageContents @"disableReadMessageContents"

#define kDisableAllAds @"disableOnlineStatus"
#define kDisableForwardRestriction @"disableForwardRestriction"
#define kKeepDeletedMessages @"keepDeletedMessages"
#define kKeepEditHistory @"keepEditHistory"

// Drops ttl_seconds from photo/video media so view-once and self-destructing media
// become ordinary, savable messages (read by AYProtected in Swift under the same key).
#define kKeepViewOnceMedia @"keepViewOnceMedia"

// Adds our own Save button to the story viewer and the view-once/self-destruct media
// viewer. Captures what is shown (full-res still for photos) straight to Photos, so it
// works even when Telegram hides its own save action for protected/ephemeral media.
#define kSaveInViewers @"saveInViewers"

#define FAKE_LOCATION_ENABLED_KEY @"ayTELEFakeLocation"
#define FAKE_LATITUDE_KEY @"ayTELESavedLatitude"
#define FAKE_LONGITUDE_KEY @"ayTELESavedLongitude"

#define FILE_PICKER_FIX_KEY @"ayTELEFixFilePicker"
#define FILE_PICKER_PATH @"ayTELEFileFixUsingSomeUglyHacks"

// Double-tap a message bubble to copy its text (opt-in; overrides Telegram's quick-react).
#define kDoubleTapCopy @"ayTELEDoubleTapCopy"

// Mic button above the chat text field: dictate with Apple speech recognition into the field.
#define kSpeechToText @"ayTELESpeechToText"
#define kSpeechLocale @"ayTELESpeechLocale"

// Arrow button above the chat text field: the next voice recording sends a picked file instead.
#define kVoiceFromFile @"ayTELEVoiceFromFile"
