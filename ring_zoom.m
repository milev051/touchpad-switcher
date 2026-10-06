// Pick transition and its sharp picture. See ring_zoom.h.

#import "ring_zoom.h"
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>

static const CFTimeInterval kGrowDuration = 0.26;
static const CFTimeInterval kFadeDuration = 0.14;
// The longest wait for a slow app or tab before the picture fades anyway.
static const CFTimeInterval kWaitForWindow = 1.2;
// Chrome needs a moment to paint a tab it just switched to.
static const int64_t kPaintAfterContentMs = 90;
static const CGFloat kStartRadius = 8.0, kEndRadius = 10.0;
// Room around the window for its shadow.
static const CGFloat kShadowMargin = 60.0;
static const size_t kLiveCaptureMaxPixelWidth = 3200;
static const int64_t kPrepareDelayMs = 120;

#pragma mark - Images

CGImageRef RingZoomCopyDecodedImage(CGImageRef source) {
    if (!source) return NULL;
    size_t width = CGImageGetWidth(source), height = CGImageGetHeight(source);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);
    CGImageRef decoded = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return decoded;
}

CGImageRef RingZoomCopyDecodedImageFromData(NSData *data) {
    if (!data.length) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    CGImageRef decoded = RingZoomCopyDecodedImage(image);
    if (image) CGImageRelease(image);
    return decoded;
}

static char kLargeImageKey;

void RingZoomAttachLargeImage(NSData *thumbnail, NSData *largeJPEG) {
    if (thumbnail && largeJPEG) objc_setAssociatedObject(thumbnail, &kLargeImageKey, largeJPEG, OBJC_ASSOCIATION_RETAIN);
}

NSData *RingZoomLargeImageForThumbnail(NSData *thumbnail) {
    return thumbnail ? objc_getAssociatedObject(thumbnail, &kLargeImageKey) : nil;
}

#pragma mark - Windows

NSRect RingZoomVisibleWindowFrame(CGWindowID windowID) {
    if (windowID == kCGNullWindowID || !NSScreen.screens.count) return NSZeroRect;
    CFArrayRef ids = CFArrayCreate(NULL, (const void **)(uintptr_t[]){windowID}, 1, NULL);
    NSArray *info = CFBridgingRelease(CGWindowListCreateDescriptionFromArray(ids));
    CFRelease(ids);
    NSDictionary *window = info.firstObject;
    if (![window[(id)kCGWindowIsOnscreen] boolValue]) return NSZeroRect;
    CGRect bounds = CGRectZero;
    if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds))
        return NSZeroRect;
    CGFloat primaryHeight = NSHeight(NSScreen.screens.firstObject.frame);
    return NSMakeRect(bounds.origin.x, primaryHeight - CGRectGetMaxY(bounds), bounds.size.width, bounds.size.height);
}

// Whether the window is the frontmost ordinary window on screen, not counting
// this app's own panels.
static BOOL windowIsFrontmost(CGWindowID windowID) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    pid_t ownPID = NSProcessInfo.processInfo.processIdentifier;
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowLayer] intValue] != 0) continue;
        if ([window[(id)kCGWindowOwnerPID] intValue] == ownPID) continue;
        return [window[(id)kCGWindowNumber] unsignedIntValue] == windowID;
    }
    return NO;
}

