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

- (void)loadDefault {
	NSString *selectedLanguageCode = [[NSUserDefaults standardUserDefaults] stringForKey:@"ayTELELanguage"];

	if (!selectedLanguageCode) {
		selectedLanguageCode = @"en";
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
