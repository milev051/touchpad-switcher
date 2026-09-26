// Experimental three-finger radial window switcher.
// A deliberate movement selects a window direction; lifting all three fingers activates it.

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <math.h>
#include <float.h>
#include <os/lock.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/file.h>
#include <libproc.h>
#include <pthread.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef enum {
    MTTouchStateNotTracking = 0,
    MTTouchStateStartInRange = 1,
    MTTouchStateHoverInRange = 2,
    MTTouchStateMakeTouch = 3,
    MTTouchStateTouching = 4,
    MTTouchStateBreakTouch = 5,
    MTTouchStateLingerInRange = 6,
    MTTouchStateOutOfRange = 7
} MTTouchState;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    MTTouchState state;
    int32_t fingerID;
    int32_t handID;
    MTVector normalizedVector;
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;
    int32_t field14;
    int32_t field15;
    float zDensity;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, MTTouch *, int, double, int);
extern CFMutableArrayRef MTDeviceCreateList(void);
extern void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
extern void MTDeviceStart(MTDeviceRef, int);
extern void MTDeviceStop(MTDeviceRef);
extern void MTUnregisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);

@interface RingEntry : NSObject
@property(nonatomic, strong) NSRunningApplication *application;
@property(nonatomic, copy) NSString *windowTitle;
@property(nonatomic, copy) NSString *tabTitle;
@property(nonatomic, copy) NSString *tabAXTitle;
@property(nonatomic, copy) NSString *tabURL;
@property(nonatomic, copy) NSString *folderPath;
@property(nonatomic) BOOL isTab;
@property(nonatomic) BOOL isSelectedTab;
@property(nonatomic) NSUInteger tabIndex;
@property(nonatomic, copy) NSString *chromeWindowID;
@property(nonatomic, copy) NSString *chromeTabID;
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic, strong) NSData *thumbnailData;
@property(nonatomic, strong) NSImage *thumbnail;
@property(nonatomic, strong) id accessibilityWindowObject;
@property(nonatomic, strong) id accessibilityTabObject;
@property(nonatomic) CGWindowID windowID;
@property(nonatomic) CGRect windowBounds;
@end
@implementation RingEntry
@end

static NSString *chromeDisplayTitle(RingEntry *entry);
static NSString *chromeHostFromEntry(RingEntry *entry);
static NSString *youtubeVideoIDFromURL(NSString *urlString);
static NSString *cardLabelText(RingEntry *entry);
static void drawCardLabel(NSString *text, NSRect cardRect, BOOL truncateMiddle);
static NSImage *resolvedThumbnail(RingEntry *entry);
static void applyThumbnailDataToEntry(RingEntry *entry, NSData *data);
static void releaseDecodedThumbnails(void);
static NSString *tabThumbnailKey(RingEntry *entry);
static BOOL ensureChromeAutomation(BOOL askUser);
static void schedulePendingThumbnailCapture(NSArray<RingEntry *> *entries);
static void scheduleChromeBackgroundPrefetch(NSArray<RingEntry *> *entries);
static void scheduleChromeTabArtwork(NSArray<RingEntry *> *entries);

@interface RingView : NSView
@property(nonatomic, copy) NSArray<RingEntry *> *entries;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic) NSPoint anchorPoint;
@property(nonatomic) CGFloat ringRadius;
@end

@implementation RingView (InputShield)
- (void)scrollWheel:(NSEvent *)event { (void)event; }
- (void)mouseDown:(NSEvent *)event { (void)event; }
- (void)mouseUp:(NSEvent *)event { (void)event; }
- (void)mouseDragged:(NSEvent *)event { (void)event; }
- (void)rightMouseDown:(NSEvent *)event { (void)event; }
- (void)rightMouseUp:(NSEvent *)event { (void)event; }
- (void)rightMouseDragged:(NSEvent *)event { (void)event; }
- (void)otherMouseDown:(NSEvent *)event { (void)event; }
- (void)otherMouseUp:(NSEvent *)event { (void)event; }
- (void)otherMouseDragged:(NSEvent *)event { (void)event; }
@end

static void ringEllipseRadii(NSUInteger count, CGFloat baseRadius, CGFloat *outRadiusX, CGFloat *outRadiusY) {
    CGFloat scaleX = 1.0;
    CGFloat scaleY = 1.0;
    if (count == 6) {
        scaleX = 1.15;
        scaleY = 0.72;
    } else if (count == 5) {
        scaleX = 1.12;
        scaleY = 0.72;
    } else if (count >= 9) {
        scaleX = 1.35;
        scaleY = 0.90;
    } else if (count >= 7) {
        scaleX = 1.06;
        scaleY = 0.82;
    } else if (count >= 4) {
        scaleX = 1.08;
        scaleY = 0.78;
    }
    if (outRadiusX) *outRadiusX = baseRadius * scaleX;
    if (outRadiusY) *outRadiusY = baseRadius * scaleY;
}

static CGFloat rawItemAngle(NSInteger i, NSUInteger count) {
    if (count == 5) {
        static const CGFloat angles5[5] = {
            (CGFloat)(M_PI_2),                   // 0: Top center
            (CGFloat)(24.0 * M_PI / 180.0),       // 1: Upper-right
            (CGFloat)(-57.0 * M_PI / 180.0),      // 2: Lower-right (harmoniously spaced, no overlap)
            (CGFloat)(-123.0 * M_PI / 180.0),     // 3: Lower-left (harmoniously spaced, no overlap)
            (CGFloat)(156.0 * M_PI / 180.0)       // 4: Upper-left
        };
        NSInteger idx = ((i % 5) + 5) % 5;
        return angles5[idx];
    }
    return (CGFloat)M_PI_2 - (CGFloat)(2.0 * M_PI * i / count);
}

static CGFloat safeCardWidthForRing(NSUInteger count, CGFloat radiusX, CGFloat radiusY, CGFloat maxAvailableWidth) {
    if (count <= 1) return MIN(600, maxAvailableWidth * 0.60);
    if (count == 2) return MIN(540, maxAvailableWidth * 0.42);

    const CGFloat minGap = 20.0;
    const CGFloat selectedScale = 1.025;
    CGFloat upperBound = (count >= 6 && count <= 10) ? 380.0 : 540.0;

    // Find the widest card that fits every pair around the ellipse while keeping
    // at least 20 px between preview bounds. Checking all pairs also protects
    // against non-adjacent cards meeting on compact rings.
    CGFloat low = 20.0;
    CGFloat high = MIN(upperBound, maxAvailableWidth);
    for (int pass = 0; pass < 24; pass++) {
        CGFloat candidate = (low + high) * 0.5;
        CGFloat previewWidth = candidate * 0.94 * selectedScale;
        CGFloat previewHeight = previewWidth * 0.60;
        BOOL fits = YES;

        for (NSUInteger i = 0; i < count && fits; i++) {
            CGFloat a1 = rawItemAngle(i, count);
            CGFloat x1 = cos(a1) * radiusX, y1 = sin(a1) * radiusY;
            for (NSUInteger j = i + 1; j < count; j++) {
                CGFloat a2 = rawItemAngle(j, count);
                CGFloat dx = fabs(cos(a2) * radiusX - x1);
                CGFloat dy = fabs(sin(a2) * radiusY - y1);
                if (dx < previewWidth + minGap && dy < previewHeight + minGap) {
                    fits = NO;
                    break;
                }
            }
        }

        if (fits) low = candidate;
        else high = candidate;
    }

    return low;
}

static CGFloat visualItemAngle(NSInteger i, NSUInteger count) {
    if (count == 0) return (CGFloat)M_PI_2;
    CGFloat radiusX = 1.0, radiusY = 1.0;
    ringEllipseRadii(count, 100.0, &radiusX, &radiusY);
    CGFloat rawAngle = rawItemAngle(i, count);
    return (CGFloat)atan2(sin(rawAngle) * radiusY, cos(rawAngle) * radiusX);
}

@implementation RingView
- (BOOL)isFlipped { return NO; }

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    return self;
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect bounds = self.bounds;
    [[NSColor colorWithCalibratedWhite:0.02 alpha:0.27] setFill];
    NSRectFill(bounds);
    NSPoint center = self.anchorPoint;
    NSUInteger count = self.entries.count;
    if (count == 0) {
        NSDictionary *emptyStyle = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        [@"No open windows" drawInRect:NSMakeRect(center.x - 70, center.y - 30, 140, 16) withAttributes:emptyStyle];
        return;
    }

    CGFloat radius = self.ringRadius;
    CGFloat radiusX = radius, radiusY = radius;
    ringEllipseRadii(count, radius, &radiusX, &radiusY);
    CGFloat cardWidth = safeCardWidthForRing(count, radiusX, radiusY, NSWidth(bounds));
    CGFloat previewWidth = cardWidth * 0.94;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat rawAngle = rawItemAngle(i, count);
        NSPoint itemCenter = NSMakePoint(center.x + cos(rawAngle) * radiusX,
                                         center.y + sin(rawAngle) * radiusY);
        BOOL selected = ((NSInteger)i == self.selectedIndex);
        RingEntry *entry = self.entries[i];
        NSImage *thumbnail = resolvedThumbnail(entry);
        if (thumbnail) {
            CGFloat itemPreviewWidth = previewWidth;
            CGFloat previewHeight = itemPreviewWidth * 0.60;
            CGFloat previewY = itemCenter.y - previewHeight / 2;
            NSRect previewRect = NSMakeRect(itemCenter.x - itemPreviewWidth / 2,
                                            previewY, itemPreviewWidth, previewHeight);

            // 1. Drop shadow behind the card
            [NSGraphicsContext saveGraphicsState];
            NSShadow *shadow = [NSShadow new];
            shadow.shadowBlurRadius = selected ? 18.0 : 14.0;
            shadow.shadowColor = selected ? [NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:0.40]
                                          : [NSColor colorWithCalibratedWhite:0.0 alpha:0.45];
            shadow.shadowOffset = NSMakeSize(0, -3);
            [shadow set];
            NSBezierPath *backPath = [NSBezierPath bezierPathWithRoundedRect:previewRect xRadius:8.0 yRadius:8.0];
            [[NSColor colorWithCalibratedWhite:0.12 alpha:1.0] setFill];
            [backPath fill];
            [NSGraphicsContext restoreGraphicsState];

            // 2. Clip thumbnail with rounded corners: cornerRadius = 8.0
            [NSGraphicsContext saveGraphicsState];
            NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:previewRect xRadius:8.0 yRadius:8.0];
            [clipPath addClip];
            [thumbnail drawInRect:previewRect
                         fromRect:NSZeroRect
                        operation:NSCompositingOperationSourceOver
                         fraction:1.0];
            [NSGraphicsContext restoreGraphicsState];

            BOOL isFinderEntry = [entry.application.bundleIdentifier isEqualToString:@"com.apple.finder"];
            drawCardLabel(cardLabelText(entry), previewRect, isFinderEntry && entry.folderPath.length > 0);

            // 4. Draw clean border around the card
            [NSGraphicsContext saveGraphicsState];
            NSBezierPath *borderPath = [NSBezierPath bezierPathWithRoundedRect:previewRect xRadius:8.0 yRadius:8.0];
            if (selected) {
                NSShadow *glow = [NSShadow new];
                glow.shadowBlurRadius = 8.0;
                glow.shadowColor = [NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:0.75];
                glow.shadowOffset = NSMakeSize(0, 0);
                [glow set];
                borderPath.lineWidth = 2.5;
                [[NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:0.95] setStroke];
                [borderPath stroke];
            } else {
                borderPath.lineWidth = 1.5;
                [[NSColor colorWithCalibratedWhite:1.0 alpha:0.22] setStroke];
                [borderPath stroke];
            }
            [NSGraphicsContext restoreGraphicsState];
        } else if ([entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"]) {
            // Chrome tabs share one CG window, so inactive tabs often have no
            // screenshot. Keep the same card size and show title + site instead
            // of a bare Chrome icon.
            CGFloat cardHeight = previewWidth * 0.60;
            NSRect cardRect = NSMakeRect(itemCenter.x - previewWidth / 2,
                                         itemCenter.y - cardHeight / 2,
                                         previewWidth, cardHeight);
            NSString *host = chromeHostFromEntry(entry);
            CGFloat hue = (CGFloat)(host.hash % 360) / 360.0;
            NSColor *topColor = [NSColor colorWithCalibratedHue:hue saturation:0.48 brightness:0.27 alpha:1.0];
            NSColor *bottomColor = [NSColor colorWithCalibratedHue:hue saturation:0.37 brightness:0.13 alpha:1.0];
            NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:cardRect xRadius:8 yRadius:8];
            [NSGraphicsContext saveGraphicsState];
            NSShadow *shadow = [NSShadow new];
            shadow.shadowBlurRadius = selected ? 18.0 : 14.0;
            shadow.shadowColor = [NSColor colorWithCalibratedWhite:0 alpha:0.45];
            shadow.shadowOffset = NSMakeSize(0, -3);
            [shadow set];
            [[NSColor colorWithCalibratedWhite:0.12 alpha:1.0] setFill];
            [cardPath fill];
            [NSGraphicsContext restoreGraphicsState];
            NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:topColor endingColor:bottomColor];
            [gradient drawInBezierPath:cardPath angle:90];

            CGFloat inset = MIN(20.0, previewWidth * 0.07);
            CGFloat iconSize = MIN(38.0, cardHeight * 0.25);
            [entry.icon drawInRect:NSMakeRect(NSMinX(cardRect) + inset,
                                              NSMaxY(cardRect) - inset - iconSize,
                                              iconSize, iconSize)];
            NSMutableParagraphStyle *titleStyle = [NSMutableParagraphStyle new];
            titleStyle.lineBreakMode = NSLineBreakByTruncatingTail;
            NSDictionary *titleAttributes = @{
                NSFontAttributeName: [NSFont systemFontOfSize:MIN(18.0, previewWidth * 0.063) weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: NSColor.whiteColor,
                NSParagraphStyleAttributeName: titleStyle
            };
            NSString *title = chromeDisplayTitle(entry);
            [title drawInRect:NSMakeRect(NSMinX(cardRect) + inset,
                                         NSMinY(cardRect) + cardHeight * 0.28,
                                         previewWidth - inset * 2,
                                         cardHeight * 0.35)
                   withAttributes:titleAttributes];
            NSDictionary *hostAttributes = @{
                NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.87 alpha:1.0],
                NSParagraphStyleAttributeName: titleStyle
            };
            [host drawInRect:NSMakeRect(NSMinX(cardRect) + inset,
                                        NSMinY(cardRect) + inset - 1,
                                        previewWidth - inset * 2,
                                        18)
                  withAttributes:hostAttributes];
            cardPath.lineWidth = selected ? 2.5 : 1.5;
            NSColor *borderColor = selected
                ? [NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:0.95]
                : [NSColor colorWithCalibratedWhite:1.0 alpha:0.22];
            [borderColor setStroke];
            [cardPath stroke];
        } else {
            CGFloat iconSize = MIN(140, MAX(54, cardWidth * 0.42));
            NSRect iconRect = NSMakeRect(itemCenter.x - iconSize / 2,
                                         itemCenter.y - iconSize / 2, iconSize, iconSize);
            NSRect iconCardRect = NSInsetRect(iconRect, -8.0, -8.0);

            [NSGraphicsContext saveGraphicsState];
            NSShadow *iconShadow = [NSShadow new];
            iconShadow.shadowBlurRadius = selected ? 18.0 : 14.0;
            iconShadow.shadowColor = selected ? [NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:0.40]
                                              : [NSColor colorWithCalibratedWhite:0.0 alpha:0.45];
            iconShadow.shadowOffset = NSMakeSize(0, -3);
            [iconShadow set];
            NSBezierPath *iconBackPath = [NSBezierPath bezierPathWithRoundedRect:iconCardRect xRadius:8.0 yRadius:8.0];
            [[NSColor colorWithCalibratedWhite:0.12 alpha:1.0] setFill];
            [iconBackPath fill];
            [NSGraphicsContext restoreGraphicsState];

            [entry.icon drawInRect:iconRect];
            BOOL isFinderIcon = [entry.application.bundleIdentifier isEqualToString:@"com.apple.finder"];
            drawCardLabel(cardLabelText(entry), iconCardRect, isFinderIcon && entry.folderPath.length > 0);

            [NSGraphicsContext saveGraphicsState];
            NSBezierPath *iconBorderPath = [NSBezierPath bezierPathWithRoundedRect:iconCardRect xRadius:8.0 yRadius:8.0];
            if (selected) {
                NSShadow *iconGlow = [NSShadow new];
                iconGlow.shadowBlurRadius = 8.0;
                iconGlow.shadowColor = [NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:0.75];
                iconGlow.shadowOffset = NSMakeSize(0, 0);
                [iconGlow set];
                iconBorderPath.lineWidth = 2.5;
                [[NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:0.95] setStroke];
            } else {
                iconBorderPath.lineWidth = 1.5;
                [[NSColor colorWithCalibratedWhite:1.0 alpha:0.22] setStroke];
            }
            [iconBorderPath stroke];
            [NSGraphicsContext restoreGraphicsState];
        }

    }

}
@end

@interface RingPanel : NSPanel
@end
@implementation RingPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static RingPanel *g_panel;
static RingView *g_ringView;
static NSArray<RingEntry *> *g_windowEntries = @[];
static _Atomic(int) g_windowEntryCount = 0;
static CFMutableArrayRef g_devices = NULL;
static _Atomic(bool) g_gestureActive = false;
static _Atomic(bool) g_ringOverlayVisible = false;
static _Atomic(bool) g_scrollSuppressionActive = false;
static _Atomic(uint64_t) g_scrollSuppressionUntilNanos = 0;
static _Atomic(bool) g_suppressGestureMomentum = false;
static _Atomic(bool) g_gestureEnding = false;
static _Atomic(uint64_t) g_ringShownGeneration = 0;
static double g_previousX = 0.0;
static double g_previousY = 0.0;
static double g_motionAccumX = 0.0;
static double g_motionAccumY = 0.0;
static NSInteger g_selectedIndex = -1;
static _Atomic(uint64_t) g_gestureGeneration = 0;
static CGPoint g_cursorAtGestureStart = {0, 0};
static CFMachPortRef g_scrollEventTap = NULL;
static dispatch_semaphore_t g_scrollTapReady;
static _Atomic(bool) g_scrollTapActive = false;
static NSMutableDictionary<NSNumber *, NSData *> *g_thumbnailCache;
static NSMutableDictionary<NSString *, NSData *> *g_tabThumbnailCache;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_windowLastSeen;
static NSMutableDictionary<NSString *, NSNumber *> *g_tabLastSeen;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_windowPIDMap;
static NSMutableDictionary<NSString *, NSNumber *> *g_tabPIDMap;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_thumbnailFailureUntil;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_thumbnailFailureCount;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_chromeWindowLastCapture;
static NSMutableDictionary<NSNumber *, NSString *> *g_chromeCaptureTabKeys;
static NSMutableSet<NSNumber *> *g_thumbnailRequests;
static NSMutableSet<NSString *> *g_tabThumbnailRequests;
static NSMutableDictionary<NSString *, NSNumber *> *g_tabLastCaptured;
static NSMutableDictionary<NSString *, NSData *> *g_tabArtworkCache;
static NSMutableDictionary<NSString *, NSData *> *g_urlArtworkCache;
static NSMutableDictionary<NSString *, NSString *> *g_tabCachedURL;
static NSMutableDictionary<NSNumber *, NSString *> *g_chromeCaptureURLs;
static NSMutableSet<NSString *> *g_tabArtworkRequests;
static dispatch_queue_t g_tabArtworkQueue;
static NSTimeInterval g_shareableContentRetryAfter = 0;
static NSUInteger g_shareableContentFailureCount = 0;
static dispatch_queue_t g_tabCaptureQueue;
static dispatch_queue_t g_chromePrefetchQueue;
static dispatch_queue_t g_thumbnailPlanningQueue;
static dispatch_queue_t g_windowActivationQueue;
static dispatch_queue_t g_windowScanQueue;
static dispatch_source_t g_scanTimer;
static _Atomic(bool) g_isScanning = false;
static _Atomic(bool) g_chromePrefetchActive = false;
static _Atomic(int) g_activeTouchCount = 0;
static NSTimeInterval g_chromePrefetchRetryAfter = 0;
static NSTimeInterval g_chromePrefetchHoldUntil = 0;
static os_unfair_lock g_selectionLock = OS_UNFAIR_LOCK_INIT;
static NSInteger g_pendingSelection = -1;
static uint64_t g_pendingSelectionGeneration = 0;
static BOOL g_selectionUpdatePending = NO;
static const BOOL g_thumbnailPreviewsEnabled = YES;
static int g_instanceLockFD = -1;

