#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <roothide.h>
#import "../Constants.h"

@interface ayTELE : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@interface TGLocalization : NSObject
- (NSString *)get:(NSString *)queryString;
- (id)initWithVersion:(int)a code:(id)b dict:(id)c isActive:(BOOL)d;
@end

@interface ayTELELocalization  : NSObject
@property (nonatomic, strong ) TGLocalization *localization;
+ (instancetype)shared;
+ (NSString *)localizedStringForKey:(NSString *)key;
+ (NSDictionary *)stringsForCode:(NSString *)code;
@end

// Generated from ayTELE.bundle by ci/gen_strings.py (EmbeddedStrings.m).
NSArray<NSDictionary *> *AYEmbeddedLanguages(void);
NSDictionary<NSString *, NSString *> *AYEmbeddedStrings(NSString *code);


@interface LanguageSelector : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@interface LocationSelector : UIViewController <MKMapViewDelegate>
@end

@interface ThreeFingerGestureHandler : NSObject
- (void)handleThreeFingerLongPress:(UILongPressGestureRecognizer *)gesture;
@end
