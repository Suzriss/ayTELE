#import "Headers.h"

@implementation ayTELELocalization

+ (instancetype)shared {
	static ayTELELocalization *instance;
	static dispatch_once_t token;
	dispatch_once(&token, ^{
		instance = [ayTELELocalization new];
		[instance loadDefault];
	});
	return instance;
}

// Maps the device's preferred language to one of ayTELE's bundled codes, or nil if none match.
- (NSString *)deviceLanguageCode {
	NSDictionary<NSString *, NSString *> *map = @{
		@"ar": @"ar", @"en": @"en", @"fr": @"fr", @"it": @"it",
		@"ja": @"ja", @"ru": @"ru", @"es": @"es", @"vi": @"vn"
	};
	for (NSString *lang in [NSLocale preferredLanguages]) {
		NSString *lower = [lang lowercaseString];
		// Chinese needs script-aware mapping (traditional -> tw, simplified -> cn).
		if ([lower hasPrefix:@"zh-hant"] || [lower hasPrefix:@"zh-tw"] ||
		    [lower hasPrefix:@"zh-hk"] || [lower hasPrefix:@"zh-mo"]) {
			return @"tw";
		}
		if ([lower hasPrefix:@"zh"]) {
			return @"cn";
		}
		NSString *base = [[lower componentsSeparatedByString:@"-"] firstObject];
		NSString *code = map[base];
		if (code) return code;
	}
	return nil;
}

- (void)loadDefault {
	// Respect an explicit choice from the language selector; otherwise follow the device
	// language when we bundle it, and fall back to Arabic for everything else.
	NSString *selectedLanguageCode = [[NSUserDefaults standardUserDefaults] stringForKey:@"ayTELELanguage"];

	if (!selectedLanguageCode) {
		selectedLanguageCode = [self deviceLanguageCode] ?: @"ar";
	}

	NSString *localizationFilePath = [NSString stringWithFormat:@"%@/ayTELE.bundle/%@.lproj/Localizable.strings", jbroot(@"/Library/Application Support/ayTELE"), selectedLanguageCode];
	if (![[NSFileManager defaultManager] fileExistsAtPath:localizationFilePath]) {
		localizationFilePath = [NSString stringWithFormat:@"%@/ayTELE.bundle/%@.lproj/Localizable.strings", [[NSBundle mainBundle] resourcePath], selectedLanguageCode];
	}

	NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:localizationFilePath];

	self.localization = [[objc_getClass("TGLocalization") alloc] initWithVersion:96929692
                                                                   code:selectedLanguageCode
                                                                   dict:dict
                                                              isActive:YES];

}

+ (NSString *)localizedStringForKey:(NSString *)key {
	if (!key) return nil;

	NSString *localizedString = [[ayTELELocalization shared].localization get:key];

	if (!localizedString) return key;

	return localizedString;
}
@end