static pid_t lockedInstancePID(int lockFD) {
    char pidText[32] = {0};
    ssize_t length = pread(lockFD, pidText, sizeof(pidText) - 1, 0);
    if (length <= 0) return 0;
    return (pid_t)strtol(pidText, NULL, 10);
}

static BOOL executableIsSwitcher(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    return [[NSString stringWithUTF8String:path].lastPathComponent isEqualToString:@"touchpad_ring_test"];
}

static void terminateOtherSwitcherProcesses(void) {
    pid_t selfPID = getpid();
    int processCount = proc_listallpids(NULL, 0);
    if (processCount <= 0) return;
    size_t capacity = (size_t)processCount + 32;
    pid_t *processIDs = calloc(capacity, sizeof(pid_t));
    if (!processIDs) return;
    int found = proc_listallpids(processIDs, (int)(capacity * sizeof(pid_t)));
    if (found < 0) { free(processIDs); return; }

    NSMutableArray<NSNumber *> *oldPIDs = [NSMutableArray array];
    for (int i = 0; i < found; i++) {
        pid_t pid = processIDs[i];
        if (pid > 0 && pid != selfPID && executableIsSwitcher(pid)) {
            kill(pid, SIGTERM);
            [oldPIDs addObject:@(pid)];
        }
    }
    free(processIDs);

    for (int attempt = 0; attempt < 20 && oldPIDs.count; attempt++) {
        [oldPIDs filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *pidNumber, NSDictionary *bindings) {
            (void)bindings;
            pid_t pid = pidNumber.intValue;
            if (kill(pid, 0) != 0 && errno == ESRCH) return NO;
            return YES;
        }]];
        if (oldPIDs.count) usleep(50000);
    }
    for (NSNumber *pidNumber in oldPIDs) kill(pidNumber.intValue, SIGKILL);
}

static BOOL claimSingleInstance(void) {
    NSString *supportDirectory = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/Touchpad Switcher"];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:supportDirectory
                                 withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        fprintf(stderr, "[instance] Cannot create lock directory: %s\n", directoryError.localizedDescription.UTF8String);
        return NO;
    }
    NSString *lockPath = [supportDirectory stringByAppendingPathComponent:@"instance.lock"];
    g_instanceLockFD = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
    if (g_instanceLockFD < 0) {
        perror("[instance] open lock");
        return NO;
    }

    BOOL locked = NO;
    pid_t previousPID = 0;
    for (int attempt = 0; attempt < 40; attempt++) {
        if (flock(g_instanceLockFD, LOCK_EX | LOCK_NB) == 0) {
            locked = YES;
            break;
        }
        previousPID = lockedInstancePID(g_instanceLockFD);
        if (previousPID > 0 && previousPID != getpid()) {
            if (attempt == 0) kill(previousPID, SIGTERM);
            if (attempt == 20 && kill(previousPID, 0) == 0) kill(previousPID, SIGKILL);
        }
        usleep(50000);
    }
    if (!locked) {
        fprintf(stderr, "[instance] Timed out replacing previous instance %d.\n", previousPID);
        close(g_instanceLockFD);
        g_instanceLockFD = -1;
        return NO;
    }

    char pidText[32];
    int length = snprintf(pidText, sizeof(pidText), "%d\n", getpid());
    ftruncate(g_instanceLockFD, 0);
    pwrite(g_instanceLockFD, pidText, (size_t)length, 0);
    fsync(g_instanceLockFD);
    terminateOtherSwitcherProcesses();
    fprintf(stderr, "[instance] Running as the only Touchpad Switcher instance (pid %d).\n", getpid());
    return YES;
}

static CGEventRef filterScrollDuringRing(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    (void)event;
    (void)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_scrollEventTap) {
            CGEventTapEnable(g_scrollEventTap, true);
            atomic_store(&g_scrollTapActive, CGEventTapIsEnabled(g_scrollEventTap));
        }
        return event;
    }
    BOOL isProtectedInput = type == kCGEventScrollWheel ||
                            type == kCGEventMouseMoved ||
                            type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp ||
                            type == kCGEventLeftMouseDragged ||
                            type == kCGEventRightMouseDown || type == kCGEventRightMouseUp ||
                            type == kCGEventRightMouseDragged ||
                            type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp ||
                            type == kCGEventOtherMouseDragged;
    if (!isProtectedInput) return event;
    if (atomic_load(&g_gestureActive) || atomic_load(&g_ringOverlayVisible)) {
        if (type == kCGEventScrollWheel) atomic_store(&g_suppressGestureMomentum, true);
        return NULL;
    }
    int64_t momentumPhase = type == kCGEventScrollWheel
        ? CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase) : 0;
    if (atomic_load(&g_scrollSuppressionActive)) {
        uint64_t nowNanos = (uint64_t)(NSProcessInfo.processInfo.systemUptime * 1000000000.0);
        uint64_t untilNanos = atomic_load(&g_scrollSuppressionUntilNanos);
        if (nowNanos < untilNanos) {
            if (momentumPhase == kCGMomentumScrollPhaseEnd) atomic_store(&g_suppressGestureMomentum, false);
            return NULL;
        }
        uint64_t expectedUntil = untilNanos;
        if (atomic_compare_exchange_strong(&g_scrollSuppressionUntilNanos, &expectedUntil, 0)) {
            atomic_store(&g_scrollSuppressionActive, false);
            if (atomic_load(&g_scrollSuppressionUntilNanos) > nowNanos) {
                atomic_store(&g_scrollSuppressionActive, true);
                return NULL;
            }
        } else if (expectedUntil > nowNanos) {
            return NULL;
        }
    }
    if (momentumPhase != kCGMomentumScrollPhaseNone && atomic_load(&g_suppressGestureMomentum)) {
        if (momentumPhase == kCGMomentumScrollPhaseEnd) atomic_store(&g_suppressGestureMomentum, false);
        return NULL;
    }
    if (type == kCGEventScrollWheel) atomic_store(&g_suppressGestureMomentum, false);
    return event;
}

static void *runScrollEventTap(void *unused) {
    (void)unused;
    @autoreleasepool {
        CGEventMask protectedInputMask = CGEventMaskBit(kCGEventScrollWheel) |
                                         CGEventMaskBit(kCGEventMouseMoved) |
                                         CGEventMaskBit(kCGEventLeftMouseDown) |
                                         CGEventMaskBit(kCGEventLeftMouseUp) |
                                         CGEventMaskBit(kCGEventLeftMouseDragged) |
                                         CGEventMaskBit(kCGEventRightMouseDown) |
                                         CGEventMaskBit(kCGEventRightMouseUp) |
                                         CGEventMaskBit(kCGEventRightMouseDragged) |
                                         CGEventMaskBit(kCGEventOtherMouseDown) |
                                         CGEventMaskBit(kCGEventOtherMouseUp) |
                                         CGEventMaskBit(kCGEventOtherMouseDragged);
        g_scrollEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                            kCGEventTapOptionDefault, protectedInputMask,
                                            filterScrollDuringRing, NULL);
        if (!g_scrollEventTap) {
            // Keep the existing app-targeted tap as a fallback on systems where
            // session-wide event monitoring is not available to this process.
            g_scrollEventTap = CGEventTapCreate(kCGAnnotatedSessionEventTap, kCGHeadInsertEventTap,
                                                kCGEventTapOptionDefault, protectedInputMask,
                                                filterScrollDuringRing, NULL);
        }

        CFRunLoopSourceRef source = g_scrollEventTap
            ? CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_scrollEventTap, 0) : NULL;
        if (source) {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
            CGEventTapEnable(g_scrollEventTap, true);
            atomic_store(&g_scrollTapActive, CGEventTapIsEnabled(g_scrollEventTap));
            if (g_scrollTapReady) dispatch_semaphore_signal(g_scrollTapReady);
            CFRunLoopRun();
            CFRelease(source);
        } else if (g_scrollTapReady) {
            dispatch_semaphore_signal(g_scrollTapReady);
        }
    }
    return NULL;
}

static BOOL startScrollEventTap(void) {
    g_scrollTapReady = dispatch_semaphore_create(0);
    pthread_t thread;
    if (pthread_create(&thread, NULL, runScrollEventTap, NULL) != 0) return NO;
    pthread_detach(thread);
    dispatch_semaphore_wait(g_scrollTapReady,
                            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return atomic_load(&g_scrollTapActive);
}

static NSPoint appKitPointFromQuartz(CGPoint quartzPoint, NSScreen **screenOut) {
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *displayNumber = screen.deviceDescription[@"NSScreenNumber"];
        if (!displayNumber) continue;
        CGRect cgFrame = CGDisplayBounds(displayNumber.unsignedIntValue);
        if (CGRectContainsPoint(cgFrame, quartzPoint)) {
            if (screenOut) *screenOut = screen;
            return NSMakePoint(screen.frame.origin.x + quartzPoint.x - CGRectGetMinX(cgFrame),
                               screen.frame.origin.y + CGRectGetMaxY(cgFrame) - quartzPoint.y);
        }
    }
    NSScreen *screen = NSScreen.mainScreen;
    if (screenOut) *screenOut = screen;
    return NSMakePoint(quartzPoint.x, screen.frame.origin.y + screen.frame.size.height - quartzPoint.y);
}

static void ensurePanel(NSScreen *screen) {
    if (g_panel) return;
    g_panel = [[RingPanel alloc] initWithContentRect:screen.frame
                                           styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
    g_panel.opaque = NO;
    g_panel.backgroundColor = NSColor.clearColor;
    g_panel.hasShadow = YES;
    // Keep the radial selector visible above full-screen browser/app windows.
    g_panel.level = NSPopUpMenuWindowLevel + 1;
    g_panel.hidesOnDeactivate = NO;
    // The full-screen panel also catches scrolling if the Quartz event tap
    // misses a trackpad event or is temporarily disabled by the system.
    g_panel.ignoresMouseEvents = NO;
    g_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary |
                                 NSWindowCollectionBehaviorStationary;
    g_ringView = [[RingView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(screen.frame), NSHeight(screen.frame))];
    g_ringView.entries = g_windowEntries;
    g_ringView.selectedIndex = -1;
    g_panel.contentView = g_ringView;
}

static CGFloat fittedRingRadius(NSSize size, NSUInteger count, CGFloat *centerOffsetY) {
    CGFloat radius = MIN(size.width * 0.44, (size.height - 100.0) / 2.0);
    if (count == 0) {
        if (centerOffsetY) *centerOffsetY = 0;
        return MAX(0, radius);
    }

    CGFloat finalRadius = radius;
    CGFloat finalOffsetY = 0;
    for (int pass = 0; pass < 3; pass++) {
        CGFloat radiusX = finalRadius, radiusY = finalRadius;
        ringEllipseRadii(count, finalRadius, &radiusX, &radiusY);
        CGFloat cardWidth = safeCardWidthForRing(count, radiusX, radiusY, size.width);
        CGFloat previewWidth = cardWidth * 0.94;
        CGFloat topContent = MAX(previewWidth * 0.30, 47.0);
        CGFloat bottomContent = topContent;
        finalOffsetY = (bottomContent - topContent) / 2.0;
        CGFloat scaleX = radiusX / (finalRadius > 0 ? finalRadius : 1.0);
        CGFloat scaleY = radiusY / (finalRadius > 0 ? finalRadius : 1.0);
        CGFloat horizontalLimit = (size.width / 2.0 - 20 - cardWidth / 2.0) / scaleX;
        CGFloat topLimit = (size.height / 2.0 - 20 - finalOffsetY - topContent) / scaleY;
        CGFloat bottomLimit = (size.height / 2.0 - 20 + finalOffsetY - bottomContent) / scaleY;
        finalRadius = MAX(0, MIN(radius, MIN(horizontalLimit, MIN(topLimit, bottomLimit))));
    }
    if (centerOffsetY) *centerOffsetY = finalOffsetY;
    return finalRadius;
}

static void pruneDeadWindowEntriesLive(void);

static void showRing(uint64_t generation) {
    if (generation != atomic_load(&g_gestureGeneration) || !atomic_load(&g_gestureActive)) return;
    if (atomic_load(&g_ringShownGeneration) == generation) return;
    NSScreen *screen = nil;
    (void)appKitPointFromQuartz(g_cursorAtGestureStart, &screen); // Cursor chooses the display only.
    ensurePanel(screen);
    CGFloat width = NSWidth(screen.frame), height = NSHeight(screen.frame);
    CGFloat centerOffsetY = 0;
    CGFloat fittedRadius = fittedRingRadius(NSMakeSize(width, height), g_windowEntries.count, &centerOffsetY);
    NSPoint anchor = NSMakePoint(width / 2.0, height / 2.0 + centerOffsetY);
    g_ringView.entries = g_windowEntries;
    g_ringView.selectedIndex = -1;
    g_ringView.anchorPoint = anchor;
    g_ringView.ringRadius = fittedRadius;
    for (RingEntry *entry in g_windowEntries) (void)resolvedThumbnail(entry);
    [g_ringView setNeedsDisplay:YES];
    // Avoid forcing a synchronous draw before the panel is ordered onscreen.
    [g_panel setFrame:screen.frame display:NO];
    atomic_store(&g_ringOverlayVisible, true);
    [g_panel orderFrontRegardless];
    atomic_store(&g_ringShownGeneration, generation);
    fprintf(stderr, "[ring] overlay shown at screen center; %lu entries\n", (unsigned long)g_windowEntries.count);

    // Pruning may issue CG/AX queries. Run it after the cached ring is already
    // visible, away from the main queue and gesture-start path.
    dispatch_async(g_windowScanQueue, ^{
        if (generation == atomic_load(&g_gestureGeneration) && atomic_load(&g_gestureActive)) {
            pruneDeadWindowEntriesLive();
        }
    });
}

static AXUIElementRef findTabButton(AXUIElementRef parent, NSString *title, int depth);
static BOOL setChromeActiveTab(NSString *windowID, NSString *tabID);
static BOOL setChromeActiveTabWithIndex(NSString *windowID, NSString *tabID, NSUInteger tabIndex1Based);

static void raiseWindowForEntry(RingEntry *entry, uint64_t generation) {
    if (generation != atomic_load(&g_gestureGeneration)) return;
    if (!entry.application || entry.application.isTerminated) return;

    // Chrome profiles are separate windows in one app. Activating Chrome keeps
    // the last used profile in front unless that window is made index 1.
    if (generation == atomic_load(&g_gestureGeneration) && entry.isTab &&
        entry.chromeWindowID.length) {
        BOOL switched = setChromeActiveTabWithIndex(entry.chromeWindowID, entry.chromeTabID,
                                                    entry.tabIndex + 1);
        if (switched) return;
        NSLog(@"[Chrome tabs] could not activate window %@ tab %@ index %lu",
              entry.chromeWindowID, entry.chromeTabID, (unsigned long)(entry.tabIndex + 1));
    }

    AXUIElementRef bestWindow = NULL;
    if (entry.accessibilityWindowObject) {
        bestWindow = (AXUIElementRef)CFRetain((__bridge AXUIElementRef)entry.accessibilityWindowObject);
        AXUIElementSetMessagingTimeout(bestWindow, 0.25f);
        AXError raiseErr = AXUIElementPerformAction(bestWindow, kAXRaiseAction);
        if (raiseErr != kAXErrorSuccess && raiseErr != kAXErrorActionUnsupported) {
            CFRelease(bestWindow);
            bestWindow = NULL;
        }
    }

    if (!bestWindow) {
        if (generation != atomic_load(&g_gestureGeneration)) return;
        AXUIElementRef appElement = AXUIElementCreateApplication(entry.application.processIdentifier);
        if (appElement) {
            AXUIElementSetMessagingTimeout(appElement, 0.3f);
            CFTypeRef windowsValue = NULL;
            AXError error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &windowsValue);
            double bestScore = DBL_MAX;
            if (error == kAXErrorSuccess && windowsValue && CFGetTypeID(windowsValue) == CFArrayGetTypeID()) {
                CFArrayRef windows = (CFArrayRef)windowsValue;
                for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
                    AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
                    CFTypeRef titleValue = NULL;
                    NSString *axTitle = nil;
                    if (AXUIElementCopyAttributeValue(window, kAXTitleAttribute, &titleValue) == kAXErrorSuccess && titleValue) {
                        axTitle = CFBridgingRelease(titleValue);
                    }

                    BOOL titleMatch = axTitle.length > 0 && entry.windowTitle.length > 0 &&
                        [axTitle localizedCaseInsensitiveCompare:entry.windowTitle] == NSOrderedSame;
                    double score = titleMatch ? 0.0 : 1000000.0;

                    CFTypeRef positionValue = NULL, sizeValue = NULL;
                    CGPoint position = CGPointZero;
                    CGSize size = CGSizeZero;
                    BOOL hasPosition = AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &positionValue) == kAXErrorSuccess &&
                        positionValue && AXValueGetTypeID() == CFGetTypeID(positionValue) &&
                        AXValueGetValue((AXValueRef)positionValue, kAXValueCGPointType, &position);
                    BOOL hasSize = AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess &&
                        sizeValue && AXValueGetTypeID() == CFGetTypeID(sizeValue) &&
                        AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);
                    if (hasPosition && hasSize) {
                        double geometryError = fabs(position.x - entry.windowBounds.origin.x) +
                            fabs(position.y - entry.windowBounds.origin.y) +
                            fabs(size.width - entry.windowBounds.size.width) +
                            fabs(size.height - entry.windowBounds.size.height);
                        score += geometryError;
                    }
                    if ((titleMatch || (entry.windowBounds.size.width > 0 && hasPosition && hasSize)) && score < bestScore) {
                        bestScore = score;
                        if (bestWindow) CFRelease(bestWindow);
                        bestWindow = (AXUIElementRef)CFRetain(window);
                    }
                    if (positionValue) CFRelease(positionValue);
                    if (sizeValue) CFRelease(sizeValue);
                }
            }
            if (windowsValue) CFRelease(windowsValue);
            CFRelease(appElement);
            if (bestWindow) {
                AXUIElementSetMessagingTimeout(bestWindow, 0.25f);
                AXUIElementPerformAction(bestWindow, kAXRaiseAction);
            }
        }
    }

    if (generation == atomic_load(&g_gestureGeneration) && entry.isTab) {
        if (entry.accessibilityTabObject) {
            // AX-backed entries already identify the exact tab. Never replace that
            // identity with a title lookup if pressing it fails.
            AXUIElementRef cachedTab = (__bridge AXUIElementRef)entry.accessibilityTabObject;
            AXUIElementSetMessagingTimeout(cachedTab, 0.2f);
            AXUIElementPerformAction(cachedTab, kAXPressAction);
        } else if (bestWindow && entry.tabTitle.length) {
            // If Apple Events are denied, AppleScript rows still fall back to an
            // exact AX title match in the mapped Chrome window.
            AXUIElementRef tab = findTabButton(bestWindow, entry.tabAXTitle ?: entry.tabTitle, 0);
            if (tab) {
                AXUIElementSetMessagingTimeout(tab, 0.2f);
                AXUIElementPerformAction(tab, kAXPressAction);
                CFRelease(tab);
            }
        }
    }
    if (bestWindow) {
        CFRelease(bestWindow);
    }
}

