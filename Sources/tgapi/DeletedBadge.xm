#import "Headers.h"
#import <objc/runtime.h>

// Red trash badge next to messages that were deleted remotely (see AYDeletedMarks).

@interface ASDisplayNode : NSObject
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly, getter=isNodeLoaded) BOOL nodeLoaded;
@property (nonatomic) CGRect bounds;
- (CGRect)convertRect:(CGRect)rect toNode:(ASDisplayNode *)node;
@end

static Class chatMessageItemViewClass;
static NSHashTable<ASDisplayNode *> *trackedNodes;
static const void *kBadgeKey = &kBadgeKey;

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
	ASDisplayNode *content = contentNodeOf(node);
	CGRect rect = content ? [content convertRect:content.bounds toNode:node] : nodeBounds;
	BOOL incoming = CGRectGetMidX(rect) < CGRectGetMidX(nodeBounds);
	CGFloat size = 20;
	CGFloat x = incoming ? CGRectGetMaxX(rect) + 4 : CGRectGetMinX(rect) - size - 4;
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
	[[NSNotificationCenter defaultCenter] addObserverForName:AYDeletedMarks.changedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		for (ASDisplayNode *node in trackedNodes.allObjects) updateDeletedBadge(node);
	}];
	%init;
}
