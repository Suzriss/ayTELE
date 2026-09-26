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

static void trackAndUpdate(ASDisplayNode *node) {
	if (!chatMessageItemViewClass || ![node isKindOfClass:chatMessageItemViewClass]) return;
	[trackedNodes addObject:node];
	updateDeletedBadge(node);
	updateEditBadge(node);
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
		}
	};
	[[NSNotificationCenter defaultCenter] addObserverForName:AYDeletedMarks.changedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
	[[NSNotificationCenter defaultCenter] addObserverForName:AYEditHistory.changedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
	%init;
}
