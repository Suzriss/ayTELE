#import "Headers.h"
#import <objc/runtime.h>

// Badges drawn on chat message nodes:
//  - a red trash badge for messages deleted remotely (see AYDeletedMarks), non-interactive.
//  - an orange pencil badge for messages edited while we watched (see AYEditHistory), tappable to
//    show every stored version.

@interface ayTELELocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

@interface ASDisplayNode : NSObject
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly, getter=isNodeLoaded) BOOL nodeLoaded;
@property (nonatomic) CGRect bounds;
- (CGRect)convertRect:(CGRect)rect toNode:(ASDisplayNode *)node;
@end

static Class chatMessageItemViewClass;
static NSHashTable<ASDisplayNode *> *trackedNodes;
static const void *kBadgeKey = &kBadgeKey;
static const void *kEditBadgeKey = &kEditBadgeKey;

// The node that draws the message itself, per ChatMessageItemView subclass.
static ASDisplayNode *contentNodeOf(ASDisplayNode *node) {
	for (NSString *name in @[@"backgroundNode", @"imageNode", @"interactiveVideoNode", @"containerNode"]) {
		Ivar ivar = class_getInstanceVariable(object_getClass(node), name.UTF8String);
		if (!ivar) continue;
		id value = object_getIvar(node, ivar);
		if ([value isKindOfClass:%c(ASDisplayNode)]) {
			CGRect bounds = ((ASDisplayNode *)value).bounds;
			if (bounds.size.width > 1 && bounds.size.height > 1) return value;
		}
	}
	return nil;
}

// Content rect in node coordinates, plus whether the bubble is incoming (drawn on the left).
static CGRect contentRectOf(ASDisplayNode *node, BOOL *incoming) {
	CGRect nodeBounds = node.bounds;
	ASDisplayNode *content = contentNodeOf(node);
	CGRect rect = content ? [content convertRect:content.bounds toNode:node] : nodeBounds;
	if (incoming) *incoming = CGRectGetMidX(rect) < CGRectGetMidX(nodeBounds);
	return rect;
}

static void updateDeletedBadge(ASDisplayNode *node) {
	UIImageView *badge = objc_getAssociatedObject(node, kBadgeKey);
	BOOL deleted = NO;
	if (AYDeletedFilter.isEnabled) {
		@try {
			deleted = [AYDeletedMarks isDeletedWithNode:node];
		} @catch (NSException *exception) {
			deleted = NO;
		}
	}
	if (!deleted) {
		badge.hidden = YES;
		return;
	}
	if (!node.isNodeLoaded) return;

	if (!badge) {
		UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
		badge = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"trash.fill" withConfiguration:config]];
		badge.tintColor = [UIColor systemRedColor];
		badge.contentMode = UIViewContentModeCenter;
		badge.userInteractionEnabled = NO;
		objc_setAssociatedObject(node, kBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	CGRect nodeBounds = node.bounds;
	BOOL incoming = NO;
	CGRect rect = contentRectOf(node, &incoming);
	CGFloat size = 20;
	CGFloat x = incoming ? CGRectGetMaxX(rect) + 4 : CGRectGetMinX(rect) - size - 4;
	x = MAX(0, MIN(x, nodeBounds.size.width - size));
	badge.frame = CGRectMake(x, CGRectGetMaxY(rect) - size - 2, size, size);
	badge.hidden = NO;

	UIView *view = node.view;
	if (badge.superview != view) [view addSubview:badge];
	else [view bringSubviewToFront:badge];
}

// Presents the stored versions for the message under this button's node.
@interface AYEditHistoryViewer : UITableViewController
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *versions;
@end

@implementation AYEditHistoryViewer
- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = [ayTELELocalization localizedStringForKey:@"EDIT_HISTORY_TITLE"];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissSelf)];
}
- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.versions.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	NSInteger n = self.versions.count;
	if (n <= 0) return nil;
	NSString *fmt = [ayTELELocalization localizedStringForKey:@"EDIT_HISTORY_COUNT"];
	return [NSString stringWithFormat:fmt, (long)n];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"v"];
	if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"v"];
	NSArray<NSString *> *version = self.versions[indexPath.row];
	cell.textLabel.text = version.firstObject.length ? version.firstObject : @"—";
	cell.textLabel.numberOfLines = 0;
	NSString *label = (indexPath.row == 0)
		? [ayTELELocalization localizedStringForKey:@"EDIT_HISTORY_ORIGINAL"]
		: [ayTELELocalization localizedStringForKey:@"EDIT_HISTORY_EDITED"];
	NSInteger ts = version.count > 1 ? version[1].integerValue : 0;
	if (ts > 0) {
		NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
		NSDateFormatter *df = [NSDateFormatter new];
		df.dateStyle = NSDateFormatterMediumStyle;
		df.timeStyle = NSDateFormatterShortStyle;
		cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", label, [df stringFromDate:date]];
	} else {
		cell.detailTextLabel.text = label;
	}
	cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	return cell;
}
@end

