#import "Headers.h"
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

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

// key is the node's message key (AYDeletedMarks.key), resolved once per update by the caller.
static void updateDeletedBadge(ASDisplayNode *node, NSString *key) {
	UIImageView *badge = objc_getAssociatedObject(node, kBadgeKey);
	BOOL deleted = key && AYDeletedFilter.isEnabled && [AYDeletedMarks isDeletedWithKey:key];
	if (!deleted) {
		badge.hidden = YES;
		return;
	}
	@try { [AYDeletedArchive backfillWithNode:node]; } @catch (NSException *exception) {}
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

static void updateEditBadge(ASDisplayNode *node, NSString *key) {
	UIButton *badge = objc_getAssociatedObject(node, kEditBadgeKey);
	BOOL edited = key && AYEditHistory.isEnabled && [AYEditHistory isEditedWithKey:key];
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
	if (self.rows.count == 0) return [ayTELELocalization localizedStringForKey:@"ARCHIVE_EMPTY"];
	return self.mode == 1 ? [ayTELELocalization localizedStringForKey:@"ARCHIVE_DELETED_NOTE"] : nil;
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
		if (text.length == 0) cell.textLabel.text = [ayTELELocalization localizedStringForKey:@"ARCHIVE_NO_TEXT"];
		NSString *chat = row.count > 2 ? row[2] : @"";
		NSString *from = row.count > 3 ? row[3] : @"";
		if ([from isEqualToString:@"me"]) from = [ayTELELocalization localizedStringForKey:@"ARCHIVE_FROM_ME"];
		NSMutableArray *parts = [NSMutableArray array];
		if (chat.length) [parts addObject:chat];
		if (from.length && ![from isEqualToString:chat]) [parts addObject:from];
		if (parts.count == 0) [parts addObject:row.firstObject];
		cell.detailTextLabel.text = [parts componentsJoinedByString:@" · "];
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

void AYPresentToast(NSString *message) { presentToast(message); }

// Sends the held read receipt for key, or explains that none is held.
static void revealReceipt(NSString *key) {
	if (![AYReceiptQueue hasHeldForKey:key]) {
		presentToast([ayTELELocalization localizedStringForKey:@"REVEAL_READ_NONE"]);
		return;
	}
	[AYReceiptQueue revealKey:key completion:^(BOOL ok) {
		presentToast([ayTELELocalization localizedStringForKey:ok ? @"REVEAL_READ_DONE" : @"REVEAL_READ_FAILED"]);
	}];
}

// Eye button in the story viewer: reveals that you watched the current peer's stories.
@interface AYStoryEyeHandler : NSObject
@end
@implementation AYStoryEyeHandler
+ (void)tapped:(UIButton *)sender {
	NSObject *view = sender.superview;
	NSString *key = nil;
	@try { key = [AYReceipts storyKeyWithView:view]; } @catch (NSException *e) {}
	if (![AYReceiptQueue hasHeldForKey:key]) key = [AYReceiptQueue latestStoryKey];
	revealReceipt(key);
}
@end

// ---------------------------------------------------------------------------
// Save button for the story viewer and the view-once / self-destruct viewer.
// Telegram hides its own save action for protected and ephemeral media; this
// captures exactly what is on screen (a full-resolution still for photos, a
// frame for video) and writes it to Photos. No TL layer, no Swift symbols.
// ---------------------------------------------------------------------------

// The largest UIImageView holding a real image inside root: for a photo story or
// a view-once photo this is the decoded media at full resolution (the avatar and
// small chrome images are far smaller and fall below minArea).
static UIImageView *bestImageView(UIView *root, CGFloat minArea) {
	if (!root) return nil;
	UIImageView *best = nil;
	CGFloat bestArea = minArea;
	for (UIView *sub in root.subviews) {
		if ([sub isKindOfClass:[UIImageView class]]) {
			UIImage *img = ((UIImageView *)sub).image;
			if (img) {
				CGFloat area = img.size.width * img.size.height;
				if (area >= bestArea && !sub.hidden && sub.alpha > 0.01) { best = (UIImageView *)sub; bestArea = area; }
			}
		}
		UIImageView *deeper = bestImageView(sub, bestArea);
		if (deeper) { best = deeper; bestArea = deeper.image.size.width * deeper.image.size.height; }
	}
	return best;
}

// The largest decoded image drawn straight onto a layer (Telegram's display nodes set layer.contents
// to a CGImage rather than using UIImageView), so photo stories save at full resolution.
static CGImageRef bestLayerImage(CALayer *layer, CGFloat *bestArea) {
	if (!layer || layer.hidden || layer.opacity < 0.01) return NULL;
	CGImageRef best = NULL;
	id contents = layer.contents;
	if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID()) {
		CGImageRef img = (__bridge CGImageRef)contents;
		CGFloat area = (CGFloat)CGImageGetWidth(img) * (CGFloat)CGImageGetHeight(img);
		if (area > *bestArea) { best = img; *bestArea = area; }
	}
	for (CALayer *sub in layer.sublayers) {
		CGImageRef deeper = bestLayerImage(sub, bestArea);
		if (deeper) best = deeper;
	}
	return best;
}

// The local file behind a video that is playing through an AVPlayerLayer somewhere under layer.
static NSURL *playingFileURL(CALayer *layer) {
	if (!layer) return nil;
	if ([layer isKindOfClass:[AVPlayerLayer class]]) {
		AVAsset *asset = ((AVPlayerLayer *)layer).player.currentItem.asset;
		if ([asset isKindOfClass:[AVURLAsset class]]) {
			NSURL *url = ((AVURLAsset *)asset).URL;
			if (url.isFileURL && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) return url;
		}
	}
	for (CALayer *sub in layer.sublayers) {
		NSURL *found = playingFileURL(sub);
		if (found) return found;
	}
	return nil;
}

// First descendant that is a kind of cls (the media content view, free of chrome).
static UIView *firstDescendantOfClass(UIView *root, Class cls) {
	if (!root || !cls) return nil;
	for (UIView *sub in root.subviews) {
		if ([sub isKindOfClass:cls]) return sub;
		UIView *deeper = firstDescendantOfClass(sub, cls);
		if (deeper) return deeper;
	}
	return nil;
}

// Renders a view (with hide temporarily removed from the frame) to an image.
static UIImage *snapshotOfView(UIView *v, UIView *hide) {
	if (!v || v.bounds.size.width < 1 || v.bounds.size.height < 1) return nil;
	BOOL wasHidden = hide.hidden;
	hide.hidden = YES;
	UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
	UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:v.bounds format:fmt];
	UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
		[v drawViewHierarchyInRect:v.bounds afterScreenUpdates:YES];
	}];
	if (hide) hide.hidden = wasHidden;
	return out;
}

