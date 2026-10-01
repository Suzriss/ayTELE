#import "Headers.h"
#import <AVFoundation/AVFoundation.h>

// Read aloud (#29): speaks a message's text with AVSpeechSynthesizer, on the device, no network.
// Offered in the two-finger message menu (DeletedBadge.xm) when kReadAloud is on. The synthesizer
// is kept alive on a singleton — a local AVSpeechSynthesizer stops as soon as it is released.

@implementation AYReadAloud

+ (AVSpeechSynthesizer *)synth {
	static AVSpeechSynthesizer *synth;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ synth = [AVSpeechSynthesizer new]; });
	return synth;
}

// Arabic when the text has Arabic letters, otherwise the device language, else English.
+ (NSString *)languageForText:(NSString *)text {
	for (NSUInteger i = 0; i < text.length; i++) {
		unichar c = [text characterAtIndex:i];
		if (c >= 0x0600 && c <= 0x06FF) return @"ar-SA";
	}
	NSString *preferred = NSLocale.preferredLanguages.firstObject;
	return preferred.length ? preferred : @"en-US";
}

+ (void)speak:(NSString *)text {
	NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (trimmed.length == 0) return;

	AVSpeechSynthesizer *synth = [self synth];
	if (synth.isSpeaking) {
		[synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
		return; // tapping again stops it
	}

	// Play over the current audio session without permanently ducking everything.
	AVAudioSession *session = [AVAudioSession sharedInstance];
	[session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeSpokenAudio options:AVAudioSessionCategoryOptionDuckOthers error:nil];
	[session setActive:YES withOptions:0 error:nil];

	AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:trimmed];
	utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:[self languageForText:trimmed]];
	utterance.rate = AVSpeechUtteranceDefaultSpeechRate;
	[synth speakUtterance:utterance];
}

@end
