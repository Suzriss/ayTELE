#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "Icons.h"
#import "Headers.h"

@interface AYNotesListViewController : UITableViewController
@end

@interface AYArchiveViewController : UITableViewController
@end

@interface AYVoiceConverter : NSObject
+ (void)convertURL:(NSURL *)url
        completion:(void (^)(NSData *oggOpusData, NSTimeInterval duration, NSData *waveform, NSError *error))completion;
@end

#ifndef AY_BUILD
#define AY_BUILD "dev"
#endif

#define TGLoc(key) [ayTELELocalization localizedStringForKey:(key)]

// Telegram-flavoured dark palette for the ayTELE settings UI.
static UIColor *ayColorHex(uint32_t rgb) {
	return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
	                       green:((rgb >> 8) & 0xFF) / 255.0
	                        blue:(rgb & 0xFF) / 255.0
	                       alpha:1.0];
}
#define AY_BG   ayColorHex(0x17212B)   // Telegram night background (blue-ish)
#define AY_CELL ayColorHex(0x0E1621)   // near-black cells
#define AY_BLUE ayColorHex(0x3390EC)   // Telegram accent blue

@interface ayTELE () <UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSString *cacheSize;
@end

@implementation ayTELE

- (void)viewDidLoad {
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    [self setupTableView];
    [self setupIconAsHeader];
    [self setupApplyButton];
    [self setupNavigationTitleWithIcon];

    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = AY_BG;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
    self.navigationController.navigationBar.standardAppearance = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.tintColor = AY_BLUE;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didChangeLanguage)
                                                 name:@"LanguageChangedNotification"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didChangeFakeLocation)
                                                 name:@"ayTELELocationChanged"
                                               object:nil];
}

- (void)didChangeLanguage {
    [self.tableView reloadData];
}

- (void)didChangeFakeLocation {
    NSIndexSet *section = [NSIndexSet indexSetWithIndex:4];
    [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = AY_BG;
    self.view.backgroundColor = AY_BG;

    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

// Plain "ayTELE" title, no ghost icon.
- (void)setupNavigationTitleWithIcon {
    self.title = @"ayTELE";
}

// Small clear spacer instead of the old ghost logo header.
- (void)setupIconAsHeader {
    UIView *spacer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.frame.size.width, 12)];
    spacer.backgroundColor = [UIColor clearColor];
    self.tableView.tableHeaderView = spacer;
}

- (void)setupApplyButton {
	UIButton *applyChangesButton = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImage *applyImage = [UIImage systemImageNamed:@"checkmark.square"];
	applyImage = [applyImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	applyChangesButton.tintColor = AY_BLUE;
	[applyChangesButton setImage:applyImage forState:UIControlStateNormal];
	[applyChangesButton addTarget:self action:@selector(applyChanges) forControlEvents:UIControlEventTouchUpInside];
	UIBarButtonItem *applyButtonItem = [[UIBarButtonItem alloc] initWithCustomView:applyChangesButton];
	self.navigationItem.rightBarButtonItems = @[applyButtonItem];
}

- (void)applyChanges {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGLoc(@"APPLY")
                                                                   message:TGLoc(@"APPLY_CHANGES")
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *okAction = [UIAlertAction actionWithTitle:TGLoc(@"OK")
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * _Nonnull action) {
		[[UIApplication sharedApplication] performSelector:@selector(suspend)];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			exit(0);
		});
	}];

    [alert addAction:okAction];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
    [alert addAction:cancelAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIColor *)dynamicColorBW {
    static dispatch_once_t token;
    static UIColor *cached;
    dispatch_once(&token, ^{
        cached = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
            if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor whiteColor];
            } else {
                return [UIColor blackColor];
            }
        }];
    });
    return cached;
}

# pragma mark - UITableViewDataSource

typedef NS_ENUM(NSInteger, TABLE_VIEW_SECTIONS) {
    GHOST_MODE = 0,
    READ_RECEIPT = 1,
    MISC = 2,
    FILE_FIXER = 3,
    FAKE_LOCATION = 4,
    CHAT_TWEAKS = 5,
    EXTRAS = 6,
    LANGUAGE = 7,
	CREDITS = 8,
};

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 9;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	switch (section) {
		case GHOST_MODE:
		   return 20;
		case READ_RECEIPT:
		   return 2;
		case MISC:
		   return 7;
		case FILE_FIXER:
		   return 2;
		case FAKE_LOCATION:
		   return 2;
		case CHAT_TWEAKS:
		   return 10;
		case EXTRAS:
		   return 1;
		case LANGUAGE:
		   return 1;
		case CREDITS:
		   return 3;
		default:
		   return 0;
	}
	return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {

	switch (section) {
		case GHOST_MODE:
		   return TGLoc(@"GHOST_MODE_SECTION_HEADER");
		case READ_RECEIPT:
		   return TGLoc(@"READ_RECEIPT_SECTION_HEADER");
		case MISC:
		   return TGLoc(@"MISC_SECTION_HEADER");
		case FILE_FIXER:
		   return TGLoc(@"FILE_FIXER_SECTION_HEADER");
		case FAKE_LOCATION:
		   return TGLoc(@"FAKE_LOCATION_SECTION_HEADER");
		case CHAT_TWEAKS:
		   return TGLoc(@"CHAT_SECTION_HEADER");
		case EXTRAS:
		   return TGLoc(@"EXTRAS_SECTION_HEADER");
		case LANGUAGE:
		   return TGLoc(@"LANGUAGE_SECTION_HEADER");
		case CREDITS:
		   return TGLoc(@"CREDITS_SECTION_HEADER");
		default:
		   return nil;
	}
	return nil;
}