// The enclosing view controller of a view (to reflect a viewer's Swift state for the media size).
static UIViewController *enclosingController(UIView *view) {
	for (UIResponder *r = view.nextResponder; r; r = r.nextResponder) {
		if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
	}
	return nil;
}

// Postbox media cache directories, found once by scanning the app container for a "postbox/media"
// folder. We look at directories only and never descend into the media folder itself, so it is cheap.
static NSArray<NSString *> *postboxMediaDirs(void) {
	static NSArray *cached;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableArray<NSString *> *found = [NSMutableArray array];
		NSFileManager *fm = [NSFileManager defaultManager];
		// Search the app's home and a couple of levels up (shared/app-group containers).
		NSMutableArray<NSString *> *roots = [NSMutableArray arrayWithObject:NSHomeDirectory()];
		NSString *up1 = [NSHomeDirectory() stringByDeletingLastPathComponent];
		NSString *up2 = [up1 stringByDeletingLastPathComponent];
		if (up1) [roots addObject:up1];
		if (up2) [roots addObject:up2];
		NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithArray:roots];
		NSMutableDictionary<NSString *, NSNumber *> *depths = [NSMutableDictionary dictionary];
		for (NSString *r in roots) depths[r] = @0;
		int scanned = 0;
		while (stack.count && scanned < 20000) {
			NSString *dir = stack.lastObject; [stack removeLastObject];
			int depth = depths[dir].intValue;
			scanned++;
			if ([dir hasSuffix:@"postbox/media"]) { [found addObject:dir]; continue; }  // don't descend
			if (depth >= 7) continue;
			NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
			for (NSString *name in items) {
				NSString *full = [dir stringByAppendingPathComponent:name];
				BOOL isDir = NO;
				if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
					[stack addObject:full];
					depths[full] = @(depth + 1);
				}
			}
		}
		cached = found;
	});
	return cached;
}