static void selectWindowImmediately(uint64_t generation, NSInteger selection) {
    if (generation != atomic_load(&g_gestureGeneration) || !atomic_load(&g_gestureActive) || !g_panel) return;
    g_ringView.selectedIndex = selection;
    [g_ringView setNeedsDisplay:YES];
}

static void scheduleSelectionUpdate(uint64_t generation, NSInteger selection) {
    BOOL shouldDispatch = NO;
    os_unfair_lock_lock(&g_selectionLock);
    g_pendingSelection = selection;
    g_pendingSelectionGeneration = generation;
    if (!g_selectionUpdatePending) {
        g_selectionUpdatePending = YES;
        shouldDispatch = YES;
    }
    os_unfair_lock_unlock(&g_selectionLock);
    if (!shouldDispatch) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        os_unfair_lock_lock(&g_selectionLock);
        NSInteger latestSelection = g_pendingSelection;
        uint64_t latestGeneration = g_pendingSelectionGeneration;
        g_selectionUpdatePending = NO;
        os_unfair_lock_unlock(&g_selectionLock);
        selectWindowImmediately(latestGeneration, latestSelection);
    });
}

static void finishGesture(uint64_t generation, NSInteger selection);

static void holdChromePrefetch(NSTimeInterval seconds) {
    @synchronized ([NSMutableDictionary class]) {
        NSTimeInterval until = NSProcessInfo.processInfo.systemUptime + seconds;
        if (until > g_chromePrefetchHoldUntil) g_chromePrefetchHoldUntil = until;
    }
}

static BOOL chromePrefetchIsHeld(void) {
    @synchronized ([NSMutableDictionary class]) {
        return NSProcessInfo.processInfo.systemUptime < g_chromePrefetchHoldUntil;
    }
}

static void finishGesture(uint64_t generation, NSInteger selection) {
    if (generation != atomic_load(&g_gestureGeneration)) return;
    // Block background Chrome tab cycling before the overlay goes away.
    // Prefetch that started on an inactive tab must not undo the user's pick.
    holdChromePrefetch(2.5);

    // Main-queue work can arrive out of order around a short touch sequence.
    // Present this generation synchronously before any finish can hide it.
    if (atomic_load(&g_ringShownGeneration) != generation) {
        showRing(generation);
        if (atomic_load(&g_ringShownGeneration) == generation) {
            // Let AppKit/compositor present at least one frame before closing
            // a ring whose touch-up raced its first show request.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ finishGesture(generation, selection); });
            return;
        }
    }
    if (generation != atomic_load(&g_gestureGeneration)) return;
    atomic_store(&g_gestureActive, false);
    atomic_store(&g_gestureEnding, false);
    if (g_panel) [g_panel orderOut:nil];
    atomic_store(&g_ringOverlayVisible, false);
    releaseDecodedThumbnails();
    if (selection < 0 || selection >= (NSInteger)g_windowEntries.count) {
        return;
    }

    RingEntry *entry = g_windowEntries[(NSUInteger)selection];
    if (!entry.application || entry.application.isTerminated) {
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // Activate the application without asking AppKit to bring every window
    // forward. For Chrome entries, raiseWindowForEntry below raises the one
    // window that owns the selected tab.
    [entry.application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
    BOOL captureChromeAfterRaise =
        [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"] &&
        entry.windowID != kCGNullWindowID;
    NSString *chromeTabKey = captureChromeAfterRaise ? [tabThumbnailKey(entry) copy] : nil;
    CGWindowID chromeWindowID = entry.windowID;
    dispatch_async(g_windowActivationQueue, ^{
        raiseWindowForEntry(entry, generation);
        if (!chromeTabKey.length) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 450 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (atomic_load(&g_gestureActive)) return;
            @synchronized ([NSMutableDictionary class]) {
                g_chromeWindowLastCapture[@(chromeWindowID)] = @0;
                g_chromeCaptureTabKeys[@(chromeWindowID)] = chromeTabKey;
                for (RingEntry *current in g_windowEntries) {
                    if (![current.application.bundleIdentifier isEqualToString:@"com.google.Chrome"] ||
                        current.windowID != chromeWindowID) continue;
                    current.isSelectedTab = [tabThumbnailKey(current) isEqualToString:chromeTabKey];
                }
            }
            schedulePendingThumbnailCapture(g_windowEntries);
        });
    });
}

static NSString *axStringAttribute(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return nil;
    if (CFGetTypeID(value) != CFStringGetTypeID()) { CFRelease(value); return nil; }
    return CFBridgingRelease(value);
}

static NSString *visibleTabTitle(NSString *title) {
    NSString *memorySuffix = @" - Memory usage - ";
    NSRange suffixRange = [title rangeOfString:memorySuffix options:NSBackwardsSearch];
    if (suffixRange.location != NSNotFound) return [title substringToIndex:suffixRange.location];
    return title;
}

static NSString *chromeDisplayTitle(RingEntry *entry) {
    NSString *title = entry.tabTitle.length ? entry.tabTitle : (entry.windowTitle ?: @"");
    NSRange chromeMarker = [title rangeOfString:@" - Google Chrome"];
    if (chromeMarker.location != NSNotFound) {
        title = [title substringToIndex:chromeMarker.location];
    }
    title = visibleTabTitle(title);
    return title.length ? title : @"Chrome tab";
}

static NSString *cardLabelText(RingEntry *entry) {
    if ([entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"]) {
        return chromeDisplayTitle(entry);
    }
    if (entry.folderPath.length) return entry.folderPath;
    NSString *title = entry.tabTitle.length ? entry.tabTitle : (entry.windowTitle ?: @"");
    title = visibleTabTitle(title);
    NSString *appName = entry.application.localizedName;
    if (appName.length && title.length) {
        NSString *suffix = [NSString stringWithFormat:@" - %@", appName];
        if ([title hasSuffix:suffix] && title.length > suffix.length) {
            title = [title substringToIndex:title.length - suffix.length];
        }
    }
    if (title.length) return title;
    return appName.length ? appName : @"Window";
}

static void drawCardLabel(NSString *text, NSRect cardRect, BOOL truncateMiddle) {
    if (!text.length) return;
    NSDictionary *measure = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0]
    };
    NSSize textSize = [text sizeWithAttributes:measure];
    CGFloat maxBadgeW = MAX(24.0, NSWidth(cardRect) - 16.0);
    CGFloat badgeW = MIN(maxBadgeW, textSize.width + 16.0);
    CGFloat badgeH = 22.0;
    NSRect badgeRect = NSMakeRect(NSMinX(cardRect) + 8.0, NSMinY(cardRect) + 8.0, badgeW, badgeH);
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:badgeRect xRadius:5.0 yRadius:5.0];
    [[NSColor colorWithCalibratedWhite:0.06 alpha:0.78] setFill];
    [pill fill];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = truncateMiddle ? NSLineBreakByTruncatingMiddle : NSLineBreakByTruncatingTail;
    NSDictionary *drawAttr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0],
        NSParagraphStyleAttributeName: style
    };
    NSRect textRect = NSMakeRect(NSMinX(badgeRect) + 8.0, NSMinY(badgeRect) + 3.0,
                                 badgeW - 16.0, badgeH - 6.0);
    [text drawInRect:textRect withAttributes:drawAttr];
}

static NSString *chromeHostFromEntry(RingEntry *entry) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:entry.tabURL ?: @""];
    NSString *host = parts.host.length ? parts.host : (parts.scheme.length ? parts.scheme : @"");
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if (host.length) return host;
    NSString *title = chromeDisplayTitle(entry);
    if ([title localizedCaseInsensitiveContainsString:@"youtube"]) return @"youtube.com";
    return @"Google Chrome";
}

static NSString *youtubeVideoIDFromURL(NSString *urlString) {
    if (!urlString.length) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:urlString];
    NSString *host = parts.host.lowercaseString ?: @"";
    NSString *path = parts.path ?: @"";
    if ([host isEqualToString:@"youtu.be"] || [host hasSuffix:@".youtu.be"]) {
        NSString *videoID = path.lastPathComponent;
        return videoID.length >= 11 ? [videoID substringToIndex:11] : nil;
    }
    BOOL isYouTube = [host containsString:@"youtube.com"] || [host containsString:@"youtube-nocookie.com"];
    if (!isYouTube) return nil;
    for (NSURLQueryItem *item in parts.queryItems) {
        if ([item.name isEqualToString:@"v"] && item.value.length >= 11) {
            NSString *videoID = item.value;
            NSRange separator = [videoID rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"&?#"]];
            if (separator.location != NSNotFound) videoID = [videoID substringToIndex:separator.location];
            return videoID.length >= 11 ? [videoID substringToIndex:11] : videoID;
        }
    }
    for (NSString *prefix in @[@"/shorts/", @"/embed/", @"/live/", @"/v/"]) {
        NSRange range = [path rangeOfString:prefix];
        if (range.location == NSNotFound) continue;
        NSString *rest = [path substringFromIndex:NSMaxRange(range)];
        NSString *videoID = [rest componentsSeparatedByString:@"/"].firstObject;
        if (videoID.length >= 11) return [videoID substringToIndex:11];
    }
    return nil;
}

static void collectTabButtons(AXUIElementRef parent, NSMutableArray<NSDictionary *> *tabs, int depth) {
    if (!parent || depth > 8) return;
    AXUIElementSetMessagingTimeout(parent, 0.080f);
    CFTypeRef childrenValue = NULL;
    if (AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute, &childrenValue) != kAXErrorSuccess ||
        !childrenValue || CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
        if (childrenValue) CFRelease(childrenValue);
        return;
    }
    CFArrayRef children = (CFArrayRef)childrenValue;
    for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
        AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
        AXUIElementSetMessagingTimeout(child, 0.2f);
        NSString *subrole = axStringAttribute(child, kAXSubroleAttribute);
        NSString *role = axStringAttribute(child, kAXRoleAttribute);
        BOOL isTabControl = [subrole isEqualToString:@"AXTabButton"] ||
            [role isEqualToString:@"AXTabButton"] ||
            [role isEqualToString:@"AXRadioButton"];
        if (isTabControl) {
            NSString *title = axStringAttribute(child, kAXTitleAttribute);
            if (!title.length) title = axStringAttribute(child, kAXDescriptionAttribute);
            BOOL selected = NO;
            CFTypeRef selectedValue = NULL;
            if (AXUIElementCopyAttributeValue(child, kAXSelectedAttribute, &selectedValue) == kAXErrorSuccess && selectedValue) {
                if (CFGetTypeID(selectedValue) == CFBooleanGetTypeID()) {
                    selected = CFBooleanGetValue((CFBooleanRef)selectedValue);
                } else if (CFGetTypeID(selectedValue) == CFNumberGetTypeID()) {
                    int num = 0;
                    CFNumberGetValue((CFNumberRef)selectedValue, kCFNumberIntType, &num);
                    selected = (num != 0);
                }
                CFRelease(selectedValue);
            }
            if (!selected) {
                CFTypeRef valValue = NULL;
                if (AXUIElementCopyAttributeValue(child, kAXValueAttribute, &valValue) == kAXErrorSuccess && valValue) {
                    if (CFGetTypeID(valValue) == CFBooleanGetTypeID()) {
                        selected = CFBooleanGetValue((CFBooleanRef)valValue);
                    } else if (CFGetTypeID(valValue) == CFNumberGetTypeID()) {
                        int num = 0;
                        CFNumberGetValue((CFNumberRef)valValue, kCFNumberIntType, &num);
                        selected = (num != 0);
                    }
                    CFRelease(valValue);
                }
            }
            if (!title.length) title = @"Tab";
            [tabs addObject:@{
                @"title": title,
                @"selected": @(selected),
                @"element": CFBridgingRelease(CFRetain(child))
            }];
        } else {
            // Prune web page contents and static documents where tabs never reside
            if ([role isEqualToString:@"AXWebArea"] || [role isEqualToString:@"AXDocument"] || [role isEqualToString:@"AXTextArea"]) {
                continue;
            }
            collectTabButtons(child, tabs, depth + 1);
        }
    }
    CFRelease(childrenValue);
}

static BOOL tabElementIsInCurrentWindowTabList(AXUIElementRef windowElement, AXUIElementRef tabElement) {
    if (!windowElement || !tabElement) return YES;

    CFTypeRef childrenValue = NULL;
    AXError childrenErr = AXUIElementCopyAttributeValue(windowElement, kAXChildrenAttribute, &childrenValue);
    if (childrenErr != kAXErrorSuccess || !childrenValue || CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
        if (childrenValue) CFRelease(childrenValue);
        // An unavailable AX tree is not proof that a tab was closed.
        return YES;
    }
    CFRelease(childrenValue);

    NSMutableArray<NSDictionary *> *currentTabs = [NSMutableArray array];
    collectTabButtons(windowElement, currentTabs, 0);
    for (NSDictionary *tabInfo in currentTabs) {
        AXUIElementRef currentTab = (__bridge AXUIElementRef)tabInfo[@"element"];
        if (currentTab && CFEqual(tabElement, currentTab)) return YES;
    }
    return NO;
}

static AXUIElementRef findTabButton(AXUIElementRef parent, NSString *title, int depth) {
    if (!parent || depth > 8 || !title.length) return NULL;
    AXUIElementSetMessagingTimeout(parent, 0.2f);
    CFTypeRef childrenValue = NULL;
    if (AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute, &childrenValue) != kAXErrorSuccess ||
        !childrenValue || CFGetTypeID(childrenValue) != CFArrayGetTypeID()) {
        if (childrenValue) CFRelease(childrenValue);
        return NULL;
    }
    CFArrayRef children = (CFArrayRef)childrenValue;
    CFIndex count = CFArrayGetCount(children);
    AXUIElementRef found = NULL;

    // Pass 1: Check direct children at this level first (broad search)
    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
        NSString *subrole = axStringAttribute(child, kAXSubroleAttribute);
        NSString *role = axStringAttribute(child, kAXRoleAttribute);
        BOOL isTabControl = [subrole isEqualToString:@"AXTabButton"] ||
            [role isEqualToString:@"AXTabButton"] ||
            [role isEqualToString:@"AXRadioButton"];
        if (isTabControl) {
            NSString *tabTitle = axStringAttribute(child, kAXTitleAttribute);
            if (!tabTitle.length) tabTitle = axStringAttribute(child, kAXDescriptionAttribute);
            if (tabTitle.length > 0 && [tabTitle localizedCaseInsensitiveCompare:title] == NSOrderedSame) {
                found = (AXUIElementRef)CFRetain(child);
                break;
            }
        }
    }

    // Pass 2: Recurse into children, skipping web content areas
    if (!found) {
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
            NSString *role = axStringAttribute(child, kAXRoleAttribute);
            if ([role isEqualToString:@"AXWebArea"] || [role isEqualToString:@"AXDocument"] || [role isEqualToString:@"AXTextArea"]) {
                continue;
            }
            found = findTabButton(child, title, depth + 1);
            if (found) break;
        }
    }

    CFRelease(childrenValue);
    return found;
}

static BOOL axWindowBounds(AXUIElementRef window, CGRect *boundsOut) {
    CFTypeRef positionValue = NULL, sizeValue = NULL;
    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL hasPosition = AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &positionValue) == kAXErrorSuccess &&
        positionValue && AXValueGetTypeID() == CFGetTypeID(positionValue) &&
        AXValueGetValue((AXValueRef)positionValue, kAXValueCGPointType, &position);
    BOOL hasSize = AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess &&
        sizeValue && AXValueGetTypeID() == CFGetTypeID(sizeValue) &&
        AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);
    if (positionValue) CFRelease(positionValue);
    if (sizeValue) CFRelease(sizeValue);
    if (hasPosition && hasSize && boundsOut) *boundsOut = CGRectMake(position.x, position.y, size.width, size.height);
    return hasPosition && hasSize;
}

static CGWindowID matchingCGWindowID(pid_t pid, CGRect bounds, NSString *windowTitle,
                                     NSArray<NSDictionary *> *windowInfos, NSSet<NSNumber *> *usedIDs) {
    CGWindowID bestID = kCGNullWindowID;
    double bestScore = DBL_MAX;
    for (NSDictionary *info in windowInfos) {
        if ([info[(id)kCGWindowOwnerPID] intValue] != pid || [info[(id)kCGWindowLayer] intValue] != 0) continue;
        NSNumber *windowNumber = info[(id)kCGWindowNumber];
        if ([usedIDs containsObject:windowNumber]) continue;
        NSDictionary *candidate = info[(id)kCGWindowBounds];
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        double score = fabs(bounds.origin.x - [candidate[@"X"] doubleValue]) +
            fabs(bounds.origin.y - [candidate[@"Y"] doubleValue]) +
            fabs(bounds.size.width - [candidate[@"Width"] doubleValue]) +
            fabs(bounds.size.height - [candidate[@"Height"] doubleValue]);
        NSString *candidateTitle = info[(id)kCGWindowName];
        if (windowTitle.length && candidateTitle.length) {
            if ([candidateTitle localizedCaseInsensitiveContainsString:windowTitle] ||
                [windowTitle localizedCaseInsensitiveContainsString:candidateTitle]) {
                score -= 1000000.0;
            } else {
                score += 10000.0;
            }
        }
        if (score < bestScore) {
            bestScore = score;
            bestID = windowNumber.unsignedIntValue;
        }
    }
    return bestID;
}

