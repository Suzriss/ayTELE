#import "ayTELEWelcome.h"

static NSString *const kAYWelcomeShownKey = @"aytele_welcome_shown";
static NSString *const kAYChannelURL = @"https://t.me/ayTweak";
static NSString *const kAYChannelDomain = @"ayTweak";

@implementation ayTELEWelcomeViewController

+ (void)presentIfNeededFrom:(UIViewController *)presenter {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kAYWelcomeShownKey] || !presenter) return;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    // Already showing, or another screen is mid-transition: try again on the next activation.
    if ([presenter isKindOfClass:self] || presenter.isBeingPresented || presenter.isBeingDismissed) return;
    ayTELEWelcomeViewController *welcome = [ayTELEWelcomeViewController new];
    welcome.modalPresentationStyle = UIModalPresentationOverFullScreen;
    welcome.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    // Block the interactive swipe-to-dismiss so the gate can only be passed via the button.
    welcome.modalInPresentation = YES;
    [presenter presentViewController:welcome animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.086 blue:0.129 alpha:1]; // 0E1621
    self.view.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;

    UIColor *accent = [UIColor colorWithRed:0.20 green:0.565 blue:0.925 alpha:1]; // 3390EC

    UIImageView *icon = [UIImageView new];
    icon.image = [UIImage systemImageNamed:@"paperplane.circle.fill"];
    icon.tintColor = accent;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.heightAnchor constraintEqualToConstant:96].active = YES;

    UILabel *title = [UILabel new];
    title.text = @"أدوات ay";
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;

    UILabel *body = [UILabel new];
    body.text = @"للاستمرار، انضمّ إلى قناة الأدوات على تيليجرام لتصلك التحديثات والإصدارات الجديدة أولاً بأول. اضغط الزر بالأسفل للانضمام.";
    body.font = [UIFont systemFontOfSize:17];
    body.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    body.textAlignment = NSTextAlignmentCenter;
    body.numberOfLines = 0;

    UIButton *join = [UIButton buttonWithType:UIButtonTypeSystem];
    [join setTitle:@"الانضمام إلى القناة" forState:UIControlStateNormal];
    join.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [join setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    join.backgroundColor = accent;
    join.layer.cornerRadius = 14;
    [join.heightAnchor constraintEqualToConstant:52].active = YES;
    [join addTarget:self action:@selector(joinTapped) forControlEvents:UIControlEventTouchUpInside];

    UILabel *handle = [UILabel new];
    handle.text = @"@ayTweak";
    handle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    handle.textColor = accent;
    handle.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, body, join, handle]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.alignment = UIStackViewAlignmentFill;
    [stack setCustomSpacing:26 afterView:body];
    [stack setCustomSpacing:10 afterView:join];
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28],
    ]];
}

- (void)markShown {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kAYWelcomeShownKey];
}

- (void)joinTapped {
    [self markShown];
    NSURL *app = [NSURL URLWithString:[NSString stringWithFormat:@"tg://resolve?domain=%@", kAYChannelDomain]];
    UIApplication *application = [UIApplication sharedApplication];
    [application openURL:app options:@{} completionHandler:^(BOOL success) {
        if (!success) [application openURL:[NSURL URLWithString:kAYChannelURL] options:@{} completionHandler:nil];
    }];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
