#import "Headers.h"
#import <objc/runtime.h>
#import <PhotosUI/PhotosUI.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>

// Sticker / cut-out from a photo (kStickerFromImage, #42): a scissors button above the chat text
// field. Pick a photo, Vision lifts the subject off its background (iOS 17+
// VNGenerateForegroundInstanceMaskRequest), and the transparent PNG is uploaded and sent into the
// current chat over raw MTProto (same pipeline as the voice send). It sends a transparent image
// document — a true WEBP sticker would need a WEBP encoder iOS doesn't ship, noted for later.

// iOS 17+ foreground-instance-mask Vision API, absent from the 16.5 build SDK. Declared here so the
// code compiles; the request class is resolved at runtime via NSClassFromString (no link-time class
// symbol) and only reached under an @available(iOS 17.0, *) guard, so older systems never touch it.
@interface VNInstanceMaskObservation : VNObservation
@property (nonatomic, readonly) NSIndexSet *allInstances;
- (CVPixelBufferRef)generateMaskedImageOfInstances:(NSIndexSet *)instances fromRequestHandler:(VNImageRequestHandler *)requestHandler croppedToInstancesExtent:(BOOL)cropResult error:(NSError **)error CF_RETURNS_RETAINED;
@end

@interface VNGenerateForegroundInstanceMaskRequest : VNImageBasedRequest
@property (nonatomic, readonly, copy) NSArray<VNInstanceMaskObservation *> *results;
@end

@interface ayTELELocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

@interface AYStickerButton : UIButton
@property (nonatomic, weak) UITextView *textView;
@end
@implementation AYStickerButton
@end

static const void *kStickerButtonKey = &kStickerButtonKey;
static NSString *SKLoc(NSString *key) { return [ayTELELocalization localizedStringForKey:key]; }

static long long stickerRandomLong(void) {
	return ((long long)arc4random() << 32) | (long long)arc4random();
}

// Redraw to an upright image so Vision and the PNG don't inherit a rotated orientation.
static UIImage *normalizedImage(UIImage *image) {
	if (image.imageOrientation == UIImageOrientationUp) return image;
	UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
	fmt.opaque = NO;
	UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:fmt];
	return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
		[image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
	}];
}

// Scales a cut-out so its longest side is at most 512 px (Telegram's sticker size).
static UIImage *fitTo512(UIImage *image) {
	CGFloat maxSide = MAX(image.size.width, image.size.height);
	if (maxSide <= 512 || maxSide <= 0) return image;
	CGFloat scale = 512.0 / maxSide;
	CGSize size = CGSizeMake(round(image.size.width * scale), round(image.size.height * scale));
	UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
	fmt.opaque = NO;
	UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
	return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
		[image drawInRect:CGRectMake(0, 0, size.width, size.height)];
	}];
}

// Runs Vision on a background queue and returns the cut-out subject (transparent PNG) or nil.
static void cutoutSubject(UIImage *image, void (^completion)(UIImage *cut)) {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		UIImage *up = normalizedImage(image);
		CGImageRef cg = up.CGImage;
		if (!cg) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); }); return; }
		UIImage *result = nil;
		@try {
			if (@available(iOS 17.0, *)) {
				VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
				// Resolve the class dynamically: the symbol isn't in the 16.5 SDK, so a direct
				// reference would fail to link even though the guard keeps it off older systems.
				VNGenerateForegroundInstanceMaskRequest *req = [[NSClassFromString(@"VNGenerateForegroundInstanceMaskRequest") alloc] init];
				NSError *error = nil;
				if ([handler performRequests:@[req] error:&error]) {
					VNInstanceMaskObservation *obs = req.results.firstObject;
					if (obs) {
						CVPixelBufferRef out = [obs generateMaskedImageOfInstances:obs.allInstances fromRequestHandler:handler croppedToInstancesExtent:YES error:&error];
						if (out) {
							CIImage *ci = [CIImage imageWithCVPixelBuffer:out];
							CIContext *ctx = [CIContext contextWithOptions:nil];
							CGImageRef outCG = [ctx createCGImage:ci fromRect:ci.extent];
							if (outCG) {
								result = fitTo512([UIImage imageWithCGImage:outCG]);
								CGImageRelease(outCG);
							}
							CVPixelBufferRelease(out);
						}
					}
				}
			}
		} @catch (NSException *e) { result = nil; }
		dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
	});
}

@interface AYStickerSender : NSObject
@property (nonatomic, strong) NSData *png;
@property (nonatomic) int width;
@property (nonatomic) int height;
@end
@implementation AYStickerSender

- (void)uploadPart:(int)index ofTotal:(int)parts fileId:(long long)fileId partSize:(NSUInteger)partSize {
	if (index >= parts) {
		NSData *payload = [AYDirectSend sendImageDocumentWithFileId:fileId parts:parts fileName:@"sticker.png" mime:@"image/png" width:self.width height:self.height randomId:stickerRandomLong() peer:AYCurrentPeerOrSelf()];
		BOOL ok = AYIssueRequest(payload, (int)0x0330e77f, ^(id result, MTRpcError *error) {
			dispatch_async(dispatch_get_main_queue(), ^{
				AYPresentToast(SKLoc(error ? @"STICKER_FAILED" : @"STICKER_SENT"));
			});
		});
		if (!ok) AYPresentToast(SKLoc(@"STICKER_FAILED"));
		return;
	}
	NSUInteger offset = (NSUInteger)index * partSize;
	NSUInteger len = MIN(partSize, self.png.length - offset);
	NSData *chunk = [self.png subdataWithRange:NSMakeRange(offset, len)];
	NSData *payload = [AYDirectSend saveFilePartWithFileId:fileId part:index chunk:chunk];
	BOOL ok = AYIssueRequest(payload, (int)0xb304a621, ^(id result, MTRpcError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (error) { AYPresentToast(SKLoc(@"STICKER_FAILED")); return; }
			[self uploadPart:index + 1 ofTotal:parts fileId:fileId partSize:partSize];
		});
	});
	if (!ok) AYPresentToast(SKLoc(@"STICKER_FAILED"));
}