// Build stamp, so a swapped dylib can be told apart from the old one at a glance.
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == CREDITS) return @"ayTELE · " AY_BUILD;
	return nil;
}

- (UITableViewCell *)switchCellFromTableView:(UITableView *)tableView {
	UITableViewCell *switchCell = [tableView dequeueReusableCellWithIdentifier:@"switchCell"];
	if (!switchCell) {
		switchCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"switchCell"];
	}

	return switchCell;
}

- (UITableViewCell *)normalCellFromTableView:(UITableView *)tableView {
	UITableViewCell *normalCell = [tableView dequeueReusableCellWithIdentifier:@"normalCell"];
	if (!normalCell) {
		normalCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"normalCell"];
	}

	return normalCell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell;

	if (indexPath.section == 0) { // GHOST MOODE
		cell = [self switchCellFromTableView:tableView];
		cell.imageView.image = nil;

		if (indexPath.row == 0) {
			cell.textLabel.text = TGLoc(@"DISABLE_ONLINE_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_ONLINE_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 1) {
			cell.textLabel.text = TGLoc(@"DISABLE_TYPING_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_TYPING_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 2) {
			cell.textLabel.text = TGLoc(@"DISABLE_RECORDING_VIDEO_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_RECORDING_VIDEO_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 3) {
			cell.textLabel.text = TGLoc(@"DISABLE_UPLOADING_VIDEO_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_UPLOADING_VIDEO_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 4) {
			cell.textLabel.text = TGLoc(@"DISABLE_VC_MESSAGE_RECORDING_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_VC_MESSAGE_RECORDING_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 5) {
			cell.textLabel.text = TGLoc(@"DISABLE_VC_MESSAGE_UPLOADING_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_VC_MESSAGE_UPLOADING_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 6) {
			cell.textLabel.text = TGLoc(@"DISABLE_UPLOADING_PHOTO_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_UPLOADING_PHOTO_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 7) {
			cell.textLabel.text = TGLoc(@"DISABLE_UPLOADING_FILE_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_UPLOADING_FILE_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 8) {
			cell.textLabel.text = TGLoc(@"DISABLE_CHOOSING_LOCATION_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_CHOOSING_LOCATION_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 9) {
			cell.textLabel.text = TGLoc(@"DISABLE_CHOOSING_CONTACT_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_CHOOSING_CONTACT_SUBTITLE");
		}
		else if (indexPath.row == 10) {
			cell.textLabel.text = TGLoc(@"DISABLE_PLAYING_GAME_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_PLAYING_GAME_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 11) {
			cell.textLabel.text = TGLoc(@"DISABLE_RECORDING_ROUND_VIDEO_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_RECORDING_ROUND_VIDEO_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 12) {
			cell.textLabel.text = TGLoc(@"DISABLE_UPLOADING_ROUND_VIDEO_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_UPLOADING_ROUND_VIDEO_STATUS_TITLE");
		}
		else if (indexPath.row == 13) {
			cell.textLabel.text = TGLoc(@"DISABLE_SPEAKING_IN_GROUP_CALL_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_SPEAKING_IN_GROUP_CALL_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 14) {
			cell.textLabel.text = TGLoc(@"DISABLE_CHOOSING_STICKER_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_CHOOSING_STICKER_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 15) {
			cell.textLabel.text = TGLoc(@"DISABLE_EMOJI_INTERACTION_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_EMOJI_INTERACTION_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 16) {
			cell.textLabel.text = TGLoc(@"DISABLE_EMOJI_ACKNOWLEDGEMENT_STATUS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_EMOJI_ACKNOWLEDGEMENT_STATUS_SUBTITLE");
		}
		else if (indexPath.row == 17) {
			cell.textLabel.text = TGLoc(@"DISABLE_CONTENT_READ_RECEIPT_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_CONTENT_READ_RECEIPT_SUBTITLE");
		}
		else if (indexPath.row == 18) {
			cell.textLabel.text = TGLoc(@"KEEP_VIEW_ONCE_MEDIA_TITLE");
			cell.detailTextLabel.text = TGLoc(@"KEEP_VIEW_ONCE_MEDIA_SUBTITLE");
		}
		else if (indexPath.row == 19) {
			cell.textLabel.text = TGLoc(@"SAVE_IN_VIEWERS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"SAVE_IN_VIEWERS_SUBTITLE");
		}

		UISwitch *toggle = (UISwitch *)cell.accessoryView;
		if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) {
			toggle = [[UISwitch alloc] init];
		}

		NSString *switchKey = [self switchKeyForIndexPath:indexPath];
		toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
		[toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
		toggle.tag = 1000 + (indexPath.section *1000) + indexPath.row;
		cell.accessoryView = toggle;

		cell.textLabel.numberOfLines = 0;
		cell.detailTextLabel.numberOfLines = 0;
		return cell;

	}
	else if (indexPath.section == 1) { // Read Receipts
		cell = [self switchCellFromTableView:tableView];
		cell.imageView.image = nil;

		if (indexPath.row == 0) {
			cell.textLabel.text = TGLoc(@"DISABLE_MESSAGE_READ_RECEIPT_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_MESSAGE_READ_RECEIPT_SUBTITLE");
		}
		else if (indexPath.row == 1) {
			cell.textLabel.text = TGLoc(@"DISABLE_STORY_READ_RECEIPT_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_STORY_READ_RECEIPT_SUBTITLE");
		}

		UISwitch *toggle = (UISwitch *)cell.accessoryView;
		if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) {
			toggle = [[UISwitch alloc] init];
		}

		NSString *switchKey = [self switchKeyForIndexPath:indexPath];
		toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
		[toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
		toggle.tag = 1000 + (indexPath.section *1000) + indexPath.row;
		cell.accessoryView = toggle;

		cell.textLabel.numberOfLines = 0;
		cell.detailTextLabel.numberOfLines = 0;
		return cell;
	}
	else if (indexPath.section == 2 && indexPath.row == 4) { // MISC: open private notes list
		cell = [self normalCellFromTableView:tableView];
		cell.textLabel.text = TGLoc(@"NOTES_SETTINGS_TITLE");
		cell.detailTextLabel.text = TGLoc(@"NOTES_SETTINGS_SUBTITLE");
		cell.imageView.image = [UIImage systemImageNamed:@"note.text"];
		cell.imageView.tintColor = [UIColor systemYellowColor];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		cell.textLabel.numberOfLines = 0;
		cell.detailTextLabel.numberOfLines = 0;
		return cell;
	}
	else if (indexPath.section == 2 && indexPath.row == 5) { // MISC: browse deleted / edited
		cell = [self normalCellFromTableView:tableView];
		cell.textLabel.text = TGLoc(@"ARCHIVE_SETTINGS_TITLE");
		cell.detailTextLabel.text = TGLoc(@"ARCHIVE_SETTINGS_SUBTITLE");
		cell.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
		cell.imageView.tintColor = [self dynamicColorBW];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		cell.textLabel.numberOfLines = 0;
		cell.detailTextLabel.numberOfLines = 0;
		return cell;
	}
	else if (indexPath.section == 2 && indexPath.row == 6) { // MISC: convert audio -> voice note
		cell = [self normalCellFromTableView:tableView];
		cell.textLabel.text = TGLoc(@"VOICE_CONVERT_TITLE");
		cell.detailTextLabel.text = TGLoc(@"VOICE_CONVERT_SUBTITLE");
		cell.imageView.image = [UIImage systemImageNamed:@"waveform"];
		cell.imageView.tintColor = [self dynamicColorBW];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		cell.textLabel.numberOfLines = 0;
		cell.detailTextLabel.numberOfLines = 0;
		return cell;
	}
	else if (indexPath.section == 2) { // MISC
		cell = [self switchCellFromTableView:tableView];
		cell.imageView.image = nil;

		if (indexPath.row == 0) {
			cell.textLabel.text = TGLoc(@"DISABLE_ALL_ADS_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DISABLE_ALL_ADS_SUBTITLE");
		}
		else if (indexPath.row == 1) {
			cell.textLabel.text = TGLoc(@"ENABLE_SAVING_PROTECTED_CONTENT_TITLE");
			cell.detailTextLabel.text = TGLoc(@"ENABLE_SAVING_PROTECTED_CONTENT_SUBTITLE");
		}
		else if (indexPath.row == 2) {
			cell.textLabel.text = TGLoc(@"KEEP_DELETED_MESSAGES_TITLE");
			cell.detailTextLabel.text = TGLoc(@"KEEP_DELETED_MESSAGES_SUBTITLE");
		}
		else if (indexPath.row == 3) {
			cell.textLabel.text = TGLoc(@"KEEP_EDIT_HISTORY_TITLE");
			cell.detailTextLabel.text = TGLoc(@"KEEP_EDIT_HISTORY_SUBTITLE");
		}

		UISwitch *toggle = (UISwitch *)cell.accessoryView;
		if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) {
			toggle = [[UISwitch alloc] init];
		}

		NSString *switchKey = [self switchKeyForIndexPath:indexPath];
		toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
		[toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
		toggle.tag = 1000 + (indexPath.section *1000) + indexPath.row;
		cell.accessoryView = toggle;

		cell.textLabel.numberOfLines = 0;
		cell.detailTextLabel.numberOfLines = 0;
		return cell;

	}
	if (indexPath.section == 3) { // File Picker Fix
		if (indexPath.row ==0) { //Enable File Picker Fix
			cell = [self switchCellFromTableView:tableView];

			cell.imageView.image = [UIImage systemImageNamed:@"folder.fill.badge.gear"];
			cell.imageView.tintColor = [self dynamicColorBW];
			cell.textLabel.text = TGLoc(@"FIX_FILE_PICKER_TITLE");
			cell.detailTextLabel.text = TGLoc(@"FIX_FILE_PICKER_SUBTITLE");

			UISwitch *toggle = (UISwitch *)cell.accessoryView;
			if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) {
				toggle = [[UISwitch alloc] init];
			}

			NSString *switchKey = [self switchKeyForIndexPath:indexPath];
			toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
			[toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
			toggle.tag = 1000 + (indexPath.section *1000) + indexPath.row;
			cell.accessoryView = toggle;

			cell.textLabel.numberOfLines = 0;
			cell.detailTextLabel.numberOfLines = 0;
			return cell;
		}

		if (indexPath.row == 1) {
			cell = [self normalCellFromTableView:tableView];
			cell.imageView.image = nil;

		    cell.textLabel.text = TGLoc(@"CLEAR_FILE_PICKER_CACHE_TITLE");
		    cell.detailTextLabel.text = TGLoc(@"CLEAR_FILE_PICKER_CACHE_SUBTITLE");
		    cell.imageView.image = [UIImage systemImageNamed:@"trash"];
		    cell.imageView.tintColor = [UIColor redColor];

		    // Initially show a UIActivityIndicator
		    UIActivityIndicatorView *loadingIcon = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
		    [loadingIcon startAnimating];
		    cell.accessoryView = loadingIcon;

		    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
				if (!self.cacheSize) {
					self.cacheSize = [self sizeOfUglyFileFixDirectory];
				}

		        dispatch_async(dispatch_get_main_queue(), ^{
					UITableViewCell *currentCell = [tableView cellForRowAtIndexPath:indexPath];
					if (currentCell == cell) {
						UILabel *sizeLabel = [[UILabel alloc] init];
						sizeLabel.text = self.cacheSize;
						cell.accessoryView = sizeLabel;

						[sizeLabel sizeToFit];
					}
		        });
		    });

			cell.textLabel.numberOfLines = 0;
			cell.detailTextLabel.numberOfLines = 0;
			return cell;
		}
	}

	if (indexPath.section == 4) { // Fake Location
		if (indexPath.row ==0) {
			cell = [self switchCellFromTableView:tableView];

			cell.imageView.image = [UIImage systemImageNamed:@"location.fill"];
			cell.imageView.tintColor = [self dynamicColorBW];
			cell.textLabel.text = TGLoc(@"ENABLE_FAKE_LOCATION_TITLE");
			cell.detailTextLabel.text = TGLoc(@"ENABLE_FAKE_LOCATION_SUBTITLE");

			UISwitch *toggle = (UISwitch *)cell.accessoryView;
			if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) {
				toggle = [[UISwitch alloc] init];
			}

			NSString *switchKey = [self switchKeyForIndexPath:indexPath];
			toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
			[toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
			toggle.tag = 1000 + (indexPath.section *1000) + indexPath.row;
			cell.accessoryView = toggle;
		}

		if (indexPath.row == 1) {
			cell = [self normalCellFromTableView:tableView];

			cell.imageView.image = [UIImage systemImageNamed:@"location.fill"];
			cell.imageView.tintColor = [self dynamicColorBW];
			cell.textLabel.text = TGLoc(@"SELECT_FAKE_LOCATION_TITLE");

			NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
			CGFloat savedLongitude = [defaults floatForKey:FAKE_LONGITUDE_KEY];
			CGFloat savedLatitude = [defaults floatForKey:FAKE_LATITUDE_KEY];

			NSString *savedCord = savedCord = [NSString stringWithFormat:@"lon :%f\nlat :%f", savedLongitude ? : 0, savedLatitude ? : 0];

			cell.textLabel.numberOfLines = 0;
			cell.detailTextLabel.text = savedCord;
		}
		cell.detailTextLabel.numberOfLines = 0;
		return cell;
	}

	if (indexPath.section == CHAT_TWEAKS && indexPath.row == 9) { // Edit keyword list
		cell = [self normalCellFromTableView:tableView];
		cell.textLabel.text = TGLoc(@"KEYWORD_ALERT_EDIT_TITLE");
		cell.detailTextLabel.text = TGLoc(@"KEYWORD_ALERT_EDIT_SUBTITLE");
		cell.imageView.image = [UIImage systemImageNamed:@"bell.badge"];
		cell.imageView.tintColor = [UIColor systemYellowColor];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		cell.textLabel.numberOfLines = 0;
		cell.detailTextLabel.numberOfLines = 0;
		return cell;
	}

	if (indexPath.section == CHAT_TWEAKS) { // Chat tweaks
		cell = [self switchCellFromTableView:tableView];
		cell.imageView.image = nil;

		if (indexPath.row == 0) {
			cell.textLabel.text = TGLoc(@"DOUBLE_TAP_COPY_TITLE");
			cell.detailTextLabel.text = TGLoc(@"DOUBLE_TAP_COPY_SUBTITLE");
		}
		else if (indexPath.row == 1) {
			cell.textLabel.text = TGLoc(@"SPEECH_TO_TEXT_TITLE");
			cell.detailTextLabel.text = TGLoc(@"SPEECH_TO_TEXT_SUBTITLE");
		}
		else if (indexPath.row == 2) {
			cell.textLabel.text = TGLoc(@"VOICE_FILE_TITLE");
			cell.detailTextLabel.text = TGLoc(@"VOICE_FILE_SUBTITLE");
		}
		else if (indexPath.row == 3) {
			cell.textLabel.text = TGLoc(@"CHAR_COUNTER_TITLE");
			cell.detailTextLabel.text = TGLoc(@"CHAR_COUNTER_SUBTITLE");
		}
		else if (indexPath.row == 4) {
			cell.textLabel.text = TGLoc(@"FORMAT_BAR_TITLE");
			cell.detailTextLabel.text = TGLoc(@"FORMAT_BAR_SUBTITLE");
		}
		else if (indexPath.row == 5) {
			cell.textLabel.text = TGLoc(@"READ_ALOUD_TITLE");
			cell.detailTextLabel.text = TGLoc(@"READ_ALOUD_SUBTITLE");
		}
		else if (indexPath.row == 6) {
			cell.textLabel.text = TGLoc(@"KEYWORD_ALERT_TITLE");
			cell.detailTextLabel.text = TGLoc(@"KEYWORD_ALERT_SUBTITLE");
		}
		else if (indexPath.row == 7) {
			cell.textLabel.text = TGLoc(@"TRANSLATE_TITLE");
			cell.detailTextLabel.text = TGLoc(@"TRANSLATE_SUBTITLE");
		}
		else if (indexPath.row == 8) {
			cell.textLabel.text = TGLoc(@"STICKER_TITLE");
			cell.detailTextLabel.text = TGLoc(@"STICKER_SUBTITLE");
		}

		UISwitch *toggle = (UISwitch *)cell.accessoryView;
		if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) {
			toggle = [[UISwitch alloc] init];
		}

		NSString *switchKey = [self switchKeyForIndexPath:indexPath];
		toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
		[toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
		toggle.tag = 1000 + (indexPath.section * 1000) + indexPath.row;
		cell.accessoryView = toggle;

		cell.textLabel.numberOfLines = 0;
		cell.detailTextLabel.numberOfLines = 0;
		return cell;
	}

	if (indexPath.section == EXTRAS) { // Power features
		cell = [self switchCellFromTableView:tableView];
		cell.imageView.image = nil;

		if (indexPath.row == 0) {
			cell.textLabel.text = TGLoc(@"SCREEN_BLUR_TITLE");
			cell.detailTextLabel.text = TGLoc(@"SCREEN_BLUR_SUBTITLE");
		}

		UISwitch *toggle = (UISwitch *)cell.accessoryView;
		if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) {
			toggle = [[UISwitch alloc] init];
		}
		NSString *switchKey = [self switchKeyForIndexPath:indexPath];
		toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
		[toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
		toggle.tag = 1000 + (indexPath.section * 1000) + indexPath.row;
		cell.accessoryView = toggle;

		cell.textLabel.numberOfLines = 0;
		cell.detailTextLabel.numberOfLines = 0;
		return cell;
	}

	if (indexPath.section == LANGUAGE) { // Language
		cell = [self normalCellFromTableView:tableView];
		if (indexPath.row == 0) {
			cell.textLabel.text = @"Change Language";
			cell.detailTextLabel.text = @"";
			cell.imageView.image = [UIImage systemImageNamed:@"globe"];
			cell.imageView.tintColor = [self dynamicColorBW];
			cell.imageView.layer.cornerRadius = 40/8;
			cell.imageView.layer.masksToBounds = YES;
			cell.accessoryView = nil;

			cell.textLabel.numberOfLines = 0;
			cell.detailTextLabel.numberOfLines = 0;
			return cell;
		}
	}

	if (indexPath.section == CREDITS) { // Credits
		cell = [self normalCellFromTableView:tableView];

		if (indexPath.row == 0) {
			cell.textLabel.text = @"Ceresify";
			cell.detailTextLabel.text = @"dev.ceresify.com";
			cell.detailTextLabel.textColor = [UIColor lightGrayColor];
			cell.imageView.image = [UIImage systemImageNamed:@"globe"];
			cell.imageView.tintColor = [self dynamicColorBW];
			cell.imageView.layer.cornerRadius = 40/8;
			cell.imageView.layer.masksToBounds = YES;
			cell.accessoryView = nil;

		}
		if (indexPath.row == 1) {
			cell.textLabel.text = @"uussuu";
			cell.detailTextLabel.text = @"t.me/uussuu";
			cell.detailTextLabel.textColor = [UIColor lightGrayColor];
			cell.imageView.image = [UIImage systemImageNamed:@"paperplane.fill"];
			cell.imageView.tintColor = [self dynamicColorBW];
			cell.imageView.layer.cornerRadius = 40/8;
			cell.imageView.layer.masksToBounds = YES;
			cell.accessoryView = nil;

		}
		else if (indexPath.row == 2) {
			cell.textLabel.text = TGLoc(@"DISCLAIMER");
			cell.detailTextLabel.text = @"ayTELE v1";
			cell.imageView.image = [UIImage systemImageNamed:@"note.text"];
			cell.imageView.tintColor = [self dynamicColorBW];
			cell.accessoryView = nil;
			cell.detailTextLabel.textColor = [UIColor lightGrayColor];
		}
		cell.textLabel.numberOfLines = 0;
		cell.detailTextLabel.numberOfLines = 0;
		return cell;
	}

    return cell;
}

# pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    cell.backgroundColor = AY_CELL;
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];

    UIView *selected = [[UIView alloc] init];
    selected.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    cell.selectedBackgroundView = selected;

    if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
        ((UISwitch *)cell.accessoryView).onTintColor = AY_BLUE;

        // Give the icon-less toggle rows a tasteful blue SF Symbol.
        if (cell.imageView.image == nil) {
            NSString *symbol = nil;
            switch (indexPath.section) {
                case GHOST_MODE:   symbol = @"eye.slash.fill"; break;
                case READ_RECEIPT: symbol = @"checkmark.seal.fill"; break;
                case MISC:         symbol = @"wand.and.stars"; break;
                case CHAT_TWEAKS:  symbol = @"hand.tap.fill"; break;
                case EXTRAS:       symbol = @"sparkles"; break;
                default: break;
            }
            if (symbol) {
                cell.imageView.image = [UIImage systemImageNamed:symbol];
                cell.imageView.tintColor = AY_BLUE;
            }
        }
    }
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.textColor = AY_BLUE;
        header.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

	if (indexPath.section == MISC) { // Private notes list / archive browser
		if (indexPath.row == 4) {
			[self showNotesList];
		}
		else if (indexPath.row == 5) {
			[self showArchive];
		}
		else if (indexPath.row == 6) {
			[self startVoiceConversion];
		}
	}

	if (indexPath.section == FILE_FIXER) { // File Picker Fix
		if (indexPath.row == 1) {
			[self clearFilePickerFixCache];
		}
	}

	if (indexPath.section == FAKE_LOCATION) { // Fake Location
		if (indexPath.row == 1) {
			[self showLocationSelector];
		}
	}

	if (indexPath.section == CHAT_TWEAKS) { // Chat tweaks
		if (indexPath.row == 9) {
			[self showKeywordEditor];
		}
	}

	if (indexPath.section == LANGUAGE) { // Language
		if (indexPath.row == 0) {
			[self showLanguageSelector];
		}
	}

    if (indexPath.section == CREDITS) {
		if (indexPath.row == 0) {
			NSString *base64String = @"aHR0cHM6Ly9kZXYuY2VyZXNpZnkuY29t";
	        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:base64String options:0];
	        NSString *decodedURL = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];

	        NSURL *url = [NSURL URLWithString:decodedURL];
	        if ([[UIApplication sharedApplication] canOpenURL:url]) {
	            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
	        }
		}
		else if (indexPath.row == 1) {
			NSString *base64String = @"aHR0cHM6Ly90Lm1lL3V1c3N1dQ==";
	        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:base64String options:0];
	        NSString *decodedURL = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];

	        NSURL *url = [NSURL URLWithString:decodedURL];
	        if ([[UIApplication sharedApplication] canOpenURL:url]) {
	            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
	        }
		}
		else if (indexPath.row == 2) {
		    [self showDisclaimer];
		}
    }
}

- (void)switchChanged:(UISwitch *)sender {
    NSInteger adjustedTag = sender.tag - 1000;
    NSInteger section = adjustedTag / 1000;
    NSInteger row = adjustedTag % 1000;

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
    NSString *switchKey = [self switchKeyForIndexPath:indexPath];

    if (switchKey) {
        [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:switchKey];
    }
}

- (NSString *)switchKeyForIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            switch (indexPath.row) {
                case 0: return kDisableOnlineStatus;
                case 1: return kDisableTypingStatus;
                case 2: return kDisableRecordingVideoStatus;
                case 3: return kDisableUploadingVideoStatus;
                case 4: return kDisableRecordingVoiceStatus;
                case 5: return kDisableUploadingVoiceStatus;
                case 6: return kDisableUploadingPhotoStatus;
                case 7: return kDisableUploadingFileStatus;
                case 8: return kDisableChoosingLocationStatus;
                case 9: return kDisableChoosingContactStatus;
                case 10: return kDisablePlayingGameStatus;
                case 11: return kDisableRecordingRoundVideoStatus;
                case 12: return kDisableUploadingRoundVideoStatus;
                case 13: return kDisableSpeakingInGroupCallStatus;
                case 14: return kDisableChoosingStickerStatus;
                case 15: return kDisableEmojiInteractionStatus;
                case 16: return kDisableEmojiAcknowledgementStatus;
                case 17: return kDisableReadMessageContents;
                case 18: return kKeepViewOnceMedia;
                case 19: return kSaveInViewers;
                default: return nil;
            }
        case 1:
            switch (indexPath.row) {
                case 0: return kDisableMessageReadReceipt;
                case 1: return kDisableStoriesReadReceipt;
                default: return nil;
            }
        case 2:
            switch (indexPath.row) {
                case 0: return kDisableAllAds;
                case 1: return kDisableForwardRestriction;
                case 2: return kKeepDeletedMessages;
                case 3: return kKeepEditHistory;
                default: return nil;
            }
        case 3:
            switch (indexPath.row) {
                case 0: return FILE_PICKER_FIX_KEY;
                default: return nil;
            }
        case 4:
            switch (indexPath.row) {
                case 0: return FAKE_LOCATION_ENABLED_KEY;
                default: return nil;
            }
        case CHAT_TWEAKS:
            switch (indexPath.row) {
                case 0: return kDoubleTapCopy;
                case 1: return kSpeechToText;
                case 2: return kVoiceFromFile;
                case 3: return kCharCounter;
                case 4: return kFormatBar;
                case 5: return kReadAloud;
                case 6: return kKeywordAlert;
                case 7: return kTranslateOutgoing;
                case 8: return kStickerFromImage;
                default: return nil;
            }
        case EXTRAS:
            switch (indexPath.row) {
                case 0: return kScreenBlur;
                default: return nil;
            }
        default:
            return nil;
    }
}

- (NSString *)sizeOfUglyFileFixDirectory {
	NSString *uglyFixDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:FILE_PICKER_PATH];

    // Calculate size of it recursively
    unsigned long long totalSize = 0;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *contents = [fileManager subpathsAtPath:uglyFixDirectory];

    for (NSString *path in contents) {
        NSString *fullPath = [uglyFixDirectory stringByAppendingPathComponent:path];
        BOOL isDirectory;
        if ([fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory]) {
            if (!isDirectory) {
                NSDictionary *attributes = [fileManager attributesOfItemAtPath:fullPath error:nil];
                totalSize += [attributes fileSize];
            }
        }
    }

    // Format the size into MB or GB
    NSString *formattedSize;
    if (totalSize >= 1024 * 1024 * 1024) { // if the size is >= 1GB
        formattedSize = [NSString stringWithFormat:@"%.2f GB", totalSize / (1024.0 * 1024.0 * 1024.0)];
    } else {
        formattedSize = [NSString stringWithFormat:@"%.2f MB", totalSize / (1024.0 * 1024.0)];
    }
	return formattedSize;
}

- (void)showDisclaimer {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGLoc(@"DISCLAIMER")
		              message:TGLoc(@"AUTHOR_MESSAGE")
		       preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *okAction = [UIAlertAction actionWithTitle:TGLoc(@"OK")
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil];

    [alert addAction:okAction];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showNotesList {
	AYNotesListViewController *ui = [[AYNotesListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
	[self.navigationController pushViewController:ui animated:YES];
}

- (void)showArchive {
	AYArchiveViewController *ui = [[AYArchiveViewController alloc] initWithStyle:UITableViewStylePlain];
	[self.navigationController pushViewController:ui animated:YES];
}

#pragma mark - Voice note conversion (#2)

- (void)startVoiceConversion {
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
		initWithDocumentTypes:@[@"public.audio", @"public.movie"] inMode:UIDocumentPickerModeOpen];
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSURL *url = urls.firstObject;
	if (!url) return;

	UIAlertController *progress = [UIAlertController alertControllerWithTitle:TGLoc(@"VOICE_CONVERTING") message:nil preferredStyle:UIAlertControllerStyleAlert];
	[self presentViewController:progress animated:YES completion:nil];

	BOOL scoped = [url startAccessingSecurityScopedResource];
	[AYVoiceConverter convertURL:url completion:^(NSData *oggOpusData, NSTimeInterval duration, NSData *waveform, NSError *error) {
		if (scoped) [url stopAccessingSecurityScopedResource];
		[progress dismissViewControllerAnimated:YES completion:^{
			if (error || oggOpusData.length == 0) {
				[self showConversionError:error];
				return;
			}
			[self exportConvertedVoice:oggOpusData sourceName:url.lastPathComponent];
		}];
	}];
}

- (void)exportConvertedVoice:(NSData *)oggData sourceName:(NSString *)sourceName {
	NSString *base = sourceName.stringByDeletingPathExtension.length ? sourceName.stringByDeletingPathExtension : @"voice";
	NSString *outName = [base stringByAppendingString:@".ogg"];
	NSURL *outURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:outName];
	NSError *writeError = nil;
	if (![oggData writeToURL:outURL options:NSDataWritingAtomic error:&writeError]) {
		[self showConversionError:writeError];
		return;
	}
	UIDocumentPickerViewController *exporter = [[UIDocumentPickerViewController alloc]
		initWithURL:outURL inMode:UIDocumentPickerModeExportToService];
	exporter.delegate = self;
	[self presentViewController:exporter animated:YES completion:nil];
}

- (void)showConversionError:(NSError *)error {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGLoc(@"VOICE_CONVERT_FAILED")
		message:error.localizedDescription
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"OK") style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

// Keyword editor (#22): one text field holding the watched words, separated by commas or new lines.
- (void)showKeywordEditor {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGLoc(@"KEYWORD_ALERT_PROMPT")
		message:TGLoc(@"KEYWORD_ALERT_EDIT_SUBTITLE")
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
		field.placeholder = TGLoc(@"KEYWORD_ALERT_PLACEHOLDER");
		field.text = [[NSUserDefaults standardUserDefaults] stringForKey:kKeywordList];
		field.autocapitalizationType = UITextAutocapitalizationTypeNone;
		field.clearButtonMode = UITextFieldViewModeWhileEditing;
	}];
	[alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"OK") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		NSString *text = alert.textFields.firstObject.text ?: @"";
		[[NSUserDefaults standardUserDefaults] setObject:text forKey:kKeywordList];
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)showLanguageSelector {
	LanguageSelector *ui = [LanguageSelector new];
	UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:ui];
	[self presentViewController:navVC animated:YES completion:nil];
}