// Decodes a lowercase hex string (the file_reference) into bytes.
static NSData *hexToData(NSString *hex) {
	if (hex.length < 2) return [NSData data];
	NSMutableData *out = [NSMutableData dataWithCapacity:hex.length / 2];
	const char *c = hex.UTF8String;
	for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
		int hi = c[i], lo = c[i+1];
		hi = (hi >= 'a') ? hi - 'a' + 10 : hi - '0';
		lo = (lo >= 'a') ? lo - 'a' + 10 : lo - '0';
		uint8_t byte = (uint8_t)((hi << 4) | lo);
		[out appendBytes:&byte length:1];
	}
	return out;
}

// True when the first bytes look like an MP4/QuickTime container ("....ftyp").
static BOOL looksLikeVideoFile(NSString *path) {
	NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
	if (!fh) return NO;
	NSData *head = [fh readDataOfLength:12];
	[fh closeFile];
	if (head.length < 12) return NO;
	const uint8_t *b = (const uint8_t *)head.bytes;
	return b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p';
}

// Roots to search for a cached media file: the app home and a couple of levels up (app-group /
// shared containers), plus the account container that holds each postbox/media we found. A story
// video is not always under postbox/media — it can sit in a sibling cache of that account.
static NSArray<NSString *> *mediaSearchRoots(void) {
	static NSArray *cached;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableOrderedSet<NSString *> *roots = [NSMutableOrderedSet orderedSet];
		// Most precise first: the account container (parent of "postbox", i.e. two levels above
		// postbox/media) and the shared container that holds all accounts and global caches.
		for (NSString *mediaDir in postboxMediaDirs()) {
			NSString *accountDir = [[mediaDir stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
			if (accountDir.length) [roots addObject:accountDir];
			NSString *sharedDir = [accountDir stringByDeletingLastPathComponent];  // .../accounts-metadata's parent
			if (sharedDir.length) [roots addObject:sharedDir];
		}
		// The app's own sandbox (Library/Caches, tmp) in case a story is streamed to a short-term cache.
		if (NSHomeDirectory()) [roots addObject:NSHomeDirectory()];
		cached = [roots array];
	});
	return cached;
}

// Finds the cached story/secret video. Telegram's MediaBox names a cached file from the resource's
// fileId, so a filename containing `fileId` is the strongest match (a streamed story is not stored
// by its byte size). Falls back to an exact byte-size match, preferring an MP4/QuickTime header.
// `debugOut` gets a trace, including the largest files seen so a miss shows how the video is stored.
static NSString *findVideoFileWithSize(long long size, long long fileId, NSString **debugOut) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *idStr = fileId != 0 ? [NSString stringWithFormat:@"%lld", fileId] : nil;
	NSString *nameMatch = nil, *ftypMatch = nil, *sizeOnlyMatch = nil;
	int sizeMatches = 0, scanned = 0;
	// Track the few largest files for diagnostics when nothing matches.
	long long big1 = 0, big2 = 0; NSString *big1Name = nil, *big2Name = nil;
	for (NSString *dir in mediaSearchRoots()) {
		NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
		for (NSString *rel in en) {
			if (++scanned > 600000) break;
			NSDictionary *attrs = [en fileAttributes];  // no extra stat; provided by the enumerator
			if ([attrs.fileType isEqualToString:NSFileTypeDirectory]) continue;
			long long fsize = (long long)attrs.fileSize;
			NSString *name = [rel lastPathComponent];
			// A file named after the resource and big enough to be the video (not its thumbnail).
			if (idStr && fsize > 65536 && [name rangeOfString:idStr].location != NSNotFound) {
				nameMatch = [dir stringByAppendingPathComponent:rel]; break;
			}
			if (fsize > big1) { big2 = big1; big2Name = big1Name; big1 = fsize; big1Name = name; }
			else if (fsize > big2) { big2 = fsize; big2Name = name; }
			if (size > 0 && fsize == size) {
				sizeMatches++;
				NSString *full = [dir stringByAppendingPathComponent:rel];
				if (looksLikeVideoFile(full)) { if (!ftypMatch) ftypMatch = full; }
				else if (!sizeOnlyMatch) sizeOnlyMatch = full;
			}
		}
		if (nameMatch) break;
	}
	NSString *chosen = nameMatch ?: ftypMatch ?: sizeOnlyMatch;
	if (debugOut) *debugOut = [NSString stringWithFormat:@"scanned %d, size-matches %d, %@; biggest %lld(%@),%lld(%@)",
		scanned, sizeMatches,
		nameMatch ? @"NAME hit" : (ftypMatch ? @"ftyp hit" : (sizeOnlyMatch ? @"size-only hit" : @"no hit")),
		big1, big1Name ?: @"-", big2, big2Name ?: @"-"];
	return chosen;
}

