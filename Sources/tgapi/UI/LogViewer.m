#import "Headers.h"
#import "../Logger/Logger.h"

// In-app viewer for the diagnostic log (customLog / customLog2 output). Shows the newest part of
// the file, lets the user share it as a file, or clear it before reproducing a problem — so one
// test on the device tells us where a feature broke instead of just "it doesn't work".

#define TGLoc(key) [ayTELELocalization localizedStringForKey:(key)]

// Only the tail is shown; a long session can grow the file well past what a text view handles well.
static const unsigned long long kAYLogTailBytes = 256 * 1024;

@interface AYLogViewController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@end

@implementation AYLogViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = TGLoc(@"LOGS_TITLE");
	self.view.backgroundColor = [UIColor colorWithRed:0x17 / 255.0 green:0x21 / 255.0 blue:0x2B / 255.0 alpha:1.0];

	UITextView *textView = [UITextView new];
	textView.editable = NO;
	textView.backgroundColor = [UIColor clearColor];
	textView.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
	textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	textView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
	textView.alwaysBounceVertical = YES;
	textView.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:textView];
	[NSLayoutConstraint activateConstraints:@[
		[textView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		[textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
	]];
	self.textView = textView;

	UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"] style:UIBarButtonItemStylePlain target:self action:@selector(shareLog:)];
	share.accessibilityLabel = TGLoc(@"LOGS_SHARE");
	UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"] style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
	clear.accessibilityLabel = TGLoc(@"LOGS_CLEAR");
	clear.tintColor = [UIColor systemRedColor];
	self.navigationItem.rightBarButtonItems = @[share, clear];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self reload];
}

- (void)reload {
	NSString *path = AYLogFilePath();
	NSFileHandle *handle = path ? [NSFileHandle fileHandleForReadingAtPath:path] : nil;
	NSString *text = nil;
	if (handle) {
		unsigned long long size = [handle seekToEndOfFile];
		[handle seekToFileOffset:size > kAYLogTailBytes ? size - kAYLogTailBytes : 0];
		NSData *data = [handle readDataToEndOfFile];
		[handle closeFile];
		// A tail cut can land inside a multi-byte character; lossy decoding keeps the rest readable.
		text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
		if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
	}
	text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	self.textView.text = text.length ? text : TGLoc(@"LOGS_EMPTY");
	if (text.length) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length, 0)];
		});
	}
}

- (void)shareLog:(UIBarButtonItem *)sender {
	NSString *path = AYLogFilePath();
	if (!path) return;
	// Share a copy with a readable name instead of the bundle-id file name.
	NSURL *copy = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:@"ayTELE-log.txt"];
	[[NSFileManager defaultManager] removeItemAtURL:copy error:nil];
	if (![[NSFileManager defaultManager] copyItemAtURL:[NSURL fileURLWithPath:path] toURL:copy error:nil]) return;
	UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[copy] applicationActivities:nil];
	activity.popoverPresentationController.barButtonItem = sender;
	[self presentViewController:activity animated:YES completion:nil];
}

- (void)clearLog {
	AYClearLog();
	[self reload];
}

@end