// Shared tap target for pencil badges. The tapped node is associated with the button.
@interface AYEditBadgeHandler : NSObject
+ (instancetype)shared;
- (void)tapped:(UIButton *)sender;
@end

@implementation AYEditBadgeHandler
+ (instancetype)shared {
	static AYEditBadgeHandler *instance;
	static dispatch_once_t token;
	dispatch_once(&token, ^{ instance = [AYEditBadgeHandler new]; });
	return instance;
}
- (void)tapped:(UIButton *)sender {
	ASDisplayNode *node = objc_getAssociatedObject(sender, kEditBadgeKey);
	if (!node) return;
	NSArray<NSArray<NSString *> *> *versions = @[];
	@try { versions = [AYEditHistory versionsWithNode:node]; } @catch (NSException *e) { return; }
	if (versions.count == 0) return;
	AYEditHistoryViewer *viewer = [AYEditHistoryViewer new];
	viewer.versions = versions;
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:viewer];
	UIWindow *window = UIApplication.sharedApplication.keyWindow;
	UIViewController *presenter = window.rootViewController;
	while (presenter.presentedViewController) presenter = presenter.presentedViewController;
	[presenter presentViewController:nav animated:YES completion:nil];
}
@end

static void updateEditBadge(ASDisplayNode *node) {
	UIButton *badge = objc_getAssociatedObject(node, kEditBadgeKey);
	BOOL edited = NO;
	if (AYEditHistory.isEnabled) {
		@try {
			edited = [AYEditHistory isEditedWithNode:node];
		} @catch (NSException *exception) {
			edited = NO;
		}
	}
	if (!edited) {
		badge.hidden = YES;
		return;
	}
	if (!node.isNodeLoaded) return;

	if (!badge) {
		UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
		badge = [UIButton buttonWithType:UIButtonTypeSystem];
		[badge setImage:[UIImage systemImageNamed:@"pencil.circle.fill" withConfiguration:config] forState:UIControlStateNormal];
		badge.tintColor = [UIColor systemOrangeColor];
		[badge addTarget:[AYEditBadgeHandler shared] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
		objc_setAssociatedObject(node, kEditBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	// Keep the node reference current so the tap reads the right message.
	objc_setAssociatedObject(badge, kEditBadgeKey, node, OBJC_ASSOCIATION_ASSIGN);

	CGRect nodeBounds = node.bounds;
	BOOL incoming = NO;
	CGRect rect = contentRectOf(node, &incoming);
	CGFloat size = 22;
	CGFloat x = incoming ? CGRectGetMaxX(rect) + 4 : CGRectGetMinX(rect) - size - 4;
	x = MAX(0, MIN(x, nodeBounds.size.width - size));
	// Sit at the top outer corner so it never overlaps the trash badge (bottom corner).
	badge.frame = CGRectMake(x, CGRectGetMinY(rect) + 2, size, size);
	badge.hidden = NO;

	UIView *view = node.view;
	if (badge.superview != view) [view addSubview:badge];
	else [view bringSubviewToFront:badge];
}

static const void *kNoteBadgeKey = &kNoteBadgeKey;
static const void *kGestureInstalledKey = &kGestureInstalledKey;
static const void *kGestureNodeKey = &kGestureNodeKey;

// Info sheet: label / value rows for one message (#30).
@interface AYMessageInfoViewer : UITableViewController
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *lines;
@end
@implementation AYMessageInfoViewer
- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = [ayTELELocalization localizedStringForKey:@"MESSAGE_INFO_TITLE"];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissSelf)];
}
- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.lines.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	NSArray<NSString *> *line = self.lines[indexPath.row];
	cell.textLabel.text = [ayTELELocalization localizedStringForKey:line.firstObject];
	cell.detailTextLabel.text = line.count > 1 ? line[1] : @"";
	cell.detailTextLabel.numberOfLines = 0;
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	return cell;
}
@end