static CGWindowID matchingTabCGWindowID(pid_t pid, CGRect bounds, NSString *tabTitle,
                                        NSArray<NSDictionary *> *windowInfos, NSSet<NSNumber *> *usedIDs) {
    if (!tabTitle.length) return kCGNullWindowID;
    CGWindowID bestID = kCGNullWindowID;
    double bestScore = DBL_MAX;
    NSString *cleanTabTitle = visibleTabTitle(tabTitle);
    if (!cleanTabTitle.length) cleanTabTitle = tabTitle;
    for (NSDictionary *info in windowInfos) {
        if ([info[(id)kCGWindowOwnerPID] intValue] != pid || [info[(id)kCGWindowLayer] intValue] != 0) continue;
        NSNumber *windowNumber = info[(id)kCGWindowNumber];
        if ([usedIDs containsObject:windowNumber]) continue;
        NSDictionary *candidate = info[(id)kCGWindowBounds];
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        NSString *candidateTitle = info[(id)kCGWindowName];
        if (!candidateTitle.length) continue;

        BOOL matches = [candidateTitle localizedCaseInsensitiveContainsString:cleanTabTitle] ||
                       [cleanTabTitle localizedCaseInsensitiveContainsString:candidateTitle] ||
                       [candidateTitle localizedCaseInsensitiveContainsString:tabTitle] ||
                       [tabTitle localizedCaseInsensitiveContainsString:candidateTitle];
        if (!matches) continue;

        double score = fabs(bounds.origin.x - [candidate[@"X"] doubleValue]) +
            fabs(bounds.origin.y - [candidate[@"Y"] doubleValue]) +
            fabs(bounds.size.width - [candidate[@"Width"] doubleValue]) +
            fabs(bounds.size.height - [candidate[@"Height"] doubleValue]);

        if ([candidateTitle localizedCaseInsensitiveCompare:cleanTabTitle] == NSOrderedSame ||
            [candidateTitle localizedCaseInsensitiveCompare:tabTitle] == NSOrderedSame) {
            score -= 1000000.0;
        }

        if (score < bestScore) {
            bestScore = score;
            bestID = windowNumber.unsignedIntValue;
        }
    }
    return bestID;
}

static NSString *normalizedTabURL(NSString *urlString) {
    if (!urlString.length) return @"";
    NSURLComponents *parts = [NSURLComponents componentsWithString:urlString];
    if (!parts) return urlString;
    parts.fragment = nil;
    NSString *host = parts.host.lowercaseString;
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    parts.host = host;
    NSString *path = parts.path;
    if (path.length > 1 && [path hasSuffix:@"/"]) {
        parts.path = [path substringToIndex:path.length - 1];
    }
    return parts.string ?: urlString;
}

static NSString *chromeArtworkCacheKey(NSString *tabURL) {
    NSString *videoID = youtubeVideoIDFromURL(tabURL);
    if (videoID.length) return [NSString stringWithFormat:@"yt:%@", videoID];
    NSString *norm = normalizedTabURL(tabURL);
    return norm.length ? [NSString stringWithFormat:@"url:%@", norm] : nil;
}

static void syncChromeTabMediaWithCurrentURL(RingEntry *entry) {
    if (![entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"]) return;
    NSString *tabKey = tabThumbnailKey(entry);
    if (!tabKey.length) return;
    if (!g_tabCachedURL) g_tabCachedURL = [NSMutableDictionary dictionary];
    NSString *url = normalizedTabURL(entry.tabURL);
    NSString *previous = g_tabCachedURL[tabKey];
    if (previous && ![previous isEqualToString:url]) {
        [g_tabThumbnailCache removeObjectForKey:tabKey];
        [g_tabArtworkCache removeObjectForKey:tabKey];
        [g_tabLastCaptured removeObjectForKey:tabKey];
        [g_tabArtworkRequests removeObject:tabKey];
        if (entry.windowID != kCGNullWindowID) g_chromeWindowLastCapture[@(entry.windowID)] = @0;
        entry.thumbnailData = nil;
        entry.thumbnail = nil;
    }
    g_tabCachedURL[tabKey] = url ?: @"";
    if (!entry.thumbnailData) {
        NSString *artKey = chromeArtworkCacheKey(entry.tabURL);
        NSData *shared = (artKey.length && g_urlArtworkCache) ? g_urlArtworkCache[artKey] : nil;
        if (shared) {
            g_tabArtworkCache[tabKey] = shared;
            applyThumbnailDataToEntry(entry, shared);
        }
    }
}

static NSString *tabThumbnailKey(RingEntry *entry) {
    if (entry.chromeWindowID.length && entry.chromeTabID.length) {
        return [NSString stringWithFormat:@"%d:chrome:%@:%@", entry.application.processIdentifier,
                entry.chromeWindowID, entry.chromeTabID];
    }
    NSString *tabIdentifier = entry.tabAXTitle.length > 0 ? entry.tabAXTitle : (entry.tabTitle.length > 0 ? entry.tabTitle : [NSString stringWithFormat:@"win%u_idx%lu", entry.windowID, (unsigned long)entry.tabIndex]);
    if (entry.isTab) {
        tabIdentifier = [NSString stringWithFormat:@"win%u_idx%lu:%@", entry.windowID,
                         (unsigned long)entry.tabIndex, tabIdentifier];
    }
    return [NSString stringWithFormat:@"%d:tab:%@", entry.application.processIdentifier, tabIdentifier];
}

static void populateThumbnailsFromCache(NSArray<RingEntry *> *entries) {
    @synchronized ([NSMutableDictionary class]) {
    for (RingEntry *entry in entries) {
        if (entry.isTab) {
            BOOL isChromeTab = [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"];
            if (isChromeTab) {
                // Drop stale screenshots when the tab navigates, then prefer a
                // real capture and fall back to a site preview for the new URL.
                syncChromeTabMediaWithCurrentURL(entry);
                NSString *tabKey = tabThumbnailKey(entry);
                if (!entry.thumbnailData) {
                    applyThumbnailDataToEntry(entry, g_tabThumbnailCache[tabKey] ?: g_tabArtworkCache[tabKey]);
                }
            } else if (!entry.thumbnailData) {
                NSString *tabKey = tabThumbnailKey(entry);
                if (g_tabThumbnailCache && g_tabThumbnailCache[tabKey]) {
                    applyThumbnailDataToEntry(entry, g_tabThumbnailCache[tabKey]);
                }
            }
        } else if (!entry.thumbnailData && entry.windowID != kCGNullWindowID && g_thumbnailCache) {
            applyThumbnailDataToEntry(entry, g_thumbnailCache[@(entry.windowID)]);
        }
    }
    }
}

static void pruneDeadWindowEntriesLive(void) {
    if (!g_windowEntries || !g_windowEntries.count) return;

    CFArrayRef allWindows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    BOOL canCheckWindowIDs = (allWindows != NULL);
    NSMutableSet<NSNumber *> *liveWindowIDs = [NSMutableSet set];
    if (allWindows) {
        CFIndex count = CFArrayGetCount(allWindows);
        for (CFIndex i = 0; i < count; i++) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(allWindows, i);
            NSNumber *wid = info[(id)kCGWindowNumber];
            if (wid) [liveWindowIDs addObject:wid];
        }
        CFRelease(allWindows);
    }

    NSMutableArray<RingEntry *> *validEntries = [NSMutableArray arrayWithCapacity:g_windowEntries.count];
    NSMutableArray<NSNumber *> *deadWindowIDs = [NSMutableArray array];
    NSMutableArray<NSString *> *deadTabKeys = [NSMutableArray array];
    BOOL changed = NO;

    for (RingEntry *entry in g_windowEntries) {
        // Fast terminated app check
        if (!entry.application || entry.application.isTerminated) {
            changed = YES;
            if (entry.windowID != kCGNullWindowID) [deadWindowIDs addObject:@(entry.windowID)];
            if (entry.isTab) [deadTabKeys addObject:tabThumbnailKey(entry)];
            continue;
        }

        // Check if application process is still alive in OS
        pid_t pid = entry.application.processIdentifier;
        if (pid > 0 && kill(pid, 0) != 0 && errno == ESRCH) {
            changed = YES;
            if (entry.windowID != kCGNullWindowID) [deadWindowIDs addObject:@(entry.windowID)];
            if (entry.isTab) [deadTabKeys addObject:tabThumbnailKey(entry)];
            continue;
        }

        // Window existence check via CGWindowListCopyWindowInfo
        BOOL windowAliveInCG = (entry.windowID != kCGNullWindowID &&
                                (!canCheckWindowIDs || [liveWindowIDs containsObject:@(entry.windowID)]));
        if (canCheckWindowIDs && entry.windowID != kCGNullWindowID && !windowAliveInCG) {
            changed = YES;
            [deadWindowIDs addObject:@(entry.windowID)];
            if (entry.isTab) [deadTabKeys addObject:tabThumbnailKey(entry)];
            continue;
        }

        // Accessibility window check (only if windowID was unknown)
        if (!windowAliveInCG && entry.accessibilityWindowObject) {
            AXUIElementRef winElem = (__bridge AXUIElementRef)entry.accessibilityWindowObject;
            AXUIElementSetMessagingTimeout(winElem, 0.010f);
            CFTypeRef roleVal = NULL;
            AXError err = AXUIElementCopyAttributeValue(winElem, kAXRoleAttribute, &roleVal);
            if (err == kAXErrorInvalidUIElement || err == kAXErrorCannotComplete) {
                changed = YES;
                if (entry.windowID != kCGNullWindowID) [deadWindowIDs addObject:@(entry.windowID)];
                if (entry.isTab) [deadTabKeys addObject:tabThumbnailKey(entry)];
                continue;
            }
            if (roleVal) CFRelease(roleVal);
        }

        // For tabs: check if accessibility tab element is still alive and attached to parent
        if (entry.isTab && entry.accessibilityTabObject) {
            AXUIElementRef tabElem = (__bridge AXUIElementRef)entry.accessibilityTabObject;
            AXUIElementSetMessagingTimeout(tabElem, 0.010f);
            CFTypeRef roleVal = NULL;
            AXError err = AXUIElementCopyAttributeValue(tabElem, kAXRoleAttribute, &roleVal);
            if (err != kAXErrorSuccess) {
                changed = YES;
                [deadTabKeys addObject:tabThumbnailKey(entry)];
                continue;
            }
            if (roleVal) CFRelease(roleVal);

            CFTypeRef parentVal = NULL;
            AXError parentErr = AXUIElementCopyAttributeValue(tabElem, kAXParentAttribute, &parentVal);
            if (parentErr != kAXErrorSuccess || !parentVal) {
                changed = YES;
                if (parentVal) CFRelease(parentVal);
                [deadTabKeys addObject:tabThumbnailKey(entry)];
                continue;
            }
            CFRelease(parentVal);

            AXUIElementRef windowElem = entry.accessibilityWindowObject
                ? (__bridge AXUIElementRef)entry.accessibilityWindowObject : NULL;
            if (!tabElementIsInCurrentWindowTabList(windowElem, tabElem)) {
                changed = YES;
                [deadTabKeys addObject:tabThumbnailKey(entry)];
                continue;
            }
        }

        [validEntries addObject:entry];
    }

    if (changed) {
        g_windowEntries = validEntries;
        atomic_store(&g_windowEntryCount, (int)validEntries.count);

        void (^updateUIAndCaches)(void) = ^{
            @synchronized ([NSMutableDictionary class]) {
            if (g_thumbnailCache) {
                for (NSNumber *wid in deadWindowIDs) {
                    [g_thumbnailCache removeObjectForKey:wid];
                    [g_windowLastSeen removeObjectForKey:wid];
                    [g_windowPIDMap removeObjectForKey:wid];
                }
            }
            if (g_tabThumbnailCache) {
                for (NSString *tKey in deadTabKeys) {
                    [g_tabThumbnailCache removeObjectForKey:tKey];
                    [g_tabArtworkCache removeObjectForKey:tKey];
                    [g_tabCachedURL removeObjectForKey:tKey];
                    [g_tabLastSeen removeObjectForKey:tKey];
                    [g_tabPIDMap removeObjectForKey:tKey];
                }
            }
            }
            if (g_ringView) {
                g_ringView.entries = validEntries;
                [g_ringView setNeedsDisplay:YES];
            }
        };

        if ([NSThread isMainThread]) {
            updateUIAndCaches();
        } else {
            dispatch_async(dispatch_get_main_queue(), updateUIAndCaches);
        }
        fprintf(stderr, "[prune] Live pruned dead entries on gesture start: now %lu entries\n", (unsigned long)validEntries.count);
    }
}

static NSDictionary<NSNumber *, NSString *> *fetchFinderPaths(void) {
    static NSAppleScript *s_finderScript = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *src = @"tell application \"Finder\"\n"
                         "  set out to \"\"\n"
                         "  repeat with i from 1 to count of windows\n"
                         "    try\n"
                         "      set wid to id of window i\n"
                         "      set u to URL of target of window i\n"
                         "      set out to out & wid & \"|\" & u & linefeed\n"
                         "    end try\n"
                         "  end repeat\n"
                         "  return out\n"
                         "end tell";
        s_finderScript = [[NSAppleScript alloc] initWithSource:src];
        [s_finderScript compileAndReturnError:nil];
    });
    if (!s_finderScript) return @{};
    NSDictionary *error = nil;
    NSAppleEventDescriptor *desc = nil;
    @synchronized (s_finderScript) {
        desc = [s_finderScript executeAndReturnError:&error];
    }
    if (error || !desc.stringValue) return @{};
    NSMutableDictionary<NSNumber *, NSString *> *map = [NSMutableDictionary dictionary];
    NSString *raw = desc.stringValue;
    NSString *homeDir = NSHomeDirectory();
    for (NSString *line in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@"|"];
        if (parts.count == 2) {
            unsigned int wid = (unsigned int)parts[0].integerValue;
            NSString *urlStr = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSURL *url = [NSURL URLWithString:urlStr];
            if (url.path.length > 0) {
                NSString *path = url.path;
                if ([path hasPrefix:homeDir]) {
                    path = [@"~" stringByAppendingString:[path substringFromIndex:homeDir.length]];
                }
                // Strip trailing slash if present (except root)
                if (path.length > 1 && [path hasSuffix:@"/"]) {
                    path = [path substringToIndex:path.length - 1];
                }
                map[@(wid)] = path;
            }
        }
    }
    return map;
}

static NSArray<NSDictionary *> *fetchChromeTabRows(void) {
    static NSAppleScript *s_chromeScript = nil;
    static NSArray<NSDictionary *> *s_lastRows = nil;
    static NSTimeInterval s_lastSuccess = 0;
    static NSTimeInterval s_retryAfter = 0;
    static NSTimeInterval s_lastErrorLog = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *src = @"set fieldSep to ASCII character 31\n"
                         "set output to \"\"\n"
                         "tell application \"Google Chrome\"\n"
                         "  repeat with windowIndex from 1 to count of windows\n"
                         "    try\n"
                         "      set chromeWindow to window windowIndex\n"
                         "      set windowID to (id of chromeWindow) as text\n"
                         "      set {xPos, yPos, x2, y2} to bounds of chromeWindow\n"
                         "      set winWidth to (x2 - xPos)\n"
                         "      set winHeight to (y2 - yPos)\n"
                         "      set activeIndex to active tab index of chromeWindow\n"
                         "      set activeTitle to (title of active tab of chromeWindow) as text\n"
                         "      set AppleScript's text item delimiters to {return, linefeed, fieldSep}\n"
                         "      set titleParts to text items of activeTitle\n"
                         "      set AppleScript's text item delimiters to \" \"\n"
                         "      set activeTitle to titleParts as text\n"
                         "      set AppleScript's text item delimiters to \"\"\n"
                         "      repeat with tabIndex from 1 to count of tabs of chromeWindow\n"
                         "        try\n"
                         "          set chromeTab to tab tabIndex of chromeWindow\n"
                         "          set tabID to (id of chromeTab) as text\n"
                         "          set tabTitle to (title of chromeTab) as text\n"
                         "          set tabURL to \"\"\n"
                         "          try\n"
                         "            set tabURL to (URL of chromeTab) as text\n"
                         "          end try\n"
                         "          set AppleScript's text item delimiters to {return, linefeed, fieldSep}\n"
                         "          set titleParts to text items of tabTitle\n"
                         "          set AppleScript's text item delimiters to \" \"\n"
                         "          set tabTitle to titleParts as text\n"
                         "          set AppleScript's text item delimiters to {return, linefeed, fieldSep}\n"
                         "          set urlParts to text items of tabURL\n"
                         "          set AppleScript's text item delimiters to \" \"\n"
                         "          set tabURL to urlParts as text\n"
                         "          set AppleScript's text item delimiters to \"\"\n"
                         "          set output to output & (windowIndex as text) & fieldSep & windowID & fieldSep & (tabIndex as text) & fieldSep & tabID & fieldSep & (activeIndex as text) & fieldSep & (xPos as text) & fieldSep & (yPos as text) & fieldSep & (winWidth as text) & fieldSep & (winHeight as text) & fieldSep & activeTitle & fieldSep & tabTitle & fieldSep & tabURL & linefeed\n"
                         "        on error\n"
                         "          set AppleScript's text item delimiters to \"\"\n"
                         "        end try\n"
                         "      end repeat\n"
                         "    on error\n"
                         "      set AppleScript's text item delimiters to \"\"\n"
                         "    end try\n"
                         "  end repeat\n"
                         "end tell\n"
                         "return output";
        s_chromeScript = [[NSAppleScript alloc] initWithSource:src];
        [s_chromeScript compileAndReturnError:nil];
    });
    if (!s_chromeScript) return @[];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!ensureChromeAutomation(YES)) {
        s_retryAfter = now + 5.0;
        return now - s_lastSuccess < 3.0 ? s_lastRows ?: @[] : @[];
    }
    if (now < s_retryAfter) return now - s_lastSuccess < 3.0 ? s_lastRows ?: @[] : @[];

    NSDictionary *error = nil;
    NSAppleEventDescriptor *desc = nil;
    @synchronized ([NSAppleScript class]) {
        desc = [s_chromeScript executeAndReturnError:&error];
    }
    if (error) {
        if (now - s_lastErrorLog > 30.0) {
            NSString *message = error[NSAppleScriptErrorMessage] ?: error.description;
            fprintf(stderr, "[Chrome tabs] AppleScript enumeration failed: %s\n",
                    message.UTF8String ?: "unknown error");
            s_lastErrorLog = now;
        }
        // Chrome can briefly reject an Apple Event while a window is closing.
        // Retry instead of permanently losing all Chrome tabs.
        s_retryAfter = now + 2.0;
        return now - s_lastSuccess < 3.0 ? s_lastRows ?: @[] : @[];
    }
    s_retryAfter = 0;
    if (!desc.stringValue.length) {
        s_lastRows = @[];
        s_lastSuccess = now;
        return @[];
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSString *line in [desc.stringValue componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (!line.length) continue;
        NSArray<NSString *> *fields = [line componentsSeparatedByString:@"\x1f"];
        if (fields.count != 12) continue;
        NSString *tabTitle = fields[10].length ? fields[10] : @"Tab";
        CGRect bounds = CGRectMake(fields[5].doubleValue, fields[6].doubleValue,
                                   fields[7].doubleValue, fields[8].doubleValue);
        [rows addObject:@{
            @"windowIndex": @(fields[0].integerValue),
            @"windowID": fields[1],
            @"tabIndex": @(fields[2].integerValue),
            @"tabID": fields[3],
            @"activeIndex": @(fields[4].integerValue),
            @"bounds": [NSValue valueWithRect:NSRectFromCGRect(bounds)],
            @"windowTitle": fields[9],
            @"title": tabTitle,
            @"URL": fields[11]
        }];
    }
    if (rows.count) {
        s_lastRows = [rows copy];
        s_lastSuccess = now;
    } else {
        s_retryAfter = now + 2.0;
        return now - s_lastSuccess < 3.0 ? s_lastRows ?: @[] : @[];
    }
    return rows;
}