BOOL RingZoomAllowed(BOOL settingOn) {
    return settingOn && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

#pragma mark - Zoom

@interface RingZoomPanel : NSPanel
@end
@implementation RingZoomPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static RingZoomPanel *g_panel;
static CALayer *g_container;   // fades as a whole
static CALayer *g_shadow;
static CALayer *g_picture;
static uint64_t g_run;

static void createPanel(NSRect frame) {
    g_panel = [[RingZoomPanel alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
          backing:NSBackingStoreBuffered defer:NO];
    g_panel.opaque = NO;
    g_panel.backgroundColor = NSColor.clearColor;
    g_panel.hasShadow = NO;
    // Same level as the menu, above full-screen windows.
    g_panel.level = NSPopUpMenuWindowLevel + 1;
    g_panel.hidesOnDeactivate = NO;
    g_panel.animationBehavior = NSWindowAnimationBehaviorNone;
    g_panel.ignoresMouseEvents = YES;
    g_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary |
                                 NSWindowCollectionBehaviorStationary;
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
    content.wantsLayer = YES;
    g_panel.contentView = content;
    g_container = [CALayer layer];
    [content.layer addSublayer:g_container];
    g_shadow = [CALayer layer];
    g_shadow.shadowColor = NSColor.blackColor.CGColor;
    g_shadow.shadowOpacity = 0.38;
    g_shadow.shadowRadius = 22.0;
    g_shadow.shadowOffset = CGSizeMake(0, -10);
    [g_container addSublayer:g_shadow];
    g_picture = [CALayer layer];
    g_picture.contentsGravity = kCAGravityResize;
    g_picture.masksToBounds = YES;
    [g_container addSublayer:g_picture];
}

static void fadeOut(uint64_t run) {
    if (run != g_run) return;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1.0;
    fade.toValue = @0.0;
    fade.duration = kFadeDuration;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g_container.opacity = 0.0;
    [CATransaction commit];
    [g_container addAnimation:fade forKey:@"fade"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kFadeDuration + 0.02) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (run != g_run) return;
        [g_panel orderOut:nil];
        [g_container removeAllAnimations];
        g_picture.contents = nil;
    });
}

// The picture stays until the picked window is really in front, so the
// window that was there before never shows through it.
static void fadeWhenWindowIsShown(uint64_t run, CGWindowID windowID, BOOL (^contentShown)(void),
                                  CFTimeInterval deadline) {
    if (run != g_run) return;
    if (!windowIsFrontmost(windowID) && CACurrentMediaTime() < deadline) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            fadeWhenWindowIsShown(run, windowID, contentShown, deadline);
        });
        return;
    }
    if (!contentShown) { fadeOut(run); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL shown = NO;
        while (!shown && run == g_run && CACurrentMediaTime() < deadline) {
            shown = contentShown();
            if (!shown) usleep(20000);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (shown ? kPaintAfterContentMs : 0) * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ fadeOut(run); });
    });
}

static CGPathRef copyShadowPath(CGSize size, CGFloat radius) {
    return CGPathCreateWithRoundedRect(CGRectMake(0, 0, size.width, size.height), radius, radius, NULL);
}

BOOL RingZoomStart(CGImageRef image, NSRect from, NSRect to, CGWindowID windowID,
                   BOOL (^contentShown)(void)) {
    if (!image || NSIsEmptyRect(from) || NSIsEmptyRect(to)) return NO;
    NSRect frame = NSInsetRect(NSUnionRect(from, to), -kShadowMargin, -kShadowMargin);
    if (!g_panel) createPanel(frame);
    uint64_t run = ++g_run;
    [g_panel setFrame:frame display:NO];
    CGRect start = NSRectToCGRect(NSOffsetRect(from, -NSMinX(frame), -NSMinY(frame)));
    CGRect end = NSRectToCGRect(NSOffsetRect(to, -NSMinX(frame), -NSMinY(frame)));
    [g_container removeAllAnimations];
    [g_shadow removeAllAnimations];
    [g_picture removeAllAnimations];
    CGPathRef startPath = copyShadowPath(start.size, kStartRadius);
    CGPathRef endPath = copyShadowPath(end.size, kEndRadius);

    // Final state first; the animations below run from the card to it.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g_container.frame = CGRectMake(0, 0, NSWidth(frame), NSHeight(frame));
    g_container.opacity = 1.0;
    g_picture.contents = (__bridge id)image;
    g_picture.contentsScale = g_panel.backingScaleFactor ?: 2.0;
    g_picture.frame = end;
    g_picture.cornerRadius = kEndRadius;
    g_shadow.frame = end;
    g_shadow.shadowPath = endPath;
    [CATransaction commit];
    [g_panel orderFrontRegardless];

    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.8 :0.25 :1.0];
    CABasicAnimation *position = [CABasicAnimation animationWithKeyPath:@"position"];
    position.fromValue = [NSValue valueWithPoint:NSMakePoint(CGRectGetMidX(start), CGRectGetMidY(start))];
    CABasicAnimation *size = [CABasicAnimation animationWithKeyPath:@"bounds.size"];
    size.fromValue = [NSValue valueWithSize:NSSizeFromCGSize(start.size)];
    CABasicAnimation *corner = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
    corner.fromValue = @(kStartRadius);
    CABasicAnimation *shadowPath = [CABasicAnimation animationWithKeyPath:@"shadowPath"];
    shadowPath.fromValue = (__bridge id)startPath;
    CAAnimationGroup *grow = [CAAnimationGroup animation];
    grow.animations = @[position, size, corner];
    grow.duration = kGrowDuration;
    grow.timingFunction = ease;
    [g_picture addAnimation:grow forKey:@"grow"];
    CAAnimationGroup *growShadow = [CAAnimationGroup animation];
    growShadow.animations = @[[position copy], [size copy], shadowPath];
    growShadow.duration = kGrowDuration;
    growShadow.timingFunction = ease;
    [g_shadow addAnimation:growShadow forKey:@"grow"];
    CGPathRelease(startPath);
    CGPathRelease(endPath);
    // Start drawing now: the menu closes and the app activates right after
    // this on the main thread, which would otherwise hold the first frame.
    [CATransaction flush];

    CFTimeInterval deadline = CACurrentMediaTime() + kGrowDuration + kWaitForWindow;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGrowDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fadeWhenWindowIsShown(run, windowID, contentShown, deadline);
    });
    return YES;
}