- (void)showLocationSelector {
	LocationSelector *ui = [LocationSelector new];
	UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:ui];
	[self presentViewController:navVC animated:YES completion:nil];
}

- (void)clearFilePickerFixCache {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGLoc(@"CACHE_CLEAR_WARNING_TITLE")
                                                                   message:TGLoc(@"CACHE_CLEAR_WARNING_MESSAGE")
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *okAction = [UIAlertAction actionWithTitle:TGLoc(@"OK")
                                                       style:UIAlertActionStyleDestructive
                                                     handler:^(UIAlertAction *action) {
        NSString *uglyFixDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ayTELEFileFixUsingSomeUglyHacks"];

        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:uglyFixDirectory error:&error];

        if (error) {
            NSLog(@"Failed to remove cache directory: %@", error.localizedDescription);
        } else {
            NSLog(@"Successfully cleared cache: %@", uglyFixDirectory);
        }

		self.cacheSize = @"Cleared";

        // Reload section or row as needed
        dispatch_async(dispatch_get_main_queue(), ^{
            NSIndexSet *section = [NSIndexSet indexSetWithIndex:FILE_FIXER];
            [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationAutomatic];
        });
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];

    [alert addAction:cancelAction];
    [alert addAction:okAction];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"LanguageChangedNotification" object:nil];

	[[NSNotificationCenter defaultCenter] removeObserver:self name:@"ayTELELocationChanged" object:nil];

}

@end