static BOOL validChromeID(NSString *identifier) {
    return identifier.length > 0 &&
        [identifier rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

static BOOL ensureChromeAutomation(BOOL askUser) {
    static NSTimeInterval s_nextCheck = 0;
    static int s_cached = -1; // 1 granted, 0 denied, -1 unknown, -2 waiting for prompt
    static BOOL s_didAsk = NO;
    static BOOL s_loggedDenial = NO;
    if (s_cached == 1) return YES;

    BOOL chromeRunning = NO;
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if ([app.bundleIdentifier isEqualToString:@"com.google.Chrome"]) {
            chromeRunning = YES;
            break;
        }
    }
    if (!chromeRunning) return NO;

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ((s_cached == 0 || s_cached == -2) && now < s_nextCheck) return NO;

    BOOL shouldAsk = askUser && !s_didAsk && [NSThread isMainThread];
    if (shouldAsk) s_didAsk = YES;

    NSAppleEventDescriptor *target =
        [NSAppleEventDescriptor descriptorWithBundleIdentifier:@"com.google.Chrome"];
    OSStatus status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, shouldAsk);
    if (status == noErr) {
        s_cached = 1;
        s_loggedDenial = NO;
        return YES;
    }
    if (status == procNotFound || status == -600) return NO;
    if (status == -1744) { // errAEEventWouldRequireUserConsent
        s_cached = -2;
        s_nextCheck = now + 2.0;
        return NO;
    }
    s_cached = 0;
    s_nextCheck = now + 8.0;
    if (!s_loggedDenial) {
        fprintf(stderr,
                "[Chrome tabs] Automation denied (status=%d). Enable Touchpad Switcher -> Google Chrome in System Settings -> Privacy & Security -> Automation.\n",
                (int)status);
        s_loggedDenial = YES;
    }
    return NO;
}

static BOOL runChromeSwitchScript(NSString *source) {
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = nil;
    @synchronized ([NSAppleScript class]) {
        result = [script executeAndReturnError:&error];
    }
    if (error) {
        NSLog(@"[Chrome tabs] switch script failed: %@", error[NSAppleScriptErrorMessage] ?: error);
        return NO;
    }
    return result.booleanValue || [result.stringValue isEqualToString:@"true"];
}

static BOOL setChromeActiveTabWithIndex(NSString *windowID, NSString *tabID, NSUInteger tabIndex1Based) {
    if (!validChromeID(windowID)) return NO;
    BOOL haveTabID = validChromeID(tabID);
    if (!haveTabID && tabIndex1Based == 0) return NO;
    // Chrome exposes window and tab ids as text, not integers. Comparing a
    // text id with an unquoted number never matches, so the previously
    // selected tab (often YouTube) stayed in front for every card.
    NSMutableString *source = [NSMutableString stringWithFormat:
        @"tell application \"Google Chrome\"\n"
         "try\n"
         "set targetWindow to first window whose id is \"%@\"\n"
         "set index of targetWindow to 1\n", windowID];
    if (haveTabID) {
        [source appendFormat:
         @"repeat with tabIndex from 1 to count of tabs of targetWindow\n"
          "if (id of tab tabIndex of targetWindow) as text is \"%@\" then\n"
          "set active tab index of targetWindow to tabIndex\n"
          "return true\n"
          "end if\n"
          "end repeat\n", tabID];
    }
    if (tabIndex1Based > 0) {
        [source appendFormat:
         @"set tabCount to count of tabs of targetWindow\n"
          "if %@ <= tabCount then\n"
          "set active tab index of targetWindow to %@\n"
          "return true\n"
          "end if\n", @(tabIndex1Based), @(tabIndex1Based)];
    }
    [source appendString:
         @"return true\n"
          "end try\n"
          "end tell\n"
          "return false"];
    return runChromeSwitchScript(source);
}

static BOOL setChromeActiveTab(NSString *windowID, NSString *tabID) {
    return setChromeActiveTabWithIndex(windowID, tabID, 0);
}

static NSArray<RingEntry *> *collectOpenWindows(void) {
    NSMutableDictionary<NSNumber *, NSRunningApplication *> *appsByPID = [NSMutableDictionary dictionary];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.activationPolicy == NSApplicationActivationPolicyRegular && !app.isTerminated) {
            appsByPID[@(app.processIdentifier)] = app;
        }
    }

    BOOL finderRunning = NO;
    for (NSRunningApplication *a in appsByPID.allValues) {
        if ([a.bundleIdentifier isEqualToString:@"com.apple.finder"]) {
            finderRunning = YES;
            break;
        }
    }
    NSDictionary<NSNumber *, NSString *> *finderPaths = finderRunning ? fetchFinderPaths() : @{};

    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
                                                     kCGNullWindowID);
    NSArray<NSDictionary *> *windowInfos = windows ? CFBridgingRelease(windows) : @[];
    NSMutableDictionary<NSNumber *, NSString *> *cgTitlesByWindowID = [NSMutableDictionary dictionary];
    for (NSDictionary *windowInfo in windowInfos) {
        NSNumber *windowID = windowInfo[(id)kCGWindowNumber];
        if (!windowID) continue;
        NSString *cgTitle = windowInfo[(id)kCGWindowName];
        cgTitlesByWindowID[windowID] = [cgTitle isKindOfClass:[NSString class]] ? cgTitle : @"";
    }
    NSMutableArray<RingEntry *> *entries = [NSMutableArray array];
    // Window presence comes from the complete CG list. AX is used to enrich
    // windows with tab information, not to decide whether an app was handled.
    NSMutableSet<NSNumber *> *handledTabWindowIDs = [NSMutableSet set];
    for (NSRunningApplication *app in appsByPID.allValues) {
        BOOL isFinder = [app.bundleIdentifier isEqualToString:@"com.apple.finder"];
        NSMutableSet<NSNumber *> *matchedWindowIDs = [NSMutableSet set];
        if ([app.bundleIdentifier isEqualToString:@"com.google.Chrome"]) {
            NSArray<NSDictionary *> *chromeTabs = fetchChromeTabRows();
            if (chromeTabs.count) {
                // AppleScript is authoritative for Chrome's browser windows and
                // tabs. Mark Chrome's on-screen window records as represented so
                // an imperfect title/bounds match cannot append a duplicate card.
                for (NSDictionary *info in windowInfos) {
                    if ([info[(id)kCGWindowOwnerPID] intValue] == app.processIdentifier &&
                        [info[(id)kCGWindowLayer] integerValue] == 0) {
                        NSNumber *windowID = info[(id)kCGWindowNumber];
                        if (windowID) [handledTabWindowIDs addObject:windowID];
                    }
                }
                NSMutableDictionary<NSNumber *, NSNumber *> *chromeWindowIDs = [NSMutableDictionary dictionary];
                for (NSDictionary *tabInfo in chromeTabs) {
                    CGRect bounds = NSRectToCGRect([tabInfo[@"bounds"] rectValue]);
                    NSString *windowTitle = tabInfo[@"windowTitle"] ?: @"";
                    NSNumber *windowIndex = tabInfo[@"windowIndex"];
                    NSNumber *mappedWindowID = chromeWindowIDs[windowIndex];
                    CGWindowID windowID = mappedWindowID
                        ? mappedWindowID.unsignedIntValue
                        : matchingCGWindowID(app.processIdentifier, bounds, windowTitle, windowInfos, matchedWindowIDs);
                    if (!mappedWindowID) chromeWindowIDs[windowIndex] = @(windowID);
                    if (windowID != kCGNullWindowID && !mappedWindowID) {
                        [matchedWindowIDs addObject:@(windowID)];
                        [handledTabWindowIDs addObject:@(windowID)];
                    }

                    RingEntry *entry = [RingEntry new];
                    entry.application = app;
                    entry.windowTitle = windowTitle.length ? windowTitle : (app.localizedName ?: @"Google Chrome");
                    entry.tabAXTitle = tabInfo[@"title"];
                    entry.tabTitle = visibleTabTitle(entry.tabAXTitle);
                    entry.tabURL = tabInfo[@"URL"];
                    entry.isTab = YES;
                    entry.tabIndex = [tabInfo[@"tabIndex"] unsignedIntegerValue] - 1;
                    entry.chromeWindowID = tabInfo[@"windowID"];
                    entry.chromeTabID = tabInfo[@"tabID"];
                    entry.isSelectedTab = [tabInfo[@"tabIndex"] integerValue] == [tabInfo[@"activeIndex"] integerValue];
                    entry.icon = app.icon ?: [NSImage imageNamed:NSImageNameApplicationIcon];
                    entry.windowID = windowID;
                    entry.windowBounds = bounds;
                    [entries addObject:entry];
                }
                static NSUInteger s_lastChromeTabLogCount = NSUIntegerMax;
                if (chromeTabs.count != s_lastChromeTabLogCount) {
                    s_lastChromeTabLogCount = chromeTabs.count;
                    NSLog(@"[Chrome tabs] AppleScript listed %lu tabs", (unsigned long)chromeTabs.count);
                }
                continue;
            }
        }
        AXUIElementRef appElement = AXUIElementCreateApplication(app.processIdentifier);
        if (!appElement) continue;
        CFTypeRef windowsValue = NULL;
        if (AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &windowsValue) == kAXErrorSuccess &&
            windowsValue && CFGetTypeID(windowsValue) == CFArrayGetTypeID()) {
            CFArrayRef axWindows = (CFArrayRef)windowsValue;
            for (CFIndex wi = 0; wi < CFArrayGetCount(axWindows); wi++) {
                AXUIElementRef axWindow = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, wi);
                NSString *subrole = axStringAttribute(axWindow, kAXSubroleAttribute);
                if (subrole && ![subrole isEqualToString:@"AXStandardWindow"] && ![subrole isEqualToString:@"AXDialog"]) {
                    continue;
                }
                NSMutableArray<NSDictionary *> *tabs = [NSMutableArray array];
                collectTabButtons(axWindow, tabs, 0);
                if (tabs.count && [app.bundleIdentifier isEqualToString:@"com.google.Chrome"]) {
                    // Chrome can publish extra compositor/Surface records through
                    // CGWindowList. Once AX has supplied this browser window's
                    // tabs, do not append those surfaces as separate windows.
                    for (NSDictionary *info in windowInfos) {
                        if ([info[(id)kCGWindowOwnerPID] intValue] == app.processIdentifier &&
                            [info[(id)kCGWindowLayer] integerValue] == 0) {
                            NSNumber *windowID = info[(id)kCGWindowNumber];
                            if (windowID) [handledTabWindowIDs addObject:windowID];
                        }
                    }
                }
                CGRect bounds = CGRectZero;
                axWindowBounds(axWindow, &bounds);
                if (bounds.size.width < 100 || bounds.size.height < 60) continue;
                NSString *windowTitle = axStringAttribute(axWindow, kAXTitleAttribute) ?: @"";
                CGWindowID windowID = matchingCGWindowID(app.processIdentifier, bounds, windowTitle,
                                                          windowInfos, matchedWindowIDs);
                if (windowID != kCGNullWindowID) {
                    [matchedWindowIDs addObject:@(windowID)];
                    [handledTabWindowIDs addObject:@(windowID)];
                }
                if (!tabs.count) {
                    // Keep CGWindowList as the authority for window existence.
                    // AX-only/stale windows are recovered by the CG fallback below.
                    if (windowID == kCGNullWindowID) continue;
                    RingEntry *entry = [RingEntry new];
                    entry.application = app;
                    entry.windowTitle = windowTitle.length > 0 ? windowTitle : (app.localizedName ?: @"Untitled");
                    entry.tabTitle = @"";
                    entry.isTab = NO;
                    entry.accessibilityWindowObject = CFBridgingRelease(CFRetain(axWindow));
                    entry.icon = app.icon ?: [NSImage imageNamed:NSImageNameApplicationIcon];
                    entry.windowID = windowID;
                    entry.windowBounds = bounds;
                    if (isFinder && entry.windowID != kCGNullWindowID && finderPaths[@(entry.windowID)]) {
                        entry.folderPath = finderPaths[@(entry.windowID)];
                    }
                    [entries addObject:entry];
                    continue;
                }
                BOOL anySelected = NO;
                for (NSDictionary *tab in tabs) {
                    if ([tab[@"selected"] boolValue]) { anySelected = YES; break; }
                }
                for (NSUInteger tabIndex = 0; tabIndex < tabs.count; tabIndex++) {
                    NSDictionary *tab = tabs[tabIndex];
                    RingEntry *entry = [RingEntry new];
                    entry.application = app;
                    entry.windowTitle = windowTitle;
                    entry.tabAXTitle = tab[@"title"];
                    entry.tabTitle = visibleTabTitle(entry.tabAXTitle);
                    entry.isTab = YES;
                    entry.isSelectedTab = anySelected ? [tab[@"selected"] boolValue] : (tabIndex == 0);
                    entry.tabIndex = tabIndex;
                    entry.accessibilityWindowObject = CFBridgingRelease(CFRetain(axWindow));
                    entry.accessibilityTabObject = tab[@"element"];
                    entry.icon = app.icon ?: [NSImage imageNamed:NSImageNameApplicationIcon];

                    CGWindowID specificTabWindowID = kCGNullWindowID;
                    if (!entry.isSelectedTab || windowID == kCGNullWindowID) {
                        specificTabWindowID = matchingTabCGWindowID(app.processIdentifier, bounds,
                                                                    entry.tabAXTitle, windowInfos, matchedWindowIDs);
                    }
                    if (specificTabWindowID != kCGNullWindowID) {
                        entry.windowID = specificTabWindowID;
                        [matchedWindowIDs addObject:@(specificTabWindowID)];
                        [handledTabWindowIDs addObject:@(specificTabWindowID)];
                    } else {
                        entry.windowID = windowID;
                    }
                    if (entry.windowID == kCGNullWindowID) continue;
                    entry.windowBounds = bounds;
                    if (isFinder) {
                        if (entry.windowID != kCGNullWindowID && finderPaths[@(entry.windowID)]) {
                            entry.folderPath = finderPaths[@(entry.windowID)];
                        } else if (windowID != kCGNullWindowID && finderPaths[@(windowID)]) {
                            entry.folderPath = finderPaths[@(windowID)];
                        }
                    }
                    [entries addObject:entry];
                }
            }
        }
        if (windowsValue) CFRelease(windowsValue);
        CFRelease(appElement);
    }
    for (NSDictionary *info in windowInfos) {
        NSNumber *layer = info[(id)kCGWindowLayer];
        NSNumber *pid = info[(id)kCGWindowOwnerPID];
        if (layer.integerValue != 0 || !pid) continue;
        NSRunningApplication *app = appsByPID[pid];
        if (!app) continue;
        NSNumber *winNum = info[(id)kCGWindowNumber];
        if (winNum && [handledTabWindowIDs containsObject:winNum]) continue;

        NSString *title = info[(id)kCGWindowName];

        NSDictionary *bounds = info[(id)kCGWindowBounds];
        CGRect windowBounds = CGRectZero;
        if ([bounds isKindOfClass:[NSDictionary class]]) {
            windowBounds = CGRectMake([bounds[@"X"] doubleValue], [bounds[@"Y"] doubleValue],
                                      [bounds[@"Width"] doubleValue], [bounds[@"Height"] doubleValue]);
            CGFloat width = [bounds[@"Width"] doubleValue];
            CGFloat height = [bounds[@"Height"] doubleValue];
            if (width < 100 || height < 60) continue;
        } else {
            continue;
        }
        if (!title.length) {
            BOOL hiddenSurfaceInsideWindow = NO;
            for (NSDictionary *containerInfo in windowInfos) {
                if ([containerInfo[(id)kCGWindowOwnerPID] intValue] != pid.intValue ||
                    [containerInfo[(id)kCGWindowLayer] intValue] != 0) {
                    continue;
                }
                NSNumber *containerID = containerInfo[(id)kCGWindowNumber];
                if (containerID.unsignedIntValue == winNum.unsignedIntValue) continue;
                NSDictionary *containerBoundsDict = containerInfo[(id)kCGWindowBounds];
                if (![containerBoundsDict isKindOfClass:[NSDictionary class]]) continue;
                CGRect containerBounds = CGRectMake([containerBoundsDict[@"X"] doubleValue],
                                                    [containerBoundsDict[@"Y"] doubleValue],
                                                    [containerBoundsDict[@"Width"] doubleValue],
                                                    [containerBoundsDict[@"Height"] doubleValue]);
                BOOL fullyContained = CGRectGetMinX(windowBounds) >= CGRectGetMinX(containerBounds) &&
                    CGRectGetMinY(windowBounds) >= CGRectGetMinY(containerBounds) &&
                    CGRectGetMaxX(windowBounds) <= CGRectGetMaxX(containerBounds) &&
                    CGRectGetMaxY(windowBounds) <= CGRectGetMaxY(containerBounds);
                BOOL containerIsLarger = CGRectGetWidth(containerBounds) > CGRectGetWidth(windowBounds) ||
                    CGRectGetHeight(containerBounds) > CGRectGetHeight(windowBounds);
                if (fullyContained && containerIsLarger) {
                    hiddenSurfaceInsideWindow = YES;
                    break;
                }
            }
            if (hiddenSurfaceInsideWindow) continue;
        }
        RingEntry *entry = [RingEntry new];
        entry.application = app;
        entry.windowTitle = title.length ? title : (app.localizedName ?: @"Window");
        entry.tabTitle = @"";
        entry.icon = app.icon ?: [NSImage imageNamed:NSImageNameApplicationIcon];
        entry.windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
        entry.windowBounds = windowBounds;
        if ([app.bundleIdentifier isEqualToString:@"com.apple.finder"] && entry.windowID != kCGNullWindowID && finderPaths[@(entry.windowID)]) {
            entry.folderPath = finderPaths[@(entry.windowID)];
        }
        [entries addObject:entry];
    }

    // Reconcile AX-enriched entries with CG-only window records after collecting
    // both sources. Distinct tabs in one browser window share a CG window ID and
    // bounds, so keep them when their tab indices differ.
    NSMutableArray<RingEntry *> *mergedEntries = [NSMutableArray arrayWithCapacity:entries.count];
    for (RingEntry *candidate in entries) {
        NSUInteger duplicateIndex = NSNotFound;
        for (NSUInteger i = 0; i < mergedEntries.count; i++) {
            RingEntry *existing = mergedEntries[i];
            BOOL sameProcess = existing.application && candidate.application &&
                existing.application.processIdentifier == candidate.application.processIdentifier;
            BOOL sameWindowID = existing.windowID != kCGNullWindowID &&
                existing.windowID == candidate.windowID;
            BOOL hasBounds = existing.windowBounds.size.width > 0 && existing.windowBounds.size.height > 0 &&
                candidate.windowBounds.size.width > 0 && candidate.windowBounds.size.height > 0;
            BOOL sameBounds = sameProcess && hasBounds &&
                fabs(existing.windowBounds.origin.x - candidate.windowBounds.origin.x) <= 4.0 &&
                fabs(existing.windowBounds.origin.y - candidate.windowBounds.origin.y) <= 4.0 &&
                fabs(existing.windowBounds.size.width - candidate.windowBounds.size.width) <= 4.0 &&
                fabs(existing.windowBounds.size.height - candidate.windowBounds.size.height) <= 4.0;
            NSString *existingCGTitle = cgTitlesByWindowID[@(existing.windowID)] ?: existing.windowTitle;
            NSString *candidateCGTitle = cgTitlesByWindowID[@(candidate.windowID)] ?: candidate.windowTitle;
            BOOL differentNamedWindows = existingCGTitle.length > 0 && candidateCGTitle.length > 0 &&
                [existingCGTitle localizedCaseInsensitiveCompare:candidateCGTitle] != NSOrderedSame;
            if (!sameWindowID && (!sameBounds || differentNamedWindows)) continue;

            BOOL separateTabs = sameProcess && existing.isTab && candidate.isTab &&
                ((existing.chromeTabID.length && candidate.chromeTabID.length &&
                  ![existing.chromeTabID isEqualToString:candidate.chromeTabID]) ||
                 existing.tabIndex != candidate.tabIndex);
            if (separateTabs) continue;
            duplicateIndex = i;
            break;
        }
        if (duplicateIndex == NSNotFound) {
            [mergedEntries addObject:candidate];
            continue;
        }

        RingEntry *existing = mergedEntries[duplicateIndex];
        NSUInteger existingAXScore = (existing.accessibilityWindowObject ? 1 : 0) +
            (existing.accessibilityTabObject ? 2 : 0);
        NSUInteger candidateAXScore = (candidate.accessibilityWindowObject ? 1 : 0) +
            (candidate.accessibilityTabObject ? 2 : 0);
        BOOL preferCandidate = candidateAXScore > existingAXScore ||
            (candidateAXScore == existingAXScore && candidate.isTab && !existing.isTab);
        RingEntry *winner = preferCandidate ? candidate : existing;
        RingEntry *discarded = preferCandidate ? existing : candidate;
        if (!winner.accessibilityWindowObject) winner.accessibilityWindowObject = discarded.accessibilityWindowObject;
        if (!winner.accessibilityTabObject) winner.accessibilityTabObject = discarded.accessibilityTabObject;
        if (!winner.thumbnailData) winner.thumbnailData = discarded.thumbnailData;
        if (!winner.thumbnail) winner.thumbnail = discarded.thumbnail;
        if (!winner.folderPath.length) winner.folderPath = discarded.folderPath;
        if (!winner.windowTitle.length) winner.windowTitle = discarded.windowTitle;
        if (!winner.tabTitle.length) winner.tabTitle = discarded.tabTitle;
        if (!winner.tabAXTitle.length) winner.tabAXTitle = discarded.tabAXTitle;
        if (!winner.tabURL.length) winner.tabURL = discarded.tabURL;
        if (!winner.chromeWindowID.length) winner.chromeWindowID = discarded.chromeWindowID;
        if (!winner.chromeTabID.length) winner.chromeTabID = discarded.chromeTabID;
        if (!winner.isTab && discarded.isTab) {
            winner.isTab = YES;
            winner.tabIndex = discarded.tabIndex;
        }
        if (winner.windowID == kCGNullWindowID) winner.windowID = discarded.windowID;
        if (winner.windowBounds.size.width <= 0 || winner.windowBounds.size.height <= 0) {
            winner.windowBounds = discarded.windowBounds;
        }
        winner.isSelectedTab = winner.isSelectedTab || discarded.isSelectedTab;
        if (preferCandidate) mergedEntries[duplicateIndex] = candidate;
    }
    entries = mergedEntries;

    // CGWindowList can expose an untitled Chrome surface beside the browser's
    // real window. Drop that placeholder only when this Chrome process also
    // has at least one genuinely titled window or tab; preserve a sole blank
    // Chrome window so it remains selectable.
    NSMutableSet<NSNumber *> *chromePIDsWithRealTitles = [NSMutableSet set];
    for (RingEntry *entry in entries) {
        if (![entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"]) continue;
        BOOL hasRealWindowTitle = entry.windowTitle.length > 0 &&
            ![entry.windowTitle isEqualToString:@"Google Chrome"];
        if (entry.tabTitle.length > 0 || hasRealWindowTitle) {
            [chromePIDsWithRealTitles addObject:@(entry.application.processIdentifier)];
        }
    }
    NSMutableArray<RingEntry *> *filteredEntries = [NSMutableArray arrayWithCapacity:entries.count];
    for (RingEntry *entry in entries) {
        BOOL isChrome = [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"];
        BOOL isUntitledNonTabChromeWindow = isChrome && !entry.isTab && !entry.tabTitle.length &&
            (!entry.windowTitle.length || [entry.windowTitle isEqualToString:@"Google Chrome"]);
        BOOL chromeHasAnotherRealTitle = isChrome &&
            [chromePIDsWithRealTitles containsObject:@(entry.application.processIdentifier)];
        if (isUntitledNonTabChromeWindow && chromeHasAnotherRealTitle) continue;
        [filteredEntries addObject:entry];
    }
    entries = filteredEntries;
    [entries sortUsingComparator:^NSComparisonResult(RingEntry *a, RingEntry *b) {
        NSComparisonResult appOrder = [a.application.localizedName localizedCaseInsensitiveCompare:b.application.localizedName];
        if (appOrder != NSOrderedSame) return appOrder;
        NSString *aTitle = a.folderPath.length ? a.folderPath : (a.tabTitle.length ? a.tabTitle : a.windowTitle);
        NSString *bTitle = b.folderPath.length ? b.folderPath : (b.tabTitle.length ? b.tabTitle : b.windowTitle);
        return [aTitle localizedCaseInsensitiveCompare:bTitle];
    }];
    return entries;
}

// Failed windows (for example minimized/off-Space windows) are retried with
// exponential backoff. All callers mutate these dictionaries on the main queue.
static BOOL thumbnailCaptureIsCoolingDown(NSNumber *windowKey) {
    @synchronized ([NSMutableDictionary class]) {
        if (!g_thumbnailFailureUntil) return NO;
        return g_thumbnailFailureUntil[windowKey].doubleValue > NSDate.timeIntervalSinceReferenceDate;
    }
}

static void recordThumbnailCaptureFailure(NSNumber *windowKey) {
    @synchronized ([NSMutableDictionary class]) {
        if (!g_thumbnailFailureUntil) g_thumbnailFailureUntil = [NSMutableDictionary dictionary];
        if (!g_thumbnailFailureCount) g_thumbnailFailureCount = [NSMutableDictionary dictionary];
        NSUInteger failures = g_thumbnailFailureCount[windowKey].unsignedIntegerValue + 1;
        g_thumbnailFailureCount[windowKey] = @(failures);
        NSTimeInterval delay = MIN(4.0, pow(2.0, MIN(failures - 1, 2)));
        g_thumbnailFailureUntil[windowKey] = @(NSDate.timeIntervalSinceReferenceDate + delay);
    }
}

static void recordThumbnailCaptureSuccess(NSNumber *windowKey) {
    @synchronized ([NSMutableDictionary class]) {
        [g_thumbnailFailureUntil removeObjectForKey:windowKey];
        [g_thumbnailFailureCount removeObjectForKey:windowKey];
    }
}

static const size_t kThumbnailPixelWidth = 640;
static const size_t kThumbnailPixelHeight = 384;

static NSData *encodedThumbnailFromCGImage(CGImageRef image) {
    if (!image) return nil;
    NSMutableData *data = [NSMutableData data];
    // This Mac cannot write WebP via ImageIO. JPEG keeps the cache small.
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, (__bridge CFStringRef)@"public.jpeg", 1, NULL);
    if (!dest) return nil;
    NSDictionary *props = @{
        (id)kCGImageDestinationLossyCompressionQuality: @0.72
    };
    CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return (ok && data.length > 64) ? data : nil;
}

static NSImage *thumbnailImageFromData(NSData *data) {
    if (!data.length) return nil;
    NSImage *image = [[NSImage alloc] initWithData:data];
    if (!image || image.size.width < 8) return nil;
    image.cacheMode = NSImageCacheNever;
    return image;
}

static NSImage *resolvedThumbnail(RingEntry *entry) {
    if (entry.thumbnail) return entry.thumbnail;
    if (!entry.thumbnailData.length) return nil;
    entry.thumbnail = thumbnailImageFromData(entry.thumbnailData);
    return entry.thumbnail;
}

static void applyThumbnailDataToEntry(RingEntry *entry, NSData *data) {
    if (!entry) return;
    entry.thumbnailData = data;
    if (data.length && atomic_load(&g_ringOverlayVisible)) {
        entry.thumbnail = thumbnailImageFromData(data);
    } else {
        entry.thumbnail = nil;
    }
}

static void releaseDecodedThumbnails(void) {
    for (RingEntry *entry in g_windowEntries) {
        entry.thumbnail = nil;
    }
}

static CGImageRef captureWindowImage(SCWindow *window) {
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
    SCStreamConfiguration *configuration = [SCStreamConfiguration new];
    configuration.width = kThumbnailPixelWidth;
    configuration.height = kThumbnailPixelHeight;
    configuration.showsCursor = NO;
    configuration.ignoreShadowsSingleWindow = YES;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block CGImageRef result = NULL;
    __block _Atomic(bool) timedOut = false;
    [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
                              completionHandler:^(CGImageRef image, NSError *error) {
        if (image && !atomic_load(&timedOut)) {
            result = (CGImageRef)CFRetain(image);
        } else if (error && !atomic_load(&timedOut)) {
            NSLog(@"ScreenCaptureKit thumbnail failed: %@", error.localizedDescription);
        }
        dispatch_semaphore_signal(semaphore);
    }];
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(800 * NSEC_PER_MSEC))) != 0) {
        atomic_store(&timedOut, true);
    }
    return result;
}