- (void)send {
	long long fileId = stickerRandomLong();
	NSUInteger partSize = 512 * 1024;
	int parts = (int)((self.png.length + partSize - 1) / partSize);
	[self uploadPart:0 ofTotal:parts fileId:fileId partSize:partSize];
}

@end

@interface AYStickerPicker : NSObject <PHPickerViewControllerDelegate>
@end
@implementation AYStickerPicker

+ (instancetype)shared {
	static AYStickerPicker *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [AYStickerPicker new]; });
	return shared;
}

+ (void)tapped:(AYStickerButton *)sender {
	UIViewController *controller = nil;
	for (UIResponder *r = sender.nextResponder; r; r = r.nextResponder) {
		if ([r isKindOfClass:[UIViewController class]]) { controller = (UIViewController *)r; break; }
	}
	if (!controller) return;
	PHPickerConfiguration *config = [PHPickerConfiguration new];
	config.filter = [PHPickerFilter imagesFilter];
	config.selectionLimit = 1;
	PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
	picker.delegate = [self shared];
	[controller presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
	[picker dismissViewControllerAnimated:YES completion:nil];
	NSItemProvider *provider = results.firstObject.itemProvider;
	if (![provider canLoadObjectOfClass:[UIImage class]]) return;
	AYPresentToast(SKLoc(@"STICKER_WORKING"));
	[provider loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *image, NSError *error) {
		if (![image isKindOfClass:[UIImage class]]) {
			dispatch_async(dispatch_get_main_queue(), ^{ AYPresentToast(SKLoc(@"STICKER_FAILED")); });
			return;
		}
		cutoutSubject(image, ^(UIImage *cut) {
			if (!cut) { AYPresentToast(SKLoc(@"STICKER_NO_SUBJECT")); return; }
			NSData *png = UIImagePNGRepresentation(cut);
			if (png.length == 0) { AYPresentToast(SKLoc(@"STICKER_FAILED")); return; }
			AYStickerSender *sender = [AYStickerSender new];
			sender.png = png;
			sender.width = (int)(cut.size.width * cut.scale);
			sender.height = (int)(cut.size.height * cut.scale);
			AYPresentToast(SKLoc(@"STICKER_SENDING"));
			[sender send];
		});
	}];
}

@end

void AYUpdateStickerButton(UITextView *textView, Class chatControllerClass) {
	AYStickerButton *button = objc_getAssociatedObject(textView, kStickerButtonKey);
	BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kStickerFromImage];
	UIViewController *controller = nil;
	if (enabled && textView.window) {
		for (UIResponder *r = textView.nextResponder; r; r = r.nextResponder) {
			if ([r isKindOfClass:[UIViewController class]]) { controller = (UIViewController *)r; break; }
		}
	}
	if (controller && chatControllerClass && ![controller isKindOfClass:chatControllerClass]) controller = nil;
	if (!controller || textView.hidden || textView.bounds.size.width < 40) {
		button.hidden = YES;
		return;
	}
	if (!button) {
		button = (AYStickerButton *)[AYStickerButton buttonWithType:UIButtonTypeCustom];
		button.textView = textView;
		button.tintColor = [UIColor whiteColor];
		button.bounds = CGRectMake(0, 0, 34, 34);
		button.layer.cornerRadius = 17;
		button.layer.zPosition = 1000;
		button.backgroundColor = [UIColor colorWithRed:0.58 green:0.35 blue:0.92 alpha:0.92];
		UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
		[button setImage:[UIImage systemImageNamed:@"scissors" withConfiguration:config] forState:UIControlStateNormal];
		button.accessibilityLabel = SKLoc(@"STICKER_TITLE");
		[button addTarget:[AYStickerPicker class] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
		objc_setAssociatedObject(textView, kStickerButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	UIView *host = controller.view;
	if (button.superview != host) [host addSubview:button];
	CGRect field = [textView convertRect:textView.bounds toView:host];
	CGFloat size = button.bounds.size.width;
	CGFloat x = MIN(CGRectGetMaxX(field) - size / 2, host.bounds.size.width - size / 2 - 8);
	// Stack to the left of whatever other input buttons are enabled.
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	if ([d boolForKey:kSpeechToText]) x -= size + 10;
	if ([d boolForKey:kVoiceFromFile]) x -= size + 10;
	if ([d boolForKey:kTranslateOutgoing]) x -= size + 10;
	CGFloat y = CGRectGetMinY(field) - size / 2 - 14;
	button.center = CGPointMake(x, y);
	button.hidden = NO;
	[host bringSubviewToFront:button];
}