// Lists every private note across chats (#27).
@interface AYNotesListViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *notes;
@end
@implementation AYNotesListViewController
- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = [ayTELELocalization localizedStringForKey:@"NOTES_LIST_TITLE"];
	self.notes = [AYNotes all];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.notes.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
	NSArray<NSString *> *note = self.notes[indexPath.row];
	cell.textLabel.text = note.count > 1 ? note[1] : @"";
	cell.textLabel.numberOfLines = 0;
	cell.detailTextLabel.text = note.count > 2 ? note[2] : @"";
	cell.detailTextLabel.numberOfLines = 0;
	cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	return cell;
}
@end

// Browse deleted / edited messages (#56). A segmented control switches lists; tapping an edited
// row opens its version history.
@interface AYArchiveViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *edited;
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *deleted;
@property (nonatomic, assign) NSInteger mode; // 0 = edited, 1 = deleted
@end
@implementation AYArchiveViewController
- (void)viewDidLoad {
	[super viewDidLoad];
	self.edited = [AYEditHistory editedList];
	self.deleted = [AYDeletedMarks deletedList];
	UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[
		[ayTELELocalization localizedStringForKey:@"ARCHIVE_EDITED"],
		[ayTELELocalization localizedStringForKey:@"ARCHIVE_DELETED"]]];
	seg.selectedSegmentIndex = 0;
	[seg addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
	self.navigationItem.titleView = seg;
}
- (void)segChanged:(UISegmentedControl *)seg { self.mode = seg.selectedSegmentIndex; [self.tableView reloadData]; }
- (NSArray<NSArray<NSString *> *> *)rows { return self.mode == 0 ? self.edited : self.deleted; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.rows.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	if (self.rows.count > 0) return nil;
	return [ayTELELocalization localizedStringForKey:@"ARCHIVE_EMPTY"];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
	NSArray<NSString *> *row = self.rows[indexPath.row];
	NSString *text = row.count > 1 ? row[1] : @"";
	cell.textLabel.text = text.length ? text : @"—";
	cell.textLabel.numberOfLines = 2;
	if (self.mode == 0) {
		NSString *fmt = [ayTELELocalization localizedStringForKey:@"EDIT_HISTORY_COUNT"];
		cell.detailTextLabel.text = [NSString stringWithFormat:fmt, (long)(row.count > 2 ? row[2].integerValue : 0)];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	} else {
		cell.detailTextLabel.text = row.firstObject;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	}
	cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (self.mode != 0) return;
	NSArray<NSString *> *row = self.rows[indexPath.row];
	NSArray<NSArray<NSString *> *> *versions = [AYEditHistory versionsWithKey:row.firstObject];
	if (versions.count == 0) return;
	AYEditHistoryViewer *viewer = [AYEditHistoryViewer new];
	viewer.versions = versions;
	[self.navigationController pushViewController:viewer animated:YES];
}
@end

static UIViewController *topPresenter(void) {
	UIWindow *window = UIApplication.sharedApplication.keyWindow;
	UIViewController *presenter = window.rootViewController;
	while (presenter.presentedViewController) presenter = presenter.presentedViewController;
	return presenter;
}

// Lightweight self-dismissing toast, used to confirm a copy.
static void presentToast(NSString *message) {
	if (message.length == 0) return;
	UIWindow *window = UIApplication.sharedApplication.keyWindow;
	if (!window) return;
	UILabel *toast = [[UILabel alloc] init];
	toast.text = message;
	toast.textColor = [UIColor whiteColor];
	toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
	toast.textAlignment = NSTextAlignmentCenter;
	toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
	toast.numberOfLines = 0;
	toast.alpha = 0;
	toast.layer.cornerRadius = 14;
	toast.clipsToBounds = YES;
	CGFloat maxW = window.bounds.size.width - 80;
	CGSize fit = [toast sizeThatFits:CGSizeMake(maxW, 1000)];
	CGFloat w = MIN(maxW, fit.width + 28);
	CGFloat h = fit.height + 16;
	toast.frame = CGRectMake((window.bounds.size.width - w) / 2, window.bounds.size.height - h - 120, w, h);
	[window addSubview:toast];
	[UIView animateWithDuration:0.25 animations:^{ toast.alpha = 1; } completion:^(BOOL f1) {
		[UIView animateWithDuration:0.3 delay:1.1 options:0 animations:^{ toast.alpha = 0; } completion:^(BOOL f2) {
			[toast removeFromSuperview];
		}];
	}];
}

