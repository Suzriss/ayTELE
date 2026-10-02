#import <UIKit/UIKit.h>

// Mandatory first-launch gate: the user must tap "join" (which opens the
// ayTweak Telegram channel) before they can get to the app. Modelled on
// ayPINT's welcome screen, but with no "later" escape so it acts as a gate.
@interface ayTELEWelcomeViewController : UIViewController
+ (void)presentIfNeededFrom:(UIViewController *)presenter;
@end