static NSString *chromeActiveTabID(NSString *windowID) {
    if (!validChromeID(windowID)) return nil;
    NSString *source = [NSString stringWithFormat:
        @"tell application \"Google Chrome\"\n"
         "set targetWindow to first window whose id is \"%@\"\n"
         "return (id of active tab of targetWindow) as text\n"
         "end tell", windowID];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = [script executeAndReturnError:&error];
    return error ? nil : result.stringValue;
}

static void finishChromePrefetch(BOOL succeeded) {
    @synchronized ([NSMutableDictionary class]) {
        g_chromePrefetchRetryAfter = succeeded ? 0 : NSProcessInfo.processInfo.systemUptime + 3.0;
    }
    atomic_store(&g_chromePrefetchActive, false);
}

static NSURL *chromeArtworkURL(NSString *tabURL) {
    NSString *videoID = youtubeVideoIDFromURL(tabURL);
    if (!videoID.length) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID]];
}

static void scheduleChromeTabArtwork(NSArray<RingEntry *> *entries) {
    if (!entries.count) return;
    if (!g_tabArtworkQueue) {
        g_tabArtworkQueue = dispatch_queue_create("touchpad.ring.chrome-artwork", DISPATCH_QUEUE_SERIAL);
    }
    @synchronized ([NSMutableDictionary class]) {
        if (!g_tabArtworkCache) g_tabArtworkCache = [NSMutableDictionary dictionary];
        if (!g_tabArtworkRequests) g_tabArtworkRequests = [NSMutableSet set];
    }
    for (RingEntry *entry in entries) {
        if (![entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"]) continue;
        NSString *tabKey = tabThumbnailKey(entry);
        NSURL *artworkURL = chromeArtworkURL(entry.tabURL);
        if (!artworkURL || !tabKey.length) continue;
        NSString *artKey = chromeArtworkCacheKey(entry.tabURL);
        NSString *requestURL = normalizedTabURL(entry.tabURL);
        @synchronized ([NSMutableDictionary class]) {
            NSData *shared = (artKey.length && g_urlArtworkCache) ? g_urlArtworkCache[artKey] : nil;
            if (shared && !g_tabArtworkCache[tabKey] && !g_tabThumbnailCache[tabKey]) {
                g_tabArtworkCache[tabKey] = shared;
                applyThumbnailDataToEntry(entry, shared);
            }
            if (g_tabThumbnailCache[tabKey] || g_tabArtworkCache[tabKey] ||
                [g_tabArtworkRequests containsObject:tabKey]) continue;
            [g_tabArtworkRequests addObject:tabKey];
        }
        NSString *requestKey = [tabKey copy];
        NSString *requestArtKey = [artKey copy];
        dispatch_async(g_tabArtworkQueue, ^{
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:artworkURL];
            request.timeoutInterval = 6.0;
            request.cachePolicy = NSURLRequestReturnCacheDataElseLoad;
            NSURLSessionDataTask *task =
                [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSData *stored = nil;
                NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                    ? (NSHTTPURLResponse *)response : nil;
                if (!error && data.length && http.statusCode == 200) {
                    NSImage *probe = [[NSImage alloc] initWithData:data];
                    if (probe && probe.size.width >= 16) stored = data;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    @synchronized ([NSMutableDictionary class]) {
                        [g_tabArtworkRequests removeObject:requestKey];
                        if (stored.length) {
                            if (requestArtKey.length) {
                                if (!g_urlArtworkCache) g_urlArtworkCache = [NSMutableDictionary dictionary];
                                g_urlArtworkCache[requestArtKey] = stored;
                            }
                            BOOL urlStillMatches = NO;
                            for (RingEntry *current in g_windowEntries) {
                                if (![tabThumbnailKey(current) isEqualToString:requestKey]) continue;
                                if (![normalizedTabURL(current.tabURL) isEqualToString:requestURL]) continue;
                                urlStillMatches = YES;
                                if (!g_tabThumbnailCache[requestKey]) {
                                    g_tabArtworkCache[requestKey] = stored;
                                    applyThumbnailDataToEntry(current, stored);
                                }
                            }
                            if (urlStillMatches && g_ringView) {
                                g_ringView.entries = g_windowEntries;
                                [g_ringView setNeedsDisplay:YES];
                            }
                            if (urlStillMatches) NSLog(@"[Chrome thumbnails] artwork %@", requestKey);
                        }
                    }
                });
            }];
            [task resume];
        });
    }
}

static void scheduleChromeBackgroundPrefetch(NSArray<RingEntry *> *entries) {
    if (atomic_load(&g_gestureActive) || atomic_load(&g_activeTouchCount) != 0 ||
        atomic_load(&g_chromePrefetchActive) || chromePrefetchIsHeld() ||
        !CGPreflightScreenCaptureAccess()) return;

    RingEntry *target = nil;
    @synchronized ([NSMutableDictionary class]) {
        if (NSProcessInfo.processInfo.systemUptime < g_chromePrefetchRetryAfter) return;
        for (RingEntry *entry in entries) {
            if (!entry.isTab || !entry.chromeWindowID.length || !entry.chromeTabID.length ||
                entry.isSelectedTab || entry.windowID == kCGNullWindowID ||
                entry.application.isActive ||
                g_tabThumbnailCache[tabThumbnailKey(entry)] ||
                g_tabArtworkCache[tabThumbnailKey(entry)]) continue;
            target = entry;
            break;
        }
    }
    if (!target || atomic_exchange(&g_chromePrefetchActive, true)) return;
    if (!g_chromePrefetchQueue) {
        g_chromePrefetchQueue = dispatch_queue_create("touchpad.ring.chrome-prefetch", DISPATCH_QUEUE_SERIAL);
    }

    NSString *windowID = [target.chromeWindowID copy];
    NSString *tabID = [target.chromeTabID copy];
    NSString *tabKey = [tabThumbnailKey(target) copy];
    CGWindowID cgWindowID = target.windowID;
    NSRunningApplication *chrome = target.application;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO
                                                completionHandler:^(SCShareableContent *content, NSError *error) {
        if (error || !content) {
            finishChromePrefetch(NO);
            return;
        }
        SCWindow *shareableWindow = nil;
        for (SCWindow *candidate in content.windows) {
            if (candidate.windowID == cgWindowID) { shareableWindow = candidate; break; }
        }
        if (!shareableWindow) {
            finishChromePrefetch(NO);
            return;
        }
        SCWindow *windowToCapture = shareableWindow;
        dispatch_async(g_chromePrefetchQueue, ^{
            @autoreleasepool {
                NSData *thumbnailData = nil;
                NSString *originalTabID = nil;
                BOOL switched = NO;
                @synchronized ([NSAppleScript class]) {
                    if (!chrome.isActive && !atomic_load(&g_gestureActive) &&
                        atomic_load(&g_activeTouchCount) == 0 && !chromePrefetchIsHeld()) {
                        originalTabID = chromeActiveTabID(windowID);
                        if (originalTabID.length && ![originalTabID isEqualToString:tabID]) {
                            switched = setChromeActiveTab(windowID, tabID);
                            @try {
                                if (switched) {
                                    usleep(250000); // Let Chrome render the newly selected tab.
                                    if (!chrome.isActive && !atomic_load(&g_gestureActive) &&
                                        atomic_load(&g_activeTouchCount) == 0 &&
                                        !chromePrefetchIsHeld() &&
                                        [chromeActiveTabID(windowID) isEqualToString:tabID]) {
                                        CGImageRef image = captureWindowImage(windowToCapture);
                                        if (image) {
                                            if ([chromeActiveTabID(windowID) isEqualToString:tabID]) {
                                                thumbnailData = encodedThumbnailFromCGImage(image);
                                            }
                                            CGImageRelease(image);
                                        }
                                    }
                                }
                            } @finally {
                                // Never restore if the user picked a tab while this
                                // capture was in flight. That restore was sending
                                // every card back to the previously active tab.
                                if (!chromePrefetchIsHeld() &&
                                    [chromeActiveTabID(windowID) isEqualToString:tabID]) {
                                    if (!setChromeActiveTab(windowID, originalTabID)) {
                                        NSLog(@"[Chrome thumbnails] Could not restore tab in window %@", windowID);
                                    }
                                }
                            }
                        }
                    }
                }
                if (thumbnailData) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        BOOL didCache = NO;
                        @synchronized ([NSMutableDictionary class]) {
                            for (RingEntry *entry in g_windowEntries) {
                                if ([tabThumbnailKey(entry) isEqualToString:tabKey]) {
                                    g_tabThumbnailCache[tabKey] = thumbnailData;
                                    g_tabLastCaptured[tabKey] = @(NSProcessInfo.processInfo.systemUptime);
                                    applyThumbnailDataToEntry(entry, thumbnailData);
                                    didCache = YES;
                                }
                            }
                            if (g_ringView) {
                                g_ringView.entries = g_windowEntries;
                                [g_ringView setNeedsDisplay:YES];
                            }
                        }
                        if (didCache) NSLog(@"[Chrome thumbnails] prefetched %@", tabKey);
                        finishChromePrefetch(didCache);
                    });
                } else {
                    finishChromePrefetch(NO);
                }
            }
        });
    }];
}