// Handles the per-message two-finger tap menu and the note badge tap.
@interface AYMessageActionHandler : NSObject
+ (instancetype)shared;
@end
@implementation AYMessageActionHandler
+ (instancetype)shared {
	static AYMessageActionHandler *instance;
	static dispatch_once_t token;
	dispatch_once(&token, ^{ instance = [AYMessageActionHandler new]; });
	return instance;
}
- (void)showInfoForNode:(NSObject *)node {
	NSArray<NSArray<NSString *> *> *lines = @[];
	@try { lines = [AYMessageDetails linesWithNode:node]; } @catch (NSException *e) { return; }
	if (lines.count == 0) return;
	AYMessageInfoViewer *viewer = [AYMessageInfoViewer new];
	viewer.lines = lines;
	[topPresenter() presentViewController:[[UINavigationController alloc] initWithRootViewController:viewer] animated:YES completion:nil];
}
- (void)showNoteEditorForNode:(NSObject *)node {
	NSString *existing = nil;
	@try { existing = [AYNotes noteWithNode:node]; } @catch (NSException *e) {}
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:[ayTELELocalization localizedStringForKey:@"PRIVATE_NOTE_TITLE"]
	                                                              message:nil
	                                                       preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
		field.placeholder = [ayTELELocalization localizedStringForKey:@"PRIVATE_NOTE_PLACEHOLDER"];
		field.text = existing;
		field.autocapitalizationType = UITextAutocapitalizationTypeSentences;
	}];
	[alert addAction:[UIAlertAction actionWithTitle:[ayTELELocalization localizedStringForKey:@"SAVE"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		NSString *text = alert.textFields.firstObject.text ?: @"";
		@try { [AYNotes setNoteWithNode:node text:text]; } @catch (NSException *e) {}
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:[ayTELELocalization localizedStringForKey:@"CANCEL"] style:UIAlertActionStyleCancel handler:nil]];
	[topPresenter() presentViewController:alert animated:YES completion:nil];
}
- (void)noteBadgeTapped:(UIButton *)sender {
	NSObject *node = objc_getAssociatedObject(sender, kGestureNodeKey);
	if (node) [self showNoteEditorForNode:node];
}
- (void)doubleTapCopy:(UITapGestureRecognizer *)gesture {
	if (gesture.state != UIGestureRecognizerStateRecognized) return;
	NSObject *node = objc_getAssociatedObject(gesture, kGestureNodeKey);
	if (!node) return;
	NSString *text = nil;
	@try { text = [AYMessageDetails textWithNode:node]; } @catch (NSException *e) { return; }
	if (text.length == 0) return;
	[UIPasteboard generalPasteboard].string = text;
	UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
	[fb impactOccurred];
	presentToast([ayTELELocalization localizedStringForKey:@"COPIED_TOAST"]);
}
- (void)twoFingerTap:(UITapGestureRecognizer *)gesture {
	if (gesture.state != UIGestureRecognizerStateRecognized) return;
	NSObject *node = objc_getAssociatedObject(gesture, kGestureNodeKey);
	if (!node) return;
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
	[sheet addAction:[UIAlertAction actionWithTitle:[ayTELELocalization localizedStringForKey:@"MSG_ACTION_INFO"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		[self showInfoForNode:node];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:[ayTELELocalization localizedStringForKey:@"MSG_ACTION_NOTE"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		[self showNoteEditorForNode:node];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:[ayTELELocalization localizedStringForKey:@"CANCEL"] style:UIAlertActionStyleCancel handler:nil]];
	UIView *view = ((ASDisplayNode *)node).view;
	sheet.popoverPresentationController.sourceView = view;
	sheet.popoverPresentationController.sourceRect = view.bounds;
	[topPresenter() presentViewController:sheet animated:YES completion:nil];
}
@end

// Two-finger tap on a message opens the info / note menu.
static void installMessageGesture(ASDisplayNode *node) {
	if (!node.isNodeLoaded) return;
	UITapGestureRecognizer *gesture = objc_getAssociatedObject(node, kGestureInstalledKey);
	if (!gesture) {
		gesture = [[UITapGestureRecognizer alloc] initWithTarget:[AYMessageActionHandler shared] action:@selector(twoFingerTap:)];
		gesture.numberOfTouchesRequired = 2;
		objc_setAssociatedObject(node, kGestureInstalledKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	objc_setAssociatedObject(gesture, kGestureNodeKey, node, OBJC_ASSOCIATION_ASSIGN);
	UIView *view = node.view;
	if (![view.gestureRecognizers containsObject:gesture]) [view addGestureRecognizer:gesture];
}

static const void *kCopyGestureKey = &kCopyGestureKey;

// One-finger double-tap to copy the message text. Opt-in (kDoubleTapCopy): added when the
// toggle is on and removed when it's off, so it never touches Telegram's own double-tap otherwise.
static void installCopyGesture(ASDisplayNode *node) {
	if (!node.isNodeLoaded) return;
	UIView *view = node.view;
	if (!view) return;
	BOOL want = [[NSUserDefaults standardUserDefaults] boolForKey:kDoubleTapCopy];
	UITapGestureRecognizer *gesture = objc_getAssociatedObject(node, kCopyGestureKey);
	if (want) {
		if (!gesture) {
			gesture = [[UITapGestureRecognizer alloc] initWithTarget:[AYMessageActionHandler shared] action:@selector(doubleTapCopy:)];
			gesture.numberOfTapsRequired = 2;
			gesture.numberOfTouchesRequired = 1;
			objc_setAssociatedObject(node, kCopyGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		objc_setAssociatedObject(gesture, kGestureNodeKey, node, OBJC_ASSOCIATION_ASSIGN);
		if (![view.gestureRecognizers containsObject:gesture]) [view addGestureRecognizer:gesture];
	} else if (gesture && [view.gestureRecognizers containsObject:gesture]) {
		[view removeGestureRecognizer:gesture];
	}
}

static void updateNoteBadge(ASDisplayNode *node) {
	UIButton *badge = objc_getAssociatedObject(node, kNoteBadgeKey);
	BOOL noted = NO;
	@try { noted = [AYNotes hasNoteWithNode:node]; } @catch (NSException *exception) { noted = NO; }
	if (!noted) { badge.hidden = YES; return; }
	if (!node.isNodeLoaded) return;

	if (!badge) {
		UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
		badge = [UIButton buttonWithType:UIButtonTypeSystem];
		[badge setImage:[UIImage systemImageNamed:@"note.text" withConfiguration:config] forState:UIControlStateNormal];
		badge.tintColor = [UIColor systemYellowColor];
		[badge addTarget:[AYMessageActionHandler shared] action:@selector(noteBadgeTapped:) forControlEvents:UIControlEventTouchUpInside];
		objc_setAssociatedObject(node, kNoteBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	objc_setAssociatedObject(badge, kGestureNodeKey, node, OBJC_ASSOCIATION_ASSIGN);

	CGRect nodeBounds = node.bounds;
	BOOL incoming = NO;
	CGRect rect = contentRectOf(node, &incoming);
	CGFloat size = 20;
	// Bottom inner corner, clear of the outer trash (bottom) and pencil (top) badges.
	CGFloat x = incoming ? CGRectGetMaxX(rect) - size - 4 : CGRectGetMinX(rect) + 4;
	x = MAX(0, MIN(x, nodeBounds.size.width - size));
	badge.frame = CGRectMake(x, CGRectGetMaxY(rect) - size - 2, size, size);
	badge.hidden = NO;

	UIView *view = node.view;
	if (badge.superview != view) [view addSubview:badge];
	else [view bringSubviewToFront:badge];
}

static void trackAndUpdate(ASDisplayNode *node) {
	if (!chatMessageItemViewClass || ![node isKindOfClass:chatMessageItemViewClass]) return;
	[trackedNodes addObject:node];
	updateDeletedBadge(node);
	updateEditBadge(node);
	updateNoteBadge(node);
	installMessageGesture(node);
	installCopyGesture(node);
}

// Chat item nodes don't override -layout, so ASDisplayNode's runs for them after ListView sizes them.
%hook ASDisplayNode

- (void)layout {
	%orig;
	trackAndUpdate(self);
}

%end

%ctor {
	chatMessageItemViewClass = objc_getClass("_TtC19ChatMessageItemView19ChatMessageItemView");
	trackedNodes = [NSHashTable weakObjectsHashTable];
	void (^refresh)(NSNotification *) = ^(NSNotification *note) {
		for (ASDisplayNode *node in trackedNodes.allObjects) {
			updateDeletedBadge(node);
			updateEditBadge(node);
			updateNoteBadge(node);
		}
	};
	[[NSNotificationCenter defaultCenter] addObserverForName:AYDeletedMarks.changedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
	[[NSNotificationCenter defaultCenter] addObserverForName:AYEditHistory.changedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
	[[NSNotificationCenter defaultCenter] addObserverForName:AYNotes.changedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
	%init;
}