@interface AYMediaSaveHandler : NSObject
@end
@implementation AYMediaSaveHandler
+ (void)commit:(UIImage *)img note:(NSString *)note {
	if (!img) { presentToast([ayTELELocalization localizedStringForKey:@"SAVE_MEDIA_FAILED"]); return; }
	// Carry the "this is only a frame" note through to the completion callback via associated object.
	UIImageWriteToSavedPhotosAlbum(img, self, @selector(image:didFinishSavingWithError:contextInfo:), (void *)CFBridgingRetain(note ?: @"SAVE_MEDIA_DONE"));
}
+ (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)ctx {
	if (error) customLog(@"save: Photos refused the image: %@", error);
	NSString *okKey = ctx ? (NSString *)CFBridgingRelease(ctx) : @"SAVE_MEDIA_DONE";
	presentToast([ayTELELocalization localizedStringForKey:error ? @"SAVE_MEDIA_FAILED" : okKey]);
}
// Copies the cached video to a .mp4 temp Photos will accept, then saves it.
+ (void)saveVideoAtPath:(NSString *)path {
	NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ayTELE-%@.mp4", [NSUUID UUID].UUIDString]];
	NSError *err = nil;
	[[NSFileManager defaultManager] copyItemAtPath:path toPath:tmp error:&err];
	if (err || !UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(tmp)) {
		customLog(@"save: video at %@ rejected (copy error=%@)", path.lastPathComponent, err);
		[[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
		presentToast([ayTELELocalization localizedStringForKey:@"SAVE_MEDIA_FAILED"]);
		return;
	}
	UISaveVideoAtPathToSavedPhotosAlbum(tmp, self, @selector(video:didFinishSavingWithError:contextInfo:), (void *)CFBridgingRetain(tmp));
}
// Writes downloaded video bytes to a temp .mp4, then saves it the same way.
+ (void)saveVideoData:(NSData *)data {
	NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ayTELE-%@.mp4", [NSUUID UUID].UUIDString]];
	if (![data writeToFile:tmp atomically:YES] || !UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(tmp)) {
		customLog(@"save: downloaded data not a saveable video (%lu bytes)", (unsigned long)data.length);
		[[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
		presentToast([ayTELELocalization localizedStringForKey:@"SAVE_MEDIA_FAILED"]);
		return;
	}
	UISaveVideoAtPathToSavedPhotosAlbum(tmp, self, @selector(video:didFinishSavingWithError:contextInfo:), (void *)CFBridgingRetain(tmp));
}
+ (void)video:(NSString *)path didFinishSavingWithError:(NSError *)error contextInfo:(void *)ctx {
	if (error) customLog(@"save: Photos refused the video: %@", error);
	if (ctx) { NSString *tmp = (NSString *)CFBridgingRelease(ctx); [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil]; }
	presentToast([ayTELELocalization localizedStringForKey:error ? @"SAVE_MEDIA_FAILED" : @"SAVE_MEDIA_DONE"]);
}
// container: the view to read pixels from. reflect: the Swift viewer object to read the video size
// from. contentClass: the media view to snapshot as a last resort. hide: our button, kept out of it.
+ (void)saveFromContainer:(UIView *)container reflect:(NSObject *)reflect contentClass:(Class)contentClass hide:(UIView *)hide {
	if (!container) { customLog(@"save: no container view"); [self commit:nil note:nil]; return; }
	UIView *content = contentClass ? firstDescendantOfClass(container, contentClass) : nil;
	UIView *media = content ?: container;

	// 1) A video playing from a local file: save that exact file.
	NSURL *playing = nil;
	@try { playing = playingFileURL(media.layer) ?: playingFileURL(container.layer); } @catch (NSException *e) {}
	if (playing) {
		customLog(@"save: playing file %@", playing.lastPathComponent);
		[self saveVideoAtPath:playing.path];
		return;
	}

	// Everything else that has to be read on the main thread, gathered up front. Reflect the viewer
	// for the video's byte size; if that comes up empty, try the inner content view, whose component
	// state is where the story item (and its media) actually lives.
	// Resource descriptor of the story/secret video: "size|fileId|dc|accessHash|fileRefHex|debug".
	__block long long size = 0, fileId = 0, accessHash = 0;
	__block NSString *fileRefHex = @"";
	__block NSString *sizeDebug = nil;
	void (^parseInfo)(NSString *) = ^(NSString *r) {
		NSArray<NSString *> *p = [r componentsSeparatedByString:@"|"];
		size = p.count > 0 ? p[0].longLongValue : 0;
		fileId = p.count > 1 ? p[1].longLongValue : 0;
		accessHash = p.count > 3 ? p[3].longLongValue : 0;
		fileRefHex = p.count > 4 ? p[4] : @"";
		sizeDebug = r;
	};
	@try {
		parseInfo([AYMediaFile videoByteSizeDebugFrom:reflect]);
		if (size <= 0 && content) {
			NSString *r2 = [AYMediaFile videoByteSizeDebugFrom:content];
			if ([r2 componentsSeparatedByString:@"|"].firstObject.longLongValue > 0) {
				parseInfo(r2);
				sizeDebug = [@"content:" stringByAppendingString:r2];
			}
		}
	} @catch (NSException *e) {}
	UIImage *photo = nil;
	@try {
		UIImageView *iv = bestImageView(media, 200.0 * 200.0);
		CGFloat layerArea = 200.0 * 200.0;
		CGImageRef layerImage = bestLayerImage(media.layer, &layerArea);
		CGFloat viewArea = iv.image ? iv.image.size.width * iv.image.scale * iv.image.size.height * iv.image.scale : 0;
		if (layerImage && layerArea > viewArea) photo = [UIImage imageWithCGImage:layerImage];
		else if (iv.image) photo = iv.image;
	} @catch (NSException *e) {}
	UIImage *frame = nil;
	@try { frame = snapshotOfView(media, hide); } @catch (NSException *e) {}
	customLog(@"save: viewer=%@ content=%@ videoSize=%lld photo=%.0fx%.0f [%@]",
		NSStringFromClass([reflect class]), content ? NSStringFromClass([content class]) : @"-", size,
		photo.size.width * photo.scale, photo.size.height * photo.scale,
		sizeDebug ?: @"-");

	// 2) A video: match its exact byte size against the Postbox cache off the main thread. Checked
	// before the photo, because a video story also shows its still preview underneath.
	if (size > 0) {
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSString *dbg = nil;
			NSString *path = findVideoFileWithSize(size, fileId, &dbg);
			if (path) {  // already on disk: save straight away
				dispatch_async(dispatch_get_main_queue(), ^{
					customLog(@"save: cache hit for %lld bytes (fileId %lld) -> %@", size, fileId, path.lastPathComponent);
					[self saveVideoAtPath:path];
				});
				return;
			}
			// Not cached (a streamed story keeps no file): pull it from the server by its resource.
			dispatch_async(dispatch_get_main_queue(), ^{
				customLog(@"save: cache miss (fileId %lld) -> downloading (%@)", fileId, dbg ?: @"-");
			});
			if (fileId == 0) { dispatch_async(dispatch_get_main_queue(), ^{ [self commit:frame note:@"SAVE_MEDIA_FRAME"]; }); return; }
			NSData *ref = hexToData(fileRefHex);
			[AYStoryDownload downloadFileId:fileId accessHash:accessHash fileRef:ref sizeHint:size completion:^(NSData *data, NSString *err) {
				dispatch_async(dispatch_get_main_queue(), ^{
					if (data.length) {
						customLog(@"save: downloaded %lu bytes -> saving video", (unsigned long)data.length);
						[self saveVideoData:data];
					} else {
						customLog(@"save: download failed (%@), saving a frame", err ?: @"?");
						[self commit:frame note:@"SAVE_MEDIA_FRAME"];
					}
				});
			}];
		});
		return;
	}

	// 3) A photo at full resolution; 4) otherwise what is on screen.
	if (photo) { [self commit:photo note:@"SAVE_MEDIA_DONE"]; return; }
	customLog(@"save: no photo or video found, saving a screen frame");
	[self commit:frame note:@"SAVE_MEDIA_FRAME"];
}
+ (void)saveStory:(UIButton *)sender {
	Class content = objc_getClass("_TtCC20StoryContainerScreen16StoryContentItem4View");
	// The container view is itself the Swift component view holding the current story item.
	[self saveFromContainer:sender.superview reflect:sender.superview contentClass:content hide:sender];
	[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}
+ (void)saveSecret:(UIButton *)sender {
	// The button sits on the controller's root view; reflect the controller for the message media.
	[self saveFromContainer:sender.superview reflect:enclosingController(sender) contentClass:nil hide:sender];
	[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}
@end

// Builds (once) and positions a round Save button as a subview of view.
static UIButton *ensureSaveButton(UIView *view, const void *key, id target, SEL action) {
	UIButton *save = objc_getAssociatedObject(view, key);
	if (!save) {
		save = [UIButton buttonWithType:UIButtonTypeSystem];
		UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
		[save setImage:[UIImage systemImageNamed:@"square.and.arrow.down.fill" withConfiguration:config] forState:UIControlStateNormal];
		save.tintColor = [UIColor whiteColor];
		save.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
		save.layer.cornerRadius = 18;
		save.accessibilityLabel = [ayTELELocalization localizedStringForKey:@"SAVE_MEDIA_BUTTON"];
		[save addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
		objc_setAssociatedObject(view, key, save, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[view addSubview:save];
	}
	return save;
}

static const void *kStoryEyeKey = &kStoryEyeKey;
static const void *kStorySaveKey = &kStorySaveKey;

%group StoryEye
%hook StoryItemSetContainerView
- (void)layoutSubviews {
	%orig;
	UIView *view = (UIView *)self;
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	CGFloat top = view.safeAreaInsets.top > 0 ? view.safeAreaInsets.top : 20;
	CGFloat right = view.bounds.size.width - 36 - 16;

	// Eye button (reveal that you watched) — shown while story receipts are blocked.
	BOOL eyeOn = [d boolForKey:kDisableStoriesReadReceipt];
	UIButton *eye = objc_getAssociatedObject(view, kStoryEyeKey);
	if (eyeOn) {
		if (!eye) {
			eye = [UIButton buttonWithType:UIButtonTypeSystem];
			[eye setImage:[UIImage systemImageNamed:@"eye.fill"] forState:UIControlStateNormal];
			eye.tintColor = [UIColor whiteColor];
			eye.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
			eye.layer.cornerRadius = 18;
			eye.accessibilityLabel = [ayTELELocalization localizedStringForKey:@"MSG_ACTION_REVEAL_READ"];
			[eye addTarget:[AYStoryEyeHandler class] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
			objc_setAssociatedObject(view, kStoryEyeKey, eye, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[view addSubview:eye];
		}
		eye.hidden = NO;
		eye.frame = CGRectMake(right, top + 64, 36, 36);
		[view bringSubviewToFront:eye];
	} else if (eye) {
		eye.hidden = YES;
	}

	// Save button — captures the story to Photos. Stacks under the eye when both show.
	BOOL saveOn = [d boolForKey:kSaveInViewers];
	UIButton *save = objc_getAssociatedObject(view, kStorySaveKey);
	if (saveOn) {
		save = ensureSaveButton(view, kStorySaveKey, [AYMediaSaveHandler class], @selector(saveStory:));
		save.hidden = NO;
		save.frame = CGRectMake(right, eyeOn ? top + 64 + 44 : top + 64, 36, 36);
		[view bringSubviewToFront:save];
	} else if (save) {
		save.hidden = YES;
	}
}
%end
%end

static const void *kSecretSaveKey = &kSecretSaveKey;

%group SecretMediaSave
%hook SecretMediaPreviewController
- (void)viewDidLayoutSubviews {
	%orig;
	UIViewController *ctrl = (UIViewController *)self;
	UIView *view = ctrl.view;
	UIButton *save = objc_getAssociatedObject(view, kSecretSaveKey);
	if (![[NSUserDefaults standardUserDefaults] boolForKey:kSaveInViewers]) {
		save.hidden = YES;
		return;
	}
	save = ensureSaveButton(view, kSecretSaveKey, [AYMediaSaveHandler class], @selector(saveSecret:));
	save.hidden = NO;
	CGFloat top = view.safeAreaInsets.top > 0 ? view.safeAreaInsets.top : 20;
	save.frame = CGRectMake(view.bounds.size.width - 36 - 16, top + 8, 36, 36);
	[view bringSubviewToFront:save];
}
%end
%end

// Floating eye button in a chat (ChatControllerImpl) while message read receipts are blocked:
// reveals the held receipt for that chat. Draggable; its position is remembered.
static NSString *const kChatEyePositionKey = @"ayTELEChatEyePosition";
static const void *kChatEyeKey = &kChatEyeKey;
static NSHashTable<UIButton *> *chatEyes;

// The chat this eye belongs to, without guessing: toggling must never hit another chat.
static NSString *exactChatEyeKey(UIButton *eye) {
	NSObject *controller = eye.superview.nextResponder;
	if (![controller isKindOfClass:[UIViewController class]]) return nil;
	@try { return [AYReceipts chatKeyWithController:controller]; } @catch (NSException *e) { return nil; }
}

// Green eye with a slash: reads in this chat stay hidden. Red open eye: reads are sent.
static void refreshChatEye(UIButton *eye) {
	if (!eye.superview) return;
	eye.hidden = ![[NSUserDefaults standardUserDefaults] boolForKey:kDisableMessageReadReceipt];
	BOOL seen = [AYReceipts isAllowedWithKey:exactChatEyeKey(eye)];
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
	[eye setImage:[UIImage systemImageNamed:seen ? @"eye.fill" : @"eye.slash.fill" withConfiguration:config] forState:UIControlStateNormal];
	eye.backgroundColor = seen ? [UIColor colorWithRed:0.92 green:0.23 blue:0.21 alpha:0.92] : [UIColor colorWithRed:0.18 green:0.72 blue:0.35 alpha:0.92];
	eye.alpha = 1.0;
	[eye.superview bringSubviewToFront:eye];
}

static void placeChatEye(UIButton *eye) {
	UIView *view = eye.superview;
	if (!view) return;
	CGSize bounds = view.bounds.size;
	CGFloat size = eye.bounds.size.width;
	// Stored as fractions of the view so it survives rotation and split view.
	NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kChatEyePositionKey];
	// Default to the top-right corner (just under the nav bar), not floating in the middle of the chat.
	CGFloat fx = saved.count == 2 ? [saved[0] doubleValue] : 1.0;
	CGFloat fy = saved.count == 2 ? [saved[1] doubleValue] : 0.1;
	CGFloat x = MAX(size / 2 + 8, MIN(bounds.width - size / 2 - 8, fx * bounds.width));
	CGFloat y = MAX(view.safeAreaInsets.top + size / 2 + 8, MIN(bounds.height - view.safeAreaInsets.bottom - size / 2 - 8, fy * bounds.height));
	eye.center = CGPointMake(x, y);
}

@interface AYChatEyeHandler : NSObject
@end
@implementation AYChatEyeHandler
+ (void)tapped:(UIButton *)sender {
	NSString *key = exactChatEyeKey(sender);
	if (!key) {
		presentToast([ayTELELocalization localizedStringForKey:@"EYE_CHAT_UNKNOWN"]);
		return;
	}
	BOOL seen = ![AYReceipts isAllowedWithKey:key];
	[AYReceipts setAllowed:seen key:key];
	refreshChatEye(sender);
	[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
	if (seen && [AYReceiptQueue hasHeldForKey:key]) {
		// Send what was held back, so the chat shows as read right away.
		[AYReceiptQueue revealKey:key completion:^(BOOL ok) {
			presentToast([ayTELELocalization localizedStringForKey:ok ? @"EYE_CHAT_SEEN" : @"REVEAL_READ_FAILED"]);
		}];
	} else {
		presentToast([ayTELELocalization localizedStringForKey:seen ? @"EYE_CHAT_SEEN" : @"EYE_CHAT_HIDDEN"]);
	}
}
+ (void)dragged:(UIPanGestureRecognizer *)pan {
	UIView *eye = pan.view;
	UIView *view = eye.superview;
	if (!view) return;
	CGPoint translation = [pan translationInView:view];
	eye.center = CGPointMake(eye.center.x + translation.x, eye.center.y + translation.y);
	[pan setTranslation:CGPointZero inView:view];
	if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
		CGSize bounds = view.bounds.size;
		if (bounds.width > 0 && bounds.height > 0) {
			[[NSUserDefaults standardUserDefaults] setObject:@[@(eye.center.x / bounds.width), @(eye.center.y / bounds.height)] forKey:kChatEyePositionKey];
		}
		placeChatEye((UIButton *)eye);
	}
}
@end

%group ChatEye
%hook ChatControllerImpl
- (void)viewDidAppear:(BOOL)animated {
	%orig;
	UIViewController *controller = (UIViewController *)self;
	UIButton *eye = objc_getAssociatedObject(controller, kChatEyeKey);
	if (![[NSUserDefaults standardUserDefaults] boolForKey:kDisableMessageReadReceipt]) {
		eye.hidden = YES;
		return;
	}
	if (!eye) {
		UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
		eye = [UIButton buttonWithType:UIButtonTypeSystem];
		[eye setImage:[UIImage systemImageNamed:@"eye.fill" withConfiguration:config] forState:UIControlStateNormal];
		eye.tintColor = [UIColor whiteColor];
		eye.backgroundColor = [UIColor colorWithRed:0.16 green:0.55 blue:0.96 alpha:0.9];
		eye.bounds = CGRectMake(0, 0, 40, 40);
		eye.layer.cornerRadius = 20;
		eye.layer.zPosition = 1000;
		eye.layer.shadowColor = [UIColor blackColor].CGColor;
		eye.layer.shadowOpacity = 0.25;
		eye.layer.shadowRadius = 4;
		eye.layer.shadowOffset = CGSizeMake(0, 2);
		eye.accessibilityLabel = [ayTELELocalization localizedStringForKey:@"MSG_ACTION_REVEAL_READ"];
		[eye addTarget:[AYChatEyeHandler class] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
		[eye addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:[AYChatEyeHandler class] action:@selector(dragged:)]];
		objc_setAssociatedObject(controller, kChatEyeKey, eye, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[chatEyes addObject:eye];
	}
	if (eye.superview != controller.view) [controller.view addSubview:eye];
	placeChatEye(eye);
	refreshChatEye(eye);
}
%end
%end

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
	// Read the message aloud on-device (opt-in).
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kReadAloud]) {
		[sheet addAction:[UIAlertAction actionWithTitle:[ayTELELocalization localizedStringForKey:@"MSG_ACTION_READ_ALOUD"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
			NSString *text = nil;
			@try { text = [AYMessageDetails textWithNode:node]; } @catch (NSException *e) {}
			if (text.length) [AYReadAloud speak:text];
			else presentToast([ayTELELocalization localizedStringForKey:@"READ_ALOUD_EMPTY"]);
		}]];
	}
	// Offered whenever read receipts are blocked; says so when nothing is held for this chat.
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableMessageReadReceipt]) {
		NSString *peerKey = nil;
		@try { peerKey = [AYReceipts peerKeyWithNode:node]; } @catch (NSException *e) {}
		[sheet addAction:[UIAlertAction actionWithTitle:[ayTELELocalization localizedStringForKey:@"MSG_ACTION_REVEAL_READ"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
			revealReceipt(peerKey);
		}]];
	}
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

static void updateNoteBadge(ASDisplayNode *node, NSString *key) {
	UIButton *badge = objc_getAssociatedObject(node, kNoteBadgeKey);
	BOOL noted = key && [AYNotes hasNoteWithKey:key];
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

// Resolves the message key once (it's reflection) and only when some badge could show.
static void updateBadges(ASDisplayNode *node) {
	NSString *key = nil;
	if (AYDeletedFilter.isEnabled || AYEditHistory.isEnabled || !AYNotes.isEmpty) {
		@try { key = [AYDeletedMarks keyWithNode:node]; } @catch (NSException *exception) {}
	}
	updateDeletedBadge(node, key);
	updateEditBadge(node, key);
	updateNoteBadge(node, key);
}

static void trackAndUpdate(ASDisplayNode *node) {
	if (!chatMessageItemViewClass || ![node isKindOfClass:chatMessageItemViewClass]) return;
	[trackedNodes addObject:node];
	updateBadges(node);
	installMessageGesture(node);
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
		for (ASDisplayNode *node in trackedNodes.allObjects) updateBadges(node);
	};
	[[NSNotificationCenter defaultCenter] addObserverForName:AYDeletedMarks.changedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
	[[NSNotificationCenter defaultCenter] addObserverForName:AYEditHistory.changedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
	[[NSNotificationCenter defaultCenter] addObserverForName:AYNotes.changedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
	chatEyes = [NSHashTable weakObjectsHashTable];
	[[NSNotificationCenter defaultCenter] addObserverForName:kAYReceiptsChangedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		for (UIButton *eye in chatEyes.allObjects) refreshChatEye(eye);
	}];
	%init;
	Class storyView = objc_getClass("_TtCC20StoryContainerScreen30StoryItemSetContainerComponent4View");
	if (storyView) %init(StoryEye, StoryItemSetContainerView = storyView);
	Class chatController = objc_getClass("_TtC10TelegramUI18ChatControllerImpl");
	if (chatController) %init(ChatEye, ChatControllerImpl = chatController);
	Class secretViewer = objc_getClass("_TtC9GalleryUI28SecretMediaPreviewController");
	if (secretViewer) %init(SecretMediaSave, SecretMediaPreviewController = secretViewer);
}