static void releaseTabThumbnailRequest(RingEntry *entry) {
    NSString *key = tabThumbnailKey(entry);
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized ([NSMutableDictionary class]) { [g_tabThumbnailRequests removeObject:key]; }
    });
}

static void captureTabThumbnails(NSArray<SCWindow *> *shareableWindows, NSArray<RingEntry *> *tabEntries) {
    if (!tabEntries.count) return;
    if (!g_tabCaptureQueue) g_tabCaptureQueue = dispatch_queue_create("touchpad.ring.tab-thumbnails", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_tabCaptureQueue, ^{
        NSMutableDictionary<NSNumber *, NSMutableArray<RingEntry *> *> *entriesByWindow = [NSMutableDictionary dictionary];
        for (RingEntry *entry in tabEntries) {
            if ([entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"]) {
                // Chrome uses the shared windowID cache in capturePendingThumbnails.
                releaseTabThumbnailRequest(entry);
                continue;
            }
            NSMutableArray *group = entriesByWindow[@(entry.windowID)];
            if (!group) entriesByWindow[@(entry.windowID)] = group = [NSMutableArray array];
            [group addObject:entry];
        }
        for (NSNumber *windowID in entriesByWindow) {
            if (thumbnailCaptureIsCoolingDown(windowID)) {
                for (RingEntry *entry in entriesByWindow[windowID]) releaseTabThumbnailRequest(entry);
                continue;
            }
            SCWindow *shareableWindow = nil;
            for (SCWindow *candidate in shareableWindows) {
                if (candidate.windowID == windowID.unsignedIntValue) { shareableWindow = candidate; break; }
            }
            NSArray<RingEntry *> *group = entriesByWindow[windowID];
            if (!shareableWindow) {
                dispatch_async(dispatch_get_main_queue(), ^{ recordThumbnailCaptureFailure(windowID); });
                for (RingEntry *entry in group) releaseTabThumbnailRequest(entry);
                continue;
            }
            RingEntry *selectedEntry = nil;
            for (RingEntry *entry in group) if (entry.isSelectedTab) { selectedEntry = entry; break; }
            if (!selectedEntry) selectedEntry = group.firstObject;
            if (!selectedEntry) {
                for (RingEntry *entry in group) releaseTabThumbnailRequest(entry);
                continue;
            }

            NSMutableDictionary<NSString *, NSData *> *capturedThumbnails = [NSMutableDictionary dictionary];
            CGImageRef capturedImage = captureWindowImage(shareableWindow);
            if (capturedImage) {
                NSData *encoded = encodedThumbnailFromCGImage(capturedImage);
                if (encoded) capturedThumbnails[tabThumbnailKey(selectedEntry)] = encoded;
                CGImageRelease(capturedImage);
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized ([NSMutableDictionary class]) {
                if (capturedThumbnails.count) {
                    recordThumbnailCaptureSuccess(windowID);
                    for (NSString *key in capturedThumbnails) {
                        NSData *thumbnail = capturedThumbnails[key];
                        g_tabThumbnailCache[key] = thumbnail;
                        if (!g_tabLastCaptured) g_tabLastCaptured = [NSMutableDictionary dictionary];
                        g_tabLastCaptured[key] = @(NSProcessInfo.processInfo.systemUptime);
                        for (RingEntry *current in g_windowEntries) {
                            if (current.isTab && [tabThumbnailKey(current) isEqualToString:key]) {
                                applyThumbnailDataToEntry(current, thumbnail);
                            }
                        }
                    }
                } else {
                    recordThumbnailCaptureFailure(windowID);
                }
                for (RingEntry *entry in group) {
                    [g_tabThumbnailRequests removeObject:tabThumbnailKey(entry)];
                }
                if (g_ringView) {
                    g_ringView.entries = g_windowEntries;
                    [g_ringView setNeedsDisplay:YES];
                }
                }
            });
        }
    });
}

static void capturePendingThumbnails(NSArray<RingEntry *> *entries,
                                    NSDictionary<NSNumber *, NSData *> *thumbnailSnapshot,
                                    NSDictionary<NSString *, NSData *> *tabThumbnailSnapshot,
                                    NSDictionary<NSString *, NSNumber *> *tabLastCapturedSnapshot,
                                    NSTimeInterval retryAfter) {
    if (atomic_load(&g_gestureActive)) return;
    @synchronized ([NSMutableDictionary class]) {
    NSMutableSet<NSNumber *> *wantedIDs = [NSMutableSet set];
    NSMutableSet<NSNumber *> *wantedChromeIDs = [NSMutableSet set];
    NSMutableArray<RingEntry *> *wantedTabs = [NSMutableArray array];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;

    NSCountedSet<NSNumber *> *tabWindowIDCounts = [NSCountedSet set];
    for (RingEntry *entry in entries) {
        if (entry.isTab && entry.windowID != kCGNullWindowID) {
            [tabWindowIDCounts addObject:@(entry.windowID)];
        }
    }

    for (RingEntry *entry in entries) {
        NSNumber *key = @(entry.windowID);
        if (entry.isTab) {
            BOOL isChromeTab = [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"];
            if (isChromeTab) {
                if (!entry.isSelectedTab) continue;
                NSString *tabKey = tabThumbnailKey(entry);
                NSTimeInterval lastAttempt = g_chromeWindowLastCapture[key].doubleValue;
                NSTimeInterval lastCaptured = tabLastCapturedSnapshot[tabKey].doubleValue;
                BOOL captureDue = !tabThumbnailSnapshot[tabKey] || (now - lastCaptured >= 8.0);
                if (entry.windowID != kCGNullWindowID && captureDue &&
                    now - lastAttempt >= 0.5 &&
                    !thumbnailCaptureIsCoolingDown(key) &&
                    ![g_thumbnailRequests containsObject:key]) {
                    [wantedIDs addObject:key];
                    [wantedChromeIDs addObject:key];
                }
                continue;
            }

            NSString *tabKey = tabThumbnailKey(entry);
            BOOL isUniqueTabWindow = (entry.windowID != kCGNullWindowID && [tabWindowIDCounts countForObject:key] == 1);
            BOOL canCapture = entry.isSelectedTab || isUniqueTabWindow;
            NSTimeInterval lastCap = tabLastCapturedSnapshot[tabKey] ? tabLastCapturedSnapshot[tabKey].doubleValue : 0;
            if (canCapture && entry.windowID != kCGNullWindowID &&
                !thumbnailCaptureIsCoolingDown(key) &&
                ![g_tabThumbnailRequests containsObject:tabKey]) {
                BOOL shouldCapture = NO;
                if (!tabThumbnailSnapshot[tabKey]) {
                    shouldCapture = YES;
                } else if (entry.isSelectedTab && (now - lastCap > 3.0)) {
                    shouldCapture = YES;
                }
                if (shouldCapture) {
                    [g_tabThumbnailRequests addObject:tabKey];
                    [wantedTabs addObject:entry];
                }
            }
        }
        if (!entry.isTab && entry.windowID != kCGNullWindowID && !thumbnailSnapshot[key] &&
                   !thumbnailCaptureIsCoolingDown(key) &&
                   ![g_thumbnailRequests containsObject:key]) {
            [wantedIDs addObject:key];
        }
    }
    if (!wantedIDs.count && !wantedTabs.count) return;
    if (retryAfter > NSDate.timeIntervalSinceReferenceDate) {
        for (RingEntry *entry in wantedTabs) [g_tabThumbnailRequests removeObject:tabThumbnailKey(entry)];
        return;
    }
    if (!g_chromeWindowLastCapture) g_chromeWindowLastCapture = [NSMutableDictionary dictionary];
    if (!g_chromeCaptureTabKeys) g_chromeCaptureTabKeys = [NSMutableDictionary dictionary];
    for (RingEntry *entry in entries) {
        if (entry.isTab && entry.isSelectedTab &&
            [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"] &&
            [wantedChromeIDs containsObject:@(entry.windowID)]) {
            g_chromeCaptureTabKeys[@(entry.windowID)] = tabThumbnailKey(entry);
            if (!g_chromeCaptureURLs) g_chromeCaptureURLs = [NSMutableDictionary dictionary];
            g_chromeCaptureURLs[@(entry.windowID)] = normalizedTabURL(entry.tabURL);
        }
    }
    for (NSNumber *windowKey in wantedChromeIDs) {
        g_chromeWindowLastCapture[windowKey] = @(now);
    }
    [g_thumbnailRequests unionSet:wantedIDs];
    if (!CGPreflightScreenCaptureAccess()) {
        static _Atomic(bool) didRequestCaptureAccess = false;
        if (!atomic_exchange(&didRequestCaptureAccess, true)) {
            CGRequestScreenCaptureAccess();
            NSLog(@"Screen Recording access requested once for Touchpad Switcher. Grant it in System Settings, then restart the app.");
        }
        @synchronized ([NSMutableDictionary class]) {
            [g_thumbnailRequests minusSet:wantedIDs];
            for (RingEntry *entry in wantedTabs) {
                [g_tabThumbnailRequests removeObject:tabThumbnailKey(entry)];
            }
        }
        return;
    }
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO
                                                completionHandler:^(SCShareableContent *content, NSError *error) {
        if (error || !content) {
            NSLog(@"ScreenCaptureKit could not list windows: %@", error.localizedDescription ?: @"no access");
            NSLog(@"Enable Screen Recording for the app that launches this test, then quit and restart it.");
            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized ([NSMutableDictionary class]) {
                g_shareableContentFailureCount++;
                NSTimeInterval delay = MIN(4.0, pow(2.0, MIN(g_shareableContentFailureCount - 1, 2)));
                g_shareableContentRetryAfter = NSDate.timeIntervalSinceReferenceDate + delay;
                [g_thumbnailRequests minusSet:wantedIDs];
                [g_chromeCaptureTabKeys removeObjectsForKeys:wantedChromeIDs.allObjects];
                for (NSNumber *windowKey in wantedIDs) recordThumbnailCaptureFailure(windowKey);
                for (RingEntry *entry in wantedTabs) {
                    recordThumbnailCaptureFailure(@(entry.windowID));
                    [g_tabThumbnailRequests removeObject:tabThumbnailKey(entry)];
                }
                }
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized ([NSMutableDictionary class]) {
                g_shareableContentFailureCount = 0;
                g_shareableContentRetryAfter = 0;
            }
        });
        NSMutableSet<NSNumber *> *foundIDs = [NSMutableSet set];
        for (SCWindow *window in content.windows) {
            NSNumber *windowKey = @(window.windowID);
            if (![wantedIDs containsObject:windowKey]) continue;
            [foundIDs addObject:windowKey];
            SCStreamConfiguration *configuration = [SCStreamConfiguration new];
            configuration.width = kThumbnailPixelWidth;
            configuration.height = kThumbnailPixelHeight;
            configuration.showsCursor = NO;
            configuration.ignoreShadowsSingleWindow = YES;
            [SCScreenshotManager captureImageWithFilter:[[SCContentFilter alloc] initWithDesktopIndependentWindow:window]
                                       configuration:configuration
                                       completionHandler:^(CGImageRef image, NSError *captureError) {
                if (!image) {
                    if (captureError) NSLog(@"Could not capture window %u: %@", window.windowID, captureError.localizedDescription);
                    dispatch_async(dispatch_get_main_queue(), ^{
                    @synchronized ([NSMutableDictionary class]) {
                    recordThumbnailCaptureFailure(windowKey);
                    [g_thumbnailRequests removeObject:windowKey];
                    [g_chromeCaptureTabKeys removeObjectForKey:windowKey];
                    }
                    });
                    return;
                }
                NSData *thumbnail = encodedThumbnailFromCGImage(image);
                if (!thumbnail) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                    @synchronized ([NSMutableDictionary class]) {
                    recordThumbnailCaptureFailure(windowKey);
                    [g_thumbnailRequests removeObject:windowKey];
                    [g_chromeCaptureTabKeys removeObjectForKey:windowKey];
                    [g_chromeCaptureURLs removeObjectForKey:windowKey];
                    }
                    });
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    @synchronized ([NSMutableDictionary class]) {
                    NSString *chromeTabKey = g_chromeCaptureTabKeys[windowKey];
                    NSString *capturedURL = g_chromeCaptureURLs[windowKey];
                    [g_chromeCaptureTabKeys removeObjectForKey:windowKey];
                    [g_chromeCaptureURLs removeObjectForKey:windowKey];
                    BOOL chromeTabStillSelected = NO;
                    BOOL chromeURLStillMatches = capturedURL == nil;
                    if (chromeTabKey.length) {
                        for (RingEntry *current in g_windowEntries) {
                            if (current.isSelectedTab && current.windowID == window.windowID &&
                                [tabThumbnailKey(current) isEqualToString:chromeTabKey]) {
                                chromeTabStillSelected = YES;
                                chromeURLStillMatches = [normalizedTabURL(current.tabURL) isEqualToString:capturedURL ?: @""];
                                break;
                            }
                        }
                    }
                    if (chromeTabKey.length && (!chromeTabStillSelected || !chromeURLStillMatches)) {
                        // A tab changed or navigated during the asynchronous screenshot.
                        [g_thumbnailRequests removeObject:windowKey];
                        g_chromeWindowLastCapture[windowKey] = @0;
                        return;
                    }
                    recordThumbnailCaptureSuccess(windowKey);
                    g_thumbnailCache[windowKey] = thumbnail;
                    [g_thumbnailRequests removeObject:windowKey];
                    if (chromeTabKey.length) {
                        BOOL firstCaptureForTab = g_tabThumbnailCache[chromeTabKey] == nil;
                        g_tabThumbnailCache[chromeTabKey] = thumbnail;
                        g_tabLastCaptured[chromeTabKey] = @(NSProcessInfo.processInfo.systemUptime);
                        if (firstCaptureForTab) NSLog(@"[Chrome thumbnails] cached %@", chromeTabKey);
                    }
                    for (RingEntry *entry in g_windowEntries) {
                        BOOL isChromeTab = entry.isTab &&
                            [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"];
                        BOOL chromeTabMatchesCapture = isChromeTab && chromeTabKey.length &&
                            [tabThumbnailKey(entry) isEqualToString:chromeTabKey];
                        if (entry.windowID == window.windowID && (!entry.isTab || chromeTabMatchesCapture)) {
                            applyThumbnailDataToEntry(entry, thumbnail);
                        }
                    }
                    if (g_ringView) {
                        g_ringView.entries = g_windowEntries;
                        [g_ringView setNeedsDisplay:YES];
                    }
                    }
                });
            }];
        }
        NSMutableSet<NSNumber *> *missingIDs = [wantedIDs mutableCopy];
        [missingIDs minusSet:foundIDs];
        if (missingIDs.count) dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized ([NSMutableDictionary class]) {
            for (NSNumber *windowKey in missingIDs) recordThumbnailCaptureFailure(windowKey);
            [g_thumbnailRequests minusSet:missingIDs];
            [g_chromeCaptureTabKeys removeObjectsForKeys:wantedChromeIDs.allObjects];
            }
        });
        captureTabThumbnails(content.windows, wantedTabs);
    }];
    }
}

static void schedulePendingThumbnailCapture(NSArray<RingEntry *> *entries) {
    if (atomic_load(&g_gestureActive)) return;
    if (!g_thumbnailPlanningQueue) {
        g_thumbnailPlanningQueue = dispatch_queue_create("touchpad.ring.thumbnail-planning", DISPATCH_QUEUE_SERIAL);
    }
    NSArray<RingEntry *> *entrySnapshot = [entries copy];
    dispatch_async(g_thumbnailPlanningQueue, ^{
        if (atomic_load(&g_gestureActive)) return;
        NSDictionary<NSNumber *, NSData *> *thumbnailSnapshot = nil;
        NSDictionary<NSString *, NSData *> *tabThumbnailSnapshot = nil;
        NSDictionary<NSString *, NSNumber *> *tabLastCapturedSnapshot = nil;
        NSTimeInterval retryAfter = 0;
        @synchronized ([NSMutableDictionary class]) {
            thumbnailSnapshot = [g_thumbnailCache copy];
            tabThumbnailSnapshot = [g_tabThumbnailCache copy];
            tabLastCapturedSnapshot = [g_tabLastCaptured copy];
            retryAfter = g_shareableContentRetryAfter;
        }
        if (!atomic_load(&g_gestureActive)) {
            capturePendingThumbnails(entrySnapshot, thumbnailSnapshot, tabThumbnailSnapshot,
                                     tabLastCapturedSnapshot, retryAfter);
        }
    });
}