#pragma mark - Sharp picture

static CGImageRef g_preparedImage;
static id g_preparedKey;
static BOOL g_preparedIsLive;
static uint64_t g_prepareRequest;

// Takes ownership of the image.
static void storePicture(uint64_t request, id key, CGImageRef image, BOOL live) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // A live picture is newer than the stored copy and is not replaced by it.
        if (request != g_prepareRequest || (!live && g_preparedIsLive && g_preparedKey == key)) {
            CGImageRelease(image);
            return;
        }
        if (g_preparedImage) CGImageRelease(g_preparedImage);
        g_preparedImage = image;
        g_preparedKey = key;
        g_preparedIsLive = live;
    });
}

static void captureLive(uint64_t request, id key, CGWindowID windowID, CGFloat scale,
                        BOOL (^stillValid)(void)) {
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
                                                completionHandler:^(SCShareableContent *content, NSError *error) {
        SCWindow *window = nil;
        for (SCWindow *candidate in content.windows) {
            if (candidate.windowID == windowID) { window = candidate; break; }
        }
        if (!window || window.frame.size.width < 1 || window.frame.size.height < 1) return;
        SCStreamConfiguration *configuration = [SCStreamConfiguration new];
        size_t width = (size_t)MIN(lround(window.frame.size.width * scale), (long)kLiveCaptureMaxPixelWidth);
        configuration.width = width;
        configuration.height = (size_t)lround(width * window.frame.size.height / window.frame.size.width);
        configuration.showsCursor = NO;
        configuration.ignoreShadowsSingleWindow = YES;
        configuration.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        [SCScreenshotManager captureImageWithFilter:[[SCContentFilter alloc] initWithDesktopIndependentWindow:window]
                                      configuration:configuration
                                  completionHandler:^(CGImageRef image, NSError *captureError) {
            if (!image || (stillValid && !stillValid())) return;
            storePicture(request, key, CGImageRetain(image), YES);
        }];
    }];
}

void RingZoomPreparePicture(id key, NSData *storedJPEG, CGWindowID windowID, CGFloat scale,
                            BOOL (^liveStillValid)(void)) {
    uint64_t request = ++g_prepareRequest;
    if (!key || key == g_preparedKey) return;
    BOOL live = windowID != kCGNullWindowID;
    if (!storedJPEG && !live) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kPrepareDelayMs * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (request != g_prepareRequest) return;
        if (storedJPEG) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                CGImageRef image = RingZoomCopyDecodedImageFromData(storedJPEG);
                if (image) storePicture(request, key, image, NO);
            });
        }
        if (live && CGPreflightScreenCaptureAccess()) captureLive(request, key, windowID, scale, liveStillValid);
    });
}

void RingZoomCancelPicture(void) {
    g_prepareRequest++;
}

CGImageRef RingZoomCopyPicture(id key) {
    return key && key == g_preparedKey && g_preparedImage ? CGImageRetain(g_preparedImage) : NULL;
}

void RingZoomForgetPicture(void) {
    g_prepareRequest++;
    if (g_preparedImage) CGImageRelease(g_preparedImage);
    g_preparedImage = NULL;
    g_preparedKey = nil;
    g_preparedIsLive = NO;
}