static void pruneThumbnailCaches(NSArray<RingEntry *> *entries) {
    @synchronized ([NSMutableDictionary class]) {
    if (!g_windowLastSeen) g_windowLastSeen = [NSMutableDictionary dictionary];
    if (!g_tabLastSeen) g_tabLastSeen = [NSMutableDictionary dictionary];
    if (!g_windowPIDMap) g_windowPIDMap = [NSMutableDictionary dictionary];
    if (!g_tabPIDMap) g_tabPIDMap = [NSMutableDictionary dictionary];

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    const NSTimeInterval kThumbnailGracePeriod = 3.0; // Reduced from 15.0s to 3.0s

    NSMutableSet<NSNumber *> *liveWindowIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *liveTabKeys = [NSMutableSet set];
    for (RingEntry *entry in entries) {
        if (entry.windowID != kCGNullWindowID) {
            NSNumber *wKey = @(entry.windowID);
            [liveWindowIDs addObject:wKey];
            g_windowLastSeen[wKey] = @(now);
            if (entry.application) {
                g_windowPIDMap[wKey] = @(entry.application.processIdentifier);
            }
        }
        if (entry.isTab) {
            NSString *tKey = tabThumbnailKey(entry);
            [liveTabKeys addObject:tKey];
            g_tabLastSeen[tKey] = @(now);
            if (entry.application) {
                g_tabPIDMap[tKey] = @(entry.application.processIdentifier);
            }
        }
    }

    CFArrayRef onScreenWindows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    NSMutableSet<NSNumber *> *onScreenWindowIDs = [NSMutableSet set];
    if (onScreenWindows) {
        CFIndex count = CFArrayGetCount(onScreenWindows);
        for (CFIndex i = 0; i < count; i++) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(onScreenWindows, i);
            NSNumber *wid = info[(id)kCGWindowNumber];
            if (wid) [onScreenWindowIDs addObject:wid];
        }
        CFRelease(onScreenWindows);
    }

    if (g_thumbnailCache) {
        NSMutableArray<NSNumber *> *keysToRemove = [NSMutableArray array];
        for (NSNumber *key in g_thumbnailCache.allKeys) {
            if ([liveWindowIDs containsObject:key]) continue;

            NSNumber *pidNum = g_windowPIDMap[key];
            BOOL processTerminated = NO;
            if (pidNum) {
                NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pidNum.intValue];
                if (!app || app.isTerminated) processTerminated = YES;
            }

            BOOL windowClosed = ![onScreenWindowIDs containsObject:key];

            NSNumber *lastSeenNum = g_windowLastSeen[key];
            NSTimeInterval lastSeen = lastSeenNum ? lastSeenNum.doubleValue : 0;
            BOOL expired = (now - lastSeen) > kThumbnailGracePeriod;

            // Remove immediately if process terminated or window closed; else when grace period expired
            if (processTerminated || windowClosed || expired) {
                [keysToRemove addObject:key];
            }
        }
        for (NSNumber *key in keysToRemove) {
            [g_thumbnailCache removeObjectForKey:key];
            [g_windowLastSeen removeObjectForKey:key];
            [g_windowPIDMap removeObjectForKey:key];
        }
    }

    if (g_tabThumbnailCache) {
        NSMutableArray<NSString *> *keysToRemove = [NSMutableArray array];
        for (NSString *key in g_tabThumbnailCache.allKeys) {
            NSNumber *pidNum = g_tabPIDMap[key];
            BOOL processTerminated = NO;
            if (pidNum) {
                NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pidNum.intValue];
                processTerminated = !app || app.isTerminated;
            }
            if (processTerminated) {
                [keysToRemove addObject:key];
                continue;
            }
            if (![liveTabKeys containsObject:key]) {
                // Chrome AppleScript can miss a tab during a transient scan.
                // Keep its last image briefly so the next scan can restore it.
                BOOL isChromeTab = [key containsString:@":chrome:"];
                NSTimeInterval lastSeen = g_tabLastSeen[key].doubleValue;
                if (!isChromeTab || now - lastSeen > 1.5) [keysToRemove addObject:key];
                continue;
            }
        }
        for (NSString *key in keysToRemove) {
            [g_tabThumbnailCache removeObjectForKey:key];
            [g_tabArtworkCache removeObjectForKey:key];
            [g_tabCachedURL removeObjectForKey:key];
            [g_tabLastSeen removeObjectForKey:key];
            [g_tabPIDMap removeObjectForKey:key];
            [g_tabLastCaptured removeObjectForKey:key];
        }
    }

    if (g_thumbnailRequests) [g_thumbnailRequests intersectSet:liveWindowIDs];
    if (g_tabThumbnailRequests) [g_tabThumbnailRequests intersectSet:liveTabKeys];
    }
}

static NSInteger directionIndex(double dx, double dy, NSInteger count) {
    if (count <= 0) return -1;
    double angle = atan2(dy, dx);
    double bestAlignment = -DBL_MAX;
    NSInteger bestIndex = -1;
    for (NSInteger i = 0; i < count; i++) {
        double itemAngle = (double)visualItemAngle(i, (NSUInteger)count);
        double alignment = cos(angle - itemAngle);
        if (alignment > bestAlignment) {
            bestAlignment = alignment;
            bestIndex = i;
        }
    }
    return bestIndex;
}

static NSInteger selectionForLift(void) {
    if (g_selectedIndex >= 0) return g_selectedIndex;
    NSInteger count = atomic_load(&g_windowEntryCount);
    double len = hypot(g_motionAccumX, g_motionAccumY);
    if (count <= 0 || len < 0.005) return -1;
    return directionIndex(g_motionAccumX, g_motionAccumY, count);
}

static NSInteger stableDirectionIndex(double dx, double dy, NSInteger count, NSInteger currentIndex) {
    NSInteger candidate = directionIndex(dx, dy, count);
    if (candidate < 0 || currentIndex < 0 || candidate == currentIndex) return candidate;
    double movementAngle = atan2(dy, dx);
    double currentAngle = (double)visualItemAngle(currentIndex, (NSUInteger)count);
    double angularDistance = fabs(remainder(movementAngle - currentAngle, 2.0 * M_PI));
    // Sticky through a bit past the midpoint, but never wider than the gap to
    // the next card. A fixed extra angle blocked neighbors when N was large.
    double halfSector = M_PI / (double)MAX(count, 1);
    double switchBoundary = halfSector * 1.18;
    return angularDistance <= switchBoundary ? currentIndex : candidate;
}

static int ringTouchCallback(MTDeviceRef device, MTTouch *touches, int numTouches, double timestamp, int frame) {
    (void)device;
    (void)frame;
    @autoreleasepool {
        static BOOL suppressUntilFourFingerLift = NO;
        static double allFingersUpSince = -1.0;
        static BOOL liftCompletionScheduled = NO;
        static uint64_t fourFingerAbortGeneration = 0;
        int activeCount = 0;
        double sumX = 0.0, sumY = 0.0;
        for (int i = 0; i < numTouches; i++) {
            MTTouch *touch = &touches[i];
            if (touch->state == MTTouchStateTouching || touch->state == MTTouchStateMakeTouch) {
                activeCount++;
                sumX += touch->normalizedVector.position.x;
                sumY += touch->normalizedVector.position.y;
            }
        }
        atomic_store(&g_activeTouchCount, activeCount);

        if (activeCount >= 3) {
            uint64_t nowNanos = (uint64_t)(NSProcessInfo.processInfo.systemUptime * 1000000000.0);
            atomic_store(&g_scrollSuppressionUntilNanos, nowNanos + 350000000ULL);
            atomic_store(&g_scrollSuppressionActive, true);
        }

        BOOL gestureActive = atomic_load(&g_gestureActive);
        if (activeCount >= 4) {
            suppressUntilFourFingerLift = YES;
            allFingersUpSince = -1.0;
            liftCompletionScheduled = NO;
            if (gestureActive) {
                // Invalidate any pending normal lift completion so it cannot
                // activate the previously selected entry after a four-touch.
                fourFingerAbortGeneration = atomic_fetch_add(&g_gestureGeneration, 1) + 1;
                atomic_store(&g_gestureEnding, true);
                atomic_store(&g_gestureActive, false);
                uint64_t generation = fourFingerAbortGeneration;
                dispatch_async(dispatch_get_main_queue(), ^{ finishGesture(generation, -1); });
            }
            return 0;
        }

        if (suppressUntilFourFingerLift) {
            if (activeCount == 0) {
                if (allFingersUpSince < 0.0) allFingersUpSince = timestamp;
                else if ((timestamp - allFingersUpSince) >= 0.200) {
                    suppressUntilFourFingerLift = NO;
                    allFingersUpSince = -1.0;
                }
                return 0;
            }
            allFingersUpSince = -1.0;
            return 0;
        }

        if (!gestureActive && activeCount == 3) {
            double x = sumX / 3.0, y = sumY / 3.0;
            atomic_store(&g_gestureActive, true);
            atomic_store(&g_gestureEnding, false);
            allFingersUpSince = -1.0;
            liftCompletionScheduled = NO;
            g_previousX = x;
            g_previousY = y;
            g_motionAccumX = 0.0;
            g_motionAccumY = 0.0;
            g_selectedIndex = -1;
            CGEventRef cursorEvent = CGEventCreate(NULL);
            if (cursorEvent) {
                g_cursorAtGestureStart = CGEventGetLocation(cursorEvent);
                CFRelease(cursorEvent);
            }
            uint64_t generation = atomic_fetch_add(&g_gestureGeneration, 1) + 1;
            NSLog(@"[touch] three-finger gesture started");
            dispatch_async(dispatch_get_main_queue(), ^{ showRing(generation); });
        } else if (gestureActive && !atomic_load(&g_gestureEnding)) {
            // Keep the overlay and input suppression active while any of the
            // three fingers remain down. A temporary count of one or two must
            // not finish the selection and send later trackpad input to apps.
            BOOL shouldEnd = activeCount >= 4;
            if (activeCount == 0) {
                if (allFingersUpSince < 0.0) allFingersUpSince = timestamp;
                if (!liftCompletionScheduled) {
                    liftCompletionScheduled = YES;
                    uint64_t generation = atomic_load(&g_gestureGeneration);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        if (generation != atomic_load(&g_gestureGeneration) ||
                            !atomic_load(&g_gestureActive) || atomic_load(&g_activeTouchCount) != 0 ||
                            atomic_exchange(&g_gestureEnding, true)) return;
                        finishGesture(generation, selectionForLift());
                    });
                }
            } else {
                allFingersUpSince = -1.0;
                liftCompletionScheduled = NO;
            }

            if (shouldEnd) {
                atomic_store(&g_gestureEnding, true);
                NSInteger selection = (activeCount == 0 || activeCount < 3) ? selectionForLift() : -1;
                uint64_t generation = atomic_load(&g_gestureGeneration);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSInteger finalSelection = (fourFingerAbortGeneration == generation) ? -1 : selection;
                    finishGesture(generation, finalSelection);
                });
            } else if (activeCount == 3) {
                double x = sumX / 3.0, y = sumY / 3.0;
                g_motionAccumX += x - g_previousX;
                g_motionAccumY += y - g_previousY;
                g_previousX = x;
                g_previousY = y;
                NSInteger count = atomic_load(&g_windowEntryCount);
                const double kFirstSelectTravel = count >= 8 ? 0.014 : 0.012;
                const double kChangeSelectTravel = count <= 5 ? 0.028 : (count <= 8 ? 0.018 : 0.012);
                const double kSelectionBias = count >= 8 ? 0.003 : 0.007;
                const double kAccumClamp = 0.050;
                double motionLength = hypot(g_motionAccumX, g_motionAccumY);
                NSInteger candidate = motionLength >= kFirstSelectTravel
                    ? stableDirectionIndex(g_motionAccumX, g_motionAccumY, count, g_selectedIndex) : -1;
                double requiredLength = g_selectedIndex < 0 ? kFirstSelectTravel : kChangeSelectTravel;
                NSInteger selection = candidate >= 0 && (candidate == g_selectedIndex || motionLength >= requiredLength)
                    ? candidate : -1;
                if (selection >= 0 && selection == g_selectedIndex) {
                    if (motionLength > kAccumClamp && motionLength > 0.0) {
                        double scale = kAccumClamp / motionLength;
                        g_motionAccumX *= scale;
                        g_motionAccumY *= scale;
                    }
                } else if (selection >= 0 && selection != g_selectedIndex) {
                    g_selectedIndex = selection;
                    double angle = (double)visualItemAngle(selection, (NSUInteger)MAX(count, 1));
                    g_motionAccumX = cos(angle) * kSelectionBias;
                    g_motionAccumY = sin(angle) * kSelectionBias;
                    fprintf(stderr, "[touch] selected entry %ld\n", (long)selection);
                    uint64_t generation = atomic_load(&g_gestureGeneration);
                    scheduleSelectionUpdate(generation, selection);
                }
            }
        }
    }
    return 0;
}

static void startMultitouchDevices(void) {
    if (g_devices) {
        for (CFIndex i = 0; i < CFArrayGetCount(g_devices); i++) {
            MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(g_devices, i);
            MTDeviceStop(device);
            MTUnregisterContactFrameCallback(device, ringTouchCallback);
        }
        CFRelease(g_devices);
        g_devices = NULL;
    }
    g_devices = MTDeviceCreateList();
    if (!g_devices || CFArrayGetCount(g_devices) == 0) {
        NSLog(@"[touch] No Multitouch devices found");
        return;
    }
    for (CFIndex i = 0; i < CFArrayGetCount(g_devices); i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(g_devices, i);
        MTRegisterContactFrameCallback(device, ringTouchCallback);
        MTDeviceStart(device, 0);
    }
    NSLog(@"[touch] listening on %ld trackpad device(s)", (long)CFArrayGetCount(g_devices));
}

@interface TouchpadWakeObserver : NSObject
@end
@implementation TouchpadWakeObserver
- (void)didWake:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[touch] wake: restarting trackpad listeners");
        startMultitouchDevices();
    });
}
@end

static TouchpadWakeObserver *g_wakeObserver;

static void handleSignal(int signalNumber) {
    (void)signalNumber;
    printf("\nStopping Touchpad Ring Test...\n");
    if (g_scanTimer) {
        dispatch_source_cancel(g_scanTimer);
        g_scanTimer = NULL;
    }
    if (g_devices) {
        for (CFIndex i = 0; i < CFArrayGetCount(g_devices); i++) {
            MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(g_devices, i);
            MTDeviceStop(device);
            MTUnregisterContactFrameCallback(device, ringTouchCallback);
        }
    }
    exit(0);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (!claimSingleInstance()) return 1;
        for (int i = 1; i < argc; i++) {
            (void)argv[i];
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        signal(SIGINT, handleSignal);
        signal(SIGTERM, handleSignal);
        BOOL accessibilityTrusted = AXIsProcessTrusted();
        BOOL listenAccess = CGPreflightListenEventAccess();
        // Run the input filter on its own loop so a slow AppKit/AX scan cannot
        // let a scroll event slip through before the selector is drawn.
        if (startScrollEventTap()) {
            NSLog(@"[input] Dedicated session scroll filter active; Accessibility=%d; Input Monitoring=%d",
                  accessibilityTrusted, listenAccess);
            printf("Scroll and mouse input are suppressed while the selector is open.\n");
        } else {
            fprintf(stderr,
                    "[input] Could not create scroll-filter event tap (Accessibility=%s, Input Monitoring=%s).\n",
                    accessibilityTrusted ? "granted" : "missing",
                    listenAccess ? "granted" : "missing");
            // The full-screen ring panel also consumes scrolling and mouse
            // input during a gesture. Avoid a recurring permission dialog.
            NSLog(@"[input] Using ring-panel input shield; session tap unavailable");
        }
        fflush(stdout);
        g_thumbnailCache = [NSMutableDictionary dictionary];
        g_tabThumbnailCache = [NSMutableDictionary dictionary];
        g_chromeWindowLastCapture = [NSMutableDictionary dictionary];
        g_chromeCaptureTabKeys = [NSMutableDictionary dictionary];
        g_thumbnailRequests = [NSMutableSet set];
        g_tabThumbnailRequests = [NSMutableSet set];
        g_tabLastCaptured = [NSMutableDictionary dictionary];
        g_tabArtworkCache = [NSMutableDictionary dictionary];
        g_urlArtworkCache = [NSMutableDictionary dictionary];
        g_tabCachedURL = [NSMutableDictionary dictionary];
        g_chromeCaptureURLs = [NSMutableDictionary dictionary];
        g_tabArtworkRequests = [NSMutableSet set];
        g_windowActivationQueue = dispatch_queue_create("touchpad.ring.window-activation", DISPATCH_QUEUE_SERIAL);
        g_windowEntries = collectOpenWindows();
        populateThumbnailsFromCache(g_windowEntries);
        atomic_store(&g_windowEntryCount, (int)g_windowEntries.count);
        if (g_thumbnailPreviewsEnabled) schedulePendingThumbnailCapture(g_windowEntries);
        if (g_thumbnailPreviewsEnabled) scheduleChromeBackgroundPrefetch(g_windowEntries);
        scheduleChromeTabArtwork(g_windowEntries);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ensureChromeAutomation(YES)) {
                NSArray<RingEntry *> *entries = collectOpenWindows();
                populateThumbnailsFromCache(entries);
                g_windowEntries = entries;
                atomic_store(&g_windowEntryCount, (int)entries.count);
                if (g_ringView) g_ringView.entries = entries;
                if (g_thumbnailPreviewsEnabled) schedulePendingThumbnailCapture(entries);
                if (g_thumbnailPreviewsEnabled) scheduleChromeBackgroundPrefetch(entries);
                scheduleChromeTabArtwork(entries);
                printf("Chrome Automation granted. Entries: %d\n", atomic_load(&g_windowEntryCount));
                fflush(stdout);
            }
        });
        printf("Touchpad Switcher: %d entries.\n", atomic_load(&g_windowEntryCount));
        for (RingEntry *entry in g_windowEntries) {
            NSString *desc = entry.folderPath.length ? entry.folderPath : (entry.tabTitle.length ? entry.tabTitle : entry.windowTitle);
            printf("  %s — %s\n", entry.application.localizedName.UTF8String ?: "Application",
                   desc.UTF8String ?: "Untitled");
        }
        printf("Place three fingers and move toward a direction to select. Lift to activate the selected window.\n");
        printf("Press Ctrl-C to stop. Three-finger drag should be disabled for a clean test.\n");
        fflush(stdout);
        startMultitouchDevices();
        if (!g_devices || CFArrayGetCount(g_devices) == 0) {
            fprintf(stderr, "[ERROR] No Multitouch devices found.\n");
            return 1;
        }
        g_wakeObserver = [TouchpadWakeObserver new];
        NSNotificationCenter *workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
        [workspaceCenter addObserver:g_wakeObserver
                            selector:@selector(didWake:)
                                name:NSWorkspaceDidWakeNotification
                              object:nil];
        [workspaceCenter addObserver:g_wakeObserver
                            selector:@selector(didWake:)
                                name:NSWorkspaceScreensDidWakeNotification
                              object:nil];
        g_windowScanQueue = dispatch_queue_create("touchpad.ring.window-scan", DISPATCH_QUEUE_SERIAL);
        g_scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_windowScanQueue);
        dispatch_source_set_timer(g_scanTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                  (uint64_t)(2.0 * NSEC_PER_SEC),
                                  (uint64_t)(100 * NSEC_PER_MSEC));
        dispatch_source_set_event_handler(g_scanTimer, ^{
            // Skip this tick if the user is gesturing or a previous scan has
            // not completed; never start a full AX/AppleScript pass mid-gesture.
            if (atomic_load(&g_gestureActive)) return;
            if (atomic_load(&g_isScanning)) return;
            atomic_store(&g_isScanning, true);
            if (atomic_load(&g_gestureActive)) {
                atomic_store(&g_isScanning, false);
                return;
            }
            @autoreleasepool {
                NSArray<RingEntry *> *entries = collectOpenWindows();
                pruneThumbnailCaches(entries);
                populateThumbnailsFromCache(entries);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!atomic_load(&g_gestureActive)) {
                        g_windowEntries = entries;
                        atomic_store(&g_windowEntryCount, (int)entries.count);
                        if (g_ringView) {
                            g_ringView.entries = entries;
                        }
                        if (g_thumbnailPreviewsEnabled) schedulePendingThumbnailCapture(entries);
                        if (g_thumbnailPreviewsEnabled) scheduleChromeBackgroundPrefetch(entries);
                        scheduleChromeTabArtwork(entries);
                    }
                    atomic_store(&g_isScanning, false);
                });
            }
        });
        dispatch_resume(g_scanTimer);
        [NSApp run];
    }
    return 0;
}
