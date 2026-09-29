// Experimental three-finger radial window switcher.
// A deliberate movement selects a window direction; lifting all three fingers activates it.

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import "ring_media.h"
#import "ring_favicons.h"
#import "ring_update.h"
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
#include <dlfcn.h>

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
extern int MTDeviceGetSensorSurfaceDimensions(MTDeviceRef, int *width, int *height);
// Exact window-server ID of an AX window (used by AltTab and yabai). Bounds
// cannot identify windows when Stage Manager shrinks them into its strip.
extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *identifier);
// Blur behind a window with an exact radius (used by iTerm2). The public
// NSVisualEffectView blur has a fixed strength.
typedef int CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
extern CGError CGSSetWindowBackgroundBlurRadius(CGSConnectionID connection, NSInteger windowNumber, int radius);

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
static void drawCardLabel(NSString *text, NSRect cardRect, BOOL truncateMiddle, CGFloat leading);
static CGFloat drawCardBadgeIcon(RingEntry *entry, NSRect cardRect);
static const CGFloat kCardBadgeIconSize = 40.0;
static NSImage *resolvedThumbnail(RingEntry *entry);
static void applyThumbnailDataToEntry(RingEntry *entry, NSData *data);
static void releaseDecodedThumbnails(void);
static NSString *tabThumbnailKey(RingEntry *entry);
static BOOL ensureChromeAutomation(BOOL askUser);
static void schedulePendingThumbnailCapture(NSArray<RingEntry *> *entries);
static void scheduleChromeBackgroundPrefetch(NSArray<RingEntry *> *entries);
static void refreshThumbnailsNow(pid_t onlyPID, NSTimeInterval minAge);
static void loadHiddenChromeTabs(uint64_t generation);
static void setRingPick(BOOL made, NSString *chromeWindowID);
static void scanWindowsNow(void);
static void noteChromeSelectionChanges(NSArray<RingEntry *> *entries);

@interface RingView : NSView
@property(nonatomic, copy) NSArray<RingEntry *> *entries;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic) NSPoint anchorPoint;
@property(nonatomic) CGFloat ringRadius;
@property(nonatomic, strong) NSView *pointerView;
@property(nonatomic, strong) CAShapeLayer *pointerArrow;
@property(nonatomic, weak) NSView *glowView;
@property(nonatomic) NSPoint lastPointer;
@property(nonatomic, strong) CALayer *focusLayer;
@property(nonatomic) NSInteger focusIndex;
- (void)movePointerTo:(NSPoint)ringPoint;
- (void)resetPointer;
- (void)resetSelectionVisuals;
@end

// Light in the direction of the fingers. It sits under the cards, reaches the
// edge of the screen and follows the finger direction smoothly, while the
// card selection moves in steps.
@interface SectorGlowView : NSView
- (void)pointAt:(CGFloat)angle width:(CGFloat)width center:(NSPoint)center;
- (void)hideAnimated:(BOOL)animated;
@end

// The first bit of motion already selects: past this tiny radius (in ring
// units, about half a millimeter of finger travel) the direction counts.
// Lifting before any motion still selects nothing.
static const double kPointerDeadZone = 0.05;
// Half the size of the center area in points: the selected app's icon lives
// there, the arrow rides on its edge and the light starts from it.
static const CGFloat kHubRadius = 56.0;
// The pointer stays inside the ring of cards; only its direction matters.
static const double kPointerReach = 0.80;

// Settings from the menu bar panel. Stored under one ID so the bare binary
// and the .app bundle share them; read from the scan, touch and main threads.
#define kSettingsID CFSTR("com.milev.touchpad-switcher")
typedef enum { CardTitlesAll = 0, CardTitlesFinderAndChrome = 1, CardTitlesNone = 2 } CardTitlesMode;
static _Atomic(int) g_settingCardTitles = CardTitlesAll;
static RingMediaOptions g_mediaOptions;   // main thread; the media module keeps its own copy
static _Atomic(bool) g_settingFinderTabsOneCard = true;
typedef enum { CardGroupingWindows = 0, CardGroupingApps = 1 } CardGrouping;
static _Atomic(int) g_settingCardGrouping = CardGroupingWindows;
static _Atomic(bool) g_settingHideMenuIcon = false;
static _Atomic(bool) g_settingSoundEffects = false;
// Mouse activation by holding the button and releasing it on a card. Off: one
// click opens the ring and a second click (or a left click) picks the card.
static _Atomic(bool) g_settingMouseHoldToSelect = true;
static _Atomic(bool) g_settingShowSiteIcons = true;   // Chrome tabs: the site's icon
static _Atomic(bool) g_settingShowAppIcons = true;    // other windows: the app's icon
static _Atomic(int) g_settingBlurRadius = 15;   // 0 turns the blur off
// -1 disables mouse activation. Values 2...31 are Quartz mouse button numbers
// (middle is 2, the usual side buttons 3 and 4); kMouseActivationKeyBase plus a
// key code is a recorded key, such as F18 sent by Logi Options+.
// kMouseActivationSwipeBack/Forward are the side buttons with Logi Options+'s
// default Back/Forward assignment, which arrive as a synthetic swipe.
static _Atomic(int) g_settingMouseButton = -1;
typedef enum { PointerStyleArrow = 0, PointerStyleDot = 1, PointerStyleHidden = 2 } PointerStyle;
static _Atomic(int) g_settingPointerStyle = PointerStyleHidden;
static NSSound *g_selectSound;
static NSSound *g_activateSound;

// Short clicks like the CS buy menu: one when the selection changes, one when
// the chosen window opens. Off unless turned on in the menu.
static void playRingSound(NSSound *sound) {
    if (!sound || !atomic_load(&g_settingSoundEffects)) return;
    [sound stop];
    [sound play];
}
static BOOL g_replacedRunningInstance = NO;

static BOOL shouldDrawCardLabel(RingEntry *entry) {
    int mode = atomic_load(&g_settingCardTitles);
    if (mode == CardTitlesNone) return NO;
    if (mode == CardTitlesAll) return YES;
    NSString *bundleID = entry.application.bundleIdentifier;
    return [bundleID isEqualToString:@"com.apple.finder"] || [bundleID isEqualToString:@"com.google.Chrome"];
}

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

// Direction of a card as seen on screen (the ring is an ellipse, so this is not
// the raw layout angle).
static CGFloat cardScreenAngle(NSInteger i, NSUInteger count) {
    CGFloat radiusX = 1.0, radiusY = 1.0;
    ringEllipseRadii(count, 1.0, &radiusX, &radiusY);
    CGFloat rawAngle = rawItemAngle(i, count);
    return (CGFloat)atan2(sin(rawAngle) * radiusY, cos(rawAngle) * radiusX);
}

// A card owns the directions up to halfway to each neighbor.
static void cardSector(NSInteger i, NSUInteger count, CGFloat *startAngle, CGFloat *endAngle) {
    CGFloat angle = cardScreenAngle(i, count);
    CGFloat counterClockwise = (CGFloat)M_PI_2, clockwise = (CGFloat)M_PI_2;
    if (count <= 1) {
        counterClockwise = clockwise = (CGFloat)M_PI;
    } else if (count > 2) {
        CGFloat toPrevious = (CGFloat)remainder(cardScreenAngle((i + count - 1) % count, count) - angle, 2.0 * M_PI);
        CGFloat toNext = (CGFloat)remainder(cardScreenAngle((i + 1) % count, count) - angle, 2.0 * M_PI);
        counterClockwise = (toPrevious > 0 ? toPrevious : toNext) / 2.0;
        clockwise = -(toPrevious > 0 ? toNext : toPrevious) / 2.0;
    }
    if (startAngle) *startAngle = angle - clockwise;
    if (endAngle) *endAngle = angle + counterClockwise;
}

@implementation SectorGlowView {
    CAGradientLayer *_gradient;   // radial: bright at the center, fading outward
    CAGradientLayer *_beam;       // conic mask: soft beam, turned by rotation
    CADisplayLink *_displayLink;
    CGPoint _target;              // unit vector toward the fingers
    CGPoint _point;               // where the light points now; shorter near the center
    CGPoint _speed;
    CGFloat _targetWidth;
    CGFloat _width;               // eases toward _targetWidth
    CGFloat _beamWidth;           // what the mask shows, widened near the center
    CGFloat _level;               // 0 hidden, 1 fully lit
    CFTimeInterval _lastFrame;
    NSPoint _center;
    CGFloat _glowRadius;
    BOOL _visible;
}

// The light points at a spot that moves in a straight line toward the new
// direction on a critically damped spring (no overshoot, about 0.15 s). A
// step to a neighbor looks like turning; a jump to the other side pulls the
// light back through the center, where it is short, dim and wide, and out
// again on the new side.
static const CGFloat kBeamSpring = 30.0;
static const CGFloat kBeamMaxWidth = 3.6;   // radians; a soft glow all around the hub

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    self.wantsLayer = YES;
    _gradient = [CAGradientLayer layer];
    _gradient.type = kCAGradientLayerRadial;
    // Brightest at the center, fading out toward the edge of the screen along
    // a smooth curve, so no ring shows where two straight segments would meet.
    NSMutableArray *colors = [NSMutableArray array], *locations = [NSMutableArray array];
    const int stops = 12;
    for (int i = 0; i <= stops; i++) {
        CGFloat t = (CGFloat)i / stops;
        CGFloat fade = (1.0 - t) * (1.0 - t);
        [colors addObject:(id)[NSColor colorWithCalibratedRed:0.24 + 0.36 * fade green:0.82 + 0.10 * fade
                                                         blue:1.0 alpha:0.55 * fade].CGColor];
        [locations addObject:@(t)];
    }
    _gradient.colors = colors;
    _gradient.locations = locations;
    _gradient.opacity = 0;
    _beam = [CAGradientLayer layer];
    _beam.type = kCAGradientLayerConic;
    _beam.startPoint = CGPointMake(0.5, 0.5);
    _beam.endPoint = CGPointMake(1.0, 0.5);
    _gradient.mask = _beam;
    [self.layer addSublayer:_gradient];
    return self;
}

- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }

// Beam centered on the conic gradient's half-way point. Its brightness follows
// a raised cosine from the middle to the edges, with no flat core: a flat core
// showed as two straight lines where the light was strongest.
- (void)setBeamWidth:(CGFloat)width {
    if (fabs(width - _beamWidth) < 0.002) return;
    _beamWidth = width;
    CGFloat edge = MIN(0.499, width * 0.85 / (2.0 * M_PI));
    const int stops = 16;
    NSMutableArray *colors = [NSMutableArray array], *locations = [NSMutableArray array];
    [colors addObject:(id)[NSColor colorWithCalibratedWhite:1.0 alpha:0.0].CGColor];
    [locations addObject:@0.0];
    for (int i = 0; i <= stops; i++) {
        CGFloat u = (CGFloat)i / stops * 2.0 - 1.0;          // -1 .. 1 across the beam
        CGFloat alpha = 0.5 * (1.0 + cos(M_PI * u));
        [colors addObject:(id)[NSColor colorWithCalibratedWhite:1.0 alpha:alpha].CGColor];
        [locations addObject:@(0.5 + u * edge)];
    }
    [colors addObject:(id)[NSColor colorWithCalibratedWhite:1.0 alpha:0.0].CGColor];
    [locations addObject:@1.0];
    _beam.colors = colors;
    _beam.locations = locations;
}

- (void)applyBeam {
    CGFloat length = MIN(1.0, hypot(_point.x, _point.y));
    CGFloat reach = length * length * (3.0 - 2.0 * length);   // smoothstep
    CGFloat angle = length > 0.001 ? (CGFloat)atan2(_point.y, _point.x) : 0;
    CGFloat viewWidth = MAX(1.0, NSWidth(self.bounds)), viewHeight = MAX(1.0, NSHeight(self.bounds));
    CGFloat radius = kHubRadius + (_glowRadius - kHubRadius) * (0.3 + 0.7 * reach);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // The beam's middle sits half a turn from the gradient's start direction.
    _beam.affineTransform = CGAffineTransformMakeRotation(angle - (CGFloat)M_PI);
    [self setBeamWidth:_width + (kBeamMaxWidth - _width) * (1.0 - reach)];
    _gradient.endPoint = CGPointMake((_center.x + radius) / viewWidth, (_center.y + radius) / viewHeight);
    _gradient.opacity = (float)(_level * (0.35 + 0.65 * reach));
    [CATransaction commit];
}

- (void)pointAt:(CGFloat)angle width:(CGFloat)width center:(NSPoint)center {
    _target = CGPointMake(cos(angle), sin(angle));
    _targetWidth = width;   // eases in with the frames below
    if (_visible) return;
    _visible = YES;

    // Crossing the center: the light that is still fading carries on toward
    // the new side instead of starting over.
    if (_level > 0.05 && NSEqualPoints(center, _center)) {
        [self startFrames];
        return;
    }

    // A new light grows out of the center toward its card.
    _center = center;
    _point = CGPointMake(_target.x * 0.15, _target.y * 0.15);
    _speed = CGPointZero;
    _width = width;
    _level = 1.0;
    CGFloat viewWidth = MAX(1.0, NSWidth(self.bounds)), viewHeight = MAX(1.0, NSHeight(self.bounds));
    _glowRadius = MAX(viewWidth, viewHeight) * 0.6;
    CGFloat side = hypot(viewWidth, viewHeight) * 2.0;   // covers the screen at any rotation
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_gradient removeAllAnimations];
    _gradient.frame = self.layer.bounds;
    _gradient.startPoint = CGPointMake(center.x / viewWidth, center.y / viewHeight);
    _beam.bounds = CGRectMake(0, 0, side, side);
    _beam.position = center;
    [CATransaction commit];
    [self applyBeam];
    [self startFrames];
}

- (void)startFrames {
    if (!_displayLink) {
        _displayLink = [self displayLinkWithTarget:self selector:@selector(stepBeam:)];
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    _lastFrame = 0;
    _displayLink.paused = NO;
}

// Each screen refresh moves the light toward the finger direction. The spring
// also smooths out the small shake of the finger data.
- (void)stepBeam:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    CGFloat dt = (CGFloat)(_lastFrame > 0 ? MIN(now - _lastFrame, 0.05) : 1.0 / 120.0);
    _lastFrame = now;
    // Small steps keep the spring stable when a frame comes late.
    for (CGFloat left = dt; left > 0; left -= 1.0 / 240.0) {
        CGFloat step = MIN(left, (CGFloat)(1.0 / 240.0));
        _speed.x += (kBeamSpring * kBeamSpring * (_target.x - _point.x) - 2.0 * kBeamSpring * _speed.x) * step;
        _speed.y += (kBeamSpring * kBeamSpring * (_target.y - _point.y) - 2.0 * kBeamSpring * _speed.y) * step;
        _point.x += _speed.x * step;
        _point.y += _speed.y * step;
    }
    // A card with a wider or narrower sector changes the width gradually.
    _width += (_targetWidth - _width) * (CGFloat)(1.0 - exp(-dt / 0.06));
    // Lighting up is quick; going out takes about a fifth of a second.
    CGFloat levelTarget = _visible ? 1.0 : 0.0;
    _level += (levelTarget - _level) * (CGFloat)(1.0 - exp(-dt / (_visible ? 0.05 : 0.07)));
    if (!_visible && _level < 0.01) {
        _level = 0;
        _displayLink.paused = YES;
    }
    [self applyBeam];
}

- (void)hideAnimated:(BOOL)animated {
    _visible = NO;
    if (animated && _level > 0) return;   // the frames fade it out
    _level = 0;
    _speed = CGPointZero;
    _displayLink.paused = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_gradient removeAllAnimations];
    _gradient.opacity = 0;
    [CATransaction commit];
}
@end

@implementation RingView
- (BOOL)isFlipped { return NO; }

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    return self;
}

// The drawn card, the same rectangle drawRect uses: a preview for windows with
// a picture and for Chrome tabs, a smaller icon card otherwise.
- (NSRect)cardRectForIndex:(NSInteger)index {
    NSUInteger count = self.entries.count;
    if (index < 0 || index >= (NSInteger)count) return NSZeroRect;
    CGFloat radiusX = self.ringRadius, radiusY = self.ringRadius;
    ringEllipseRadii(count, self.ringRadius, &radiusX, &radiusY);
    CGFloat cardWidth = safeCardWidthForRing(count, radiusX, radiusY, NSWidth(self.bounds));
    CGFloat previewWidth = cardWidth * 0.94;
    CGFloat rawAngle = rawItemAngle(index, count);
    NSPoint itemCenter = NSMakePoint(self.anchorPoint.x + cos(rawAngle) * radiusX,
                                     self.anchorPoint.y + sin(rawAngle) * radiusY);
    RingEntry *entry = self.entries[(NSUInteger)index];
    BOOL preview = entry.thumbnail || entry.thumbnailData.length ||
        [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"];
    if (preview) {
        CGFloat height = previewWidth * 0.60;
        return NSMakeRect(itemCenter.x - previewWidth / 2.0, itemCenter.y - height / 2.0, previewWidth, height);
    }
    CGFloat iconSize = MIN(140, MAX(54, cardWidth * 0.42));
    return NSInsetRect(NSMakeRect(itemCenter.x - iconSize / 2.0, itemCenter.y - iconSize / 2.0, iconSize, iconSize),
                       -8.0, -8.0);
}

// The selected card is a copy of it in its own layer, a little larger and
// outlined. It fades in on the new card while the previous one fades out and
// shrinks back, instead of an outline gliding from card to card.
static const CGFloat kSelectedCardScale = 1.08;

// The card exactly as drawRect draws it, as an image for the selection layer.
- (id)cardImageForIndex:(NSInteger)index rect:(NSRect)rect {
    CGFloat scale = self.window.backingScaleFactor ?: 2.0;
    size_t pixelsWide = (size_t)ceil(NSWidth(rect) * scale);
    size_t pixelsHigh = (size_t)ceil(NSHeight(rect) * scale);
    if (pixelsWide == 0 || pixelsHigh == 0) return nil;
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, pixelsWide, pixelsHigh, 8, 0, sRGB,
                                                (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(sRGB);
    if (!bitmap) return nil;
    CGContextScaleCTM(bitmap, scale, scale);
    CGContextTranslateCTM(bitmap, -NSMinX(rect), -NSMinY(rect));
    NSUInteger count = self.entries.count;
    CGFloat radiusX = self.ringRadius, radiusY = self.ringRadius;
    ringEllipseRadii(count, self.ringRadius, &radiusX, &radiusY);
    CGFloat cardWidth = safeCardWidthForRing(count, radiusX, radiusY, NSWidth(self.bounds));
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:NO];
    [self drawCardForEntry:self.entries[(NSUInteger)index]
                  atCenter:NSMakePoint(NSMidX(rect), NSMidY(rect))
                 cardWidth:cardWidth];
    [NSGraphicsContext restoreGraphicsState];
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    return CFBridgingRelease(image);
}

// Places the selection layer on its card and paints the card into it.
- (void)fillFocusLayer:(CALayer *)focus index:(NSInteger)index {
    NSRect rect = [self cardRectForIndex:index];
    focus.bounds = CGRectMake(0, 0, NSWidth(rect), NSHeight(rect));
    focus.position = CGPointMake(NSMidX(rect), NSMidY(rect));
    focus.contentsScale = self.window.backingScaleFactor ?: 2.0;
    focus.contents = [self cardImageForIndex:index rect:rect];
    CGPathRef outline = CGPathCreateWithRoundedRect(focus.bounds, 8.0, 8.0, NULL);
    focus.shadowPath = outline;
    CGPathRelease(outline);
}

- (void)updateFocusAnimated:(BOOL)animated {
    NSInteger index = self.selectedIndex;
    BOOL hasSelection = index >= 0 && index < (NSInteger)self.entries.count;
    if (hasSelection && self.focusLayer && self.focusIndex == index) return;

    CALayer *previous = self.focusLayer;
    self.focusLayer = nil;
    if (previous) {
        CALayer *shown = (CALayer *)previous.presentationLayer ?: previous;
        NSNumber *fromOpacity = @(shown.opacity);
        NSNumber *fromScale = [shown valueForKeyPath:@"transform.scale"] ?: @(kSelectedCardScale);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setCompletionBlock:^{ [previous removeFromSuperlayer]; }];
        [previous removeAllAnimations];
        previous.opacity = 0;
        previous.transform = CATransform3DIdentity;
        if (animated) {
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue = fromOpacity;
            fade.toValue = @0.0;
            CABasicAnimation *shrink = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            shrink.fromValue = fromScale;
            shrink.toValue = @1.0;
            CAAnimationGroup *leave = [CAAnimationGroup animation];
            leave.animations = @[fade, shrink];
            leave.duration = 0.16;
            leave.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [previous addAnimation:leave forKey:@"leave"];
        }
        [CATransaction commit];
    }
    if (!hasSelection) return;

    CALayer *focus = [CALayer layer];
    NSColor *accent = [NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:0.95];
    focus.contentsGravity = kCAGravityResize;
    focus.borderColor = accent.CGColor;
    focus.borderWidth = 2.5;
    focus.cornerRadius = 8.0;
    focus.shadowColor = accent.CGColor;
    focus.shadowOpacity = 0.9;
    focus.shadowRadius = 9.0;
    focus.shadowOffset = CGSizeZero;
    focus.zPosition = 5;   // above the cards, under the pointer
    [self fillFocusLayer:focus index:index];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    focus.transform = CATransform3DMakeScale(kSelectedCardScale, kSelectedCardScale, 1);
    [self.layer addSublayer:focus];
    if (animated) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @0.0;
        fade.toValue = @1.0;
        fade.duration = 0.16;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [focus addAnimation:fade forKey:@"fade"];
        CASpringAnimation *zoom = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
        zoom.fromValue = @1.0;
        zoom.toValue = @(kSelectedCardScale);
        zoom.stiffness = 320;
        zoom.damping = 24;
        zoom.duration = zoom.settlingDuration;
        [focus addAnimation:zoom forKey:@"zoom"];
    }
    [CATransaction commit];
    self.focusLayer = focus;
    self.focusIndex = index;
}

// A picture that arrived while the card is selected, or a card that changed
// size, is copied into the selection layer without animating it again.
- (void)refreshFocusContents {
    CALayer *focus = self.focusLayer;
    if (!focus) return;
    if (self.focusIndex != self.selectedIndex || self.focusIndex >= (NSInteger)self.entries.count) {
        [self updateFocusAnimated:NO];
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self fillFocusLayer:focus index:self.focusIndex];
    [CATransaction commit];
}

- (void)resetSelectionVisuals {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.focusLayer removeFromSuperlayer];
    self.focusLayer = nil;
    [CATransaction commit];
    [(SectorGlowView *)self.glowView hideAnimated:NO];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    if (_selectedIndex == selectedIndex) return;
    _selectedIndex = selectedIndex;
    // Cards no longer change when selected, only the hub icon does; the
    // outline and the light are layers.
    // The center icon with its shadow can reach about 1.2 hub radii out.
    CGFloat iconReach = kHubRadius * 1.2 + 16.0;
    [self setNeedsDisplayInRect:NSMakeRect(self.anchorPoint.x - iconReach, self.anchorPoint.y - iconReach,
                                           iconReach * 2.0, iconReach * 2.0)];
    [self updateFocusAnimated:YES];
    if (selectedIndex >= 0 && selectedIndex < (NSInteger)self.entries.count) {
        [self updateGlow];
        playRingSound(g_selectSound);
    } else {
        [(SectorGlowView *)self.glowView hideAnimated:YES];
    }
}

// The light points where the fingers point, as wide as the selected card's
// sector.
- (void)updateGlow {
    NSUInteger count = self.entries.count;
    NSInteger selectedIndex = self.selectedIndex;
    if (selectedIndex < 0 || selectedIndex >= (NSInteger)count) return;
    CGFloat startAngle = 0, endAngle = 0;
    cardSector(selectedIndex, count, &startAngle, &endAngle);
    NSPoint pointer = self.lastPointer;
    CGFloat angle = hypot(pointer.x, pointer.y) > 0.001 ? (CGFloat)atan2(pointer.y, pointer.x)
                                                        : (startAngle + endAngle) / 2.0;
    [(SectorGlowView *)self.glowView pointAt:angle width:endAngle - startAngle center:self.anchorPoint];
}

// The pointer (an arrow that turns to point away from the center, or a dot)
// is its own small layer. Following the fingers never redraws the thumbnails.
- (void)resetPointer {
    [self.pointerView removeFromSuperview];
    self.pointerView = nil;
    self.pointerArrow = nil;
}

- (void)movePointerTo:(NSPoint)ringPoint {
    if (!self.pointerView) {
        const CGFloat size = 40.0;
        NSView *holder = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size, size)];
        holder.wantsLayer = YES;
        CAShapeLayer *arrow = [CAShapeLayer layer];
        arrow.bounds = CGRectMake(-size / 2.0, -size / 2.0, size, size);
        arrow.position = CGPointMake(size / 2.0, size / 2.0);
        CGMutablePathRef path = CGPathCreateMutable();
        if (atomic_load(&g_settingPointerStyle) == PointerStyleDot) {
            CGPathAddEllipseInRect(path, NULL, CGRectMake(-8, -8, 16, 16));
        } else {
            CGPathMoveToPoint(path, NULL, 14, 0);
            CGPathAddLineToPoint(path, NULL, -9, 10);
            CGPathAddLineToPoint(path, NULL, -4, 0);
            CGPathAddLineToPoint(path, NULL, -9, -10);
            CGPathCloseSubpath(path);
        }
        arrow.path = path;
        CGPathRelease(path);
        arrow.fillColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.95].CGColor;
        arrow.strokeColor = [NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:1.0].CGColor;
        arrow.lineWidth = 1.5;
        arrow.lineJoin = kCALineJoinRound;
        arrow.shadowColor = [NSColor colorWithCalibratedRed:0.24 green:0.82 blue:1.0 alpha:1.0].CGColor;
        arrow.shadowOpacity = 0.8;
        arrow.shadowRadius = 6.0;
        arrow.shadowOffset = CGSizeZero;
        arrow.affineTransform = CGAffineTransformMakeRotation((CGFloat)M_PI_2);
        [holder.layer addSublayer:arrow];
        holder.hidden = atomic_load(&g_settingPointerStyle) == PointerStyleHidden;
        holder.layer.zPosition = 10;   // above the selection outline
        [self addSubview:holder];
        self.pointerView = holder;
        self.pointerArrow = arrow;
    }
    self.lastPointer = ringPoint;
    [self updateGlow];
    // At the very center there is no direction; start pointing up.
    CGFloat angle = hypot(ringPoint.x, ringPoint.y) > 0.001 ? (CGFloat)atan2(ringPoint.y, ringPoint.x) : (CGFloat)M_PI_2;
    // The arrow never hides the icon in the hub: it rides on the hub's edge
    // until the pointer moves further out.
    CGFloat distance = MAX(hypot(ringPoint.x, ringPoint.y) * self.ringRadius, kHubRadius + 16.0);
    NSSize size = self.pointerView.frame.size;
    [self.pointerView setFrameOrigin:NSMakePoint(self.anchorPoint.x + cos(angle) * distance - size.width / 2.0,
                                                 self.anchorPoint.y + sin(angle) * distance - size.height / 2.0)];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.pointerArrow.affineTransform = CGAffineTransformMakeRotation(angle);
    [CATransaction commit];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect selectedCard = [self cardRectForIndex:self.focusIndex];
    if (self.focusLayer && NSIntersectsRect(NSInsetRect(selectedCard, -30.0, -30.0), dirtyRect)) {
        // A picture that just arrived can change the selected card.
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshFocusContents]; });
    }
    NSRect bounds = self.bounds;
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

    NSInteger selectedIndex = self.selectedIndex;

    // The icon of the selected app in the center, on its own without a
    // circle behind it, so the choice is readable where the eye already is.
    CGFloat hubRadius = kHubRadius;
    if (selectedIndex >= 0 && selectedIndex < (NSInteger)count) {
        // A Chrome tab shows its site's icon here too, when site icons are on.
        RingEntry *selectedEntry = self.entries[(NSUInteger)selectedIndex];
        NSImage *siteIcon = [selectedEntry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"] &&
                            atomic_load(&g_settingShowSiteIcons) ? RingFaviconForURL(selectedEntry.tabURL) : nil;
        // App icons carry their own margin, site icons do not.
        CGFloat iconSize = siteIcon ? hubRadius * 1.25 : hubRadius * 1.8;
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext currentContext].imageInterpolation = NSImageInterpolationHigh;
        NSShadow *iconShadow = [NSShadow new];
        iconShadow.shadowBlurRadius = 12.0;
        iconShadow.shadowOffset = NSMakeSize(0, -2);
        iconShadow.shadowColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.55];
        [iconShadow set];
        [(siteIcon ?: selectedEntry.icon) drawInRect:NSMakeRect(center.x - iconSize / 2.0, center.y - iconSize / 2.0,
                                                                iconSize, iconSize)];
        [NSGraphicsContext restoreGraphicsState];
    }

    CGFloat cardWidth = safeCardWidthForRing(count, radiusX, radiusY, NSWidth(bounds));
    CGFloat previewWidth = cardWidth * 0.94;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat rawAngle = rawItemAngle(i, count);
        NSPoint itemCenter = NSMakePoint(center.x + cos(rawAngle) * radiusX,
                                         center.y + sin(rawAngle) * radiusY);
        CGFloat cardHeight = previewWidth * 0.60;
        NSRect cardArea = NSInsetRect(NSMakeRect(itemCenter.x - previewWidth / 2.0, itemCenter.y - cardHeight / 2.0,
                                                 previewWidth, cardHeight), -30.0, -30.0);
        if (!NSIntersectsRect(cardArea, dirtyRect)) continue;
        [self drawCardForEntry:self.entries[i] atCenter:itemCenter cardWidth:cardWidth];
    }
}

// One card around itemCenter: a preview for windows with a picture and for
// Chrome tabs, a smaller icon card otherwise.
- (void)drawCardForEntry:(RingEntry *)entry atCenter:(NSPoint)itemCenter cardWidth:(CGFloat)cardWidth {
    CGFloat previewWidth = cardWidth * 0.94;
    // The selection layer marks the selection; cards draw unselected.
    BOOL selected = NO;
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
        // Fill the card without stretching; trim the sides of wide windows
        // and the bottom of tall ones, so the title bar stays visible.
        NSSize imageSize = thumbnail.size;
        NSRect sourceRect = NSMakeRect(0, 0, imageSize.width, imageSize.height);
        CGFloat cardAspect = itemPreviewWidth / previewHeight;
        if (imageSize.width > 0 && imageSize.height > 0) {
            if (imageSize.width / imageSize.height > cardAspect) {
                sourceRect.size.width = imageSize.height * cardAspect;
                sourceRect.origin.x = (imageSize.width - sourceRect.size.width) / 2.0;
            } else {
                sourceRect.size.height = imageSize.width / cardAspect;
                sourceRect.origin.y = imageSize.height - sourceRect.size.height;
            }
        }
        [thumbnail drawInRect:previewRect
                     fromRect:sourceRect
                    operation:NSCompositingOperationSourceOver
                     fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];

        BOOL isFinderEntry = [entry.application.bundleIdentifier isEqualToString:@"com.apple.finder"];
        CGFloat badgeWidth = drawCardBadgeIcon(entry, previewRect);
        if (shouldDrawCardLabel(entry)) {
            drawCardLabel(cardLabelText(entry), previewRect, isFinderEntry && entry.folderPath.length > 0, badgeWidth);
        }

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
        NSImage *siteIcon = atomic_load(&g_settingShowSiteIcons) ? RingFaviconForURL(entry.tabURL) : nil;
        [(siteIcon ?: entry.icon) drawInRect:NSMakeRect(NSMinX(cardRect) + inset,
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
        if (shouldDrawCardLabel(entry)) {
            drawCardLabel(cardLabelText(entry), iconCardRect, isFinderIcon && entry.folderPath.length > 0, 0);
        }

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
@end

@interface RingPanel : NSPanel
@end
@implementation RingPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static RingPanel *g_panel;
static RingView *g_ringView;
static SectorGlowView *g_glowView;
static NSView *g_dimView;
static NSArray<RingEntry *> *g_windowEntries = @[];
static _Atomic(int) g_windowEntryCount = 0;
static CFMutableArrayRef g_devices = NULL;
static _Atomic(bool) g_gestureActive = false;
static _Atomic(bool) g_mouseGestureActive = false;
static _Atomic(bool) g_keyboardGestureActive = false;
static _Atomic(int) g_mouseGestureButton = -1;
static _Atomic(bool) g_mouseButtonLearning = false;
static _Atomic(int) g_learnedButtonAwaitingUp = -1;
static _Atomic(int) g_learnedKeyAwaitingUp = -1;
// Click mode: the ring stays open after the activation until the same button
// or a left click picks the card. A Logi Back/Forward swipe has no press
// duration, so it always works this way.
static _Atomic(bool) g_clickGestureActive = false;
static _Atomic(bool) g_swallowLeftMouseUp = false;
static _Atomic(int) g_swallowOtherMouseUp = -1;
// The swipe's direction is only known at its end, so its start is held back
// and posted again when the swipe turns out not to be the activation.
static CGEventRef g_heldSwipeBegin = NULL;
static _Atomic(bool) g_systemCursorHidden = false;
static _Atomic(bool) g_ringOverlayVisible = false;
static _Atomic(bool) g_scrollSuppressionActive = false;
static _Atomic(uint64_t) g_scrollSuppressionUntilNanos = 0;
static _Atomic(bool) g_suppressGestureMomentum = false;
static _Atomic(bool) g_gestureEnding = false;
static _Atomic(uint64_t) g_ringShownGeneration = 0;
static double g_previousX = 0.0;
static double g_previousY = 0.0;
// Virtual pointer in ring units: cards sit on the ellipse ringEllipseRadii(count, 1).
static double g_pointerX = 0.0;
static double g_pointerY = 0.0;
static double g_trackpadAspect = 0.68;
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
static NSMutableDictionary<NSNumber *, NSString *> *g_lastSelectedChromeTabKeys;
static NSMutableSet<NSString *> *g_chromeForceCaptureKeys;
static NSMutableSet<NSNumber *> *g_thumbnailRequests;
static NSMutableSet<NSString *> *g_tabThumbnailRequests;
static NSMutableDictionary<NSString *, NSNumber *> *g_tabLastCaptured;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_windowLastCaptured;
static NSMutableDictionary<NSString *, NSString *> *g_tabCachedURL;
static NSMutableDictionary<NSNumber *, NSString *> *g_chromeCaptureURLs;
static dispatch_queue_t g_liveCaptureQueue;
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
static NSPoint g_pendingPointer = {0, 0};
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
            g_replacedRunningInstance = YES;
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
        g_replacedRunningInstance = YES;
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

static void showRing(uint64_t generation);
static void moveRingPointer(double dx, double dy, NSInteger count);
static NSInteger pointerSelection(NSInteger count, NSInteger currentIndex);
static void scheduleSelectionUpdate(uint64_t generation, NSInteger selection, NSPoint pointer);
static void finishGesture(uint64_t generation, NSInteger selection);
enum {
    kMouseActivationLegacyF18 = 100,
    kMouseActivationKeyBase = 1000,
    kMouseActivationSwipeBack = 2001,
    kMouseActivationSwipeForward = 2002,
};
static const CGEventType kGestureEventType = (CGEventType)29;   // NSEventTypeGesture
static const CGKeyCode kEscapeKeyCode = 53;
static NSString *const kMouseButtonLearnedNotification = @"TouchpadSwitcherMouseButtonLearned";

static void persistMouseActivationSetting(int value) {
    atomic_store(&g_settingMouseButton, value);
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &value);
    CFPreferencesSetAppValue(CFSTR("MouseActivationButton"), number, kSettingsID);
    CFPreferencesAppSynchronize(kSettingsID);
    CFRelease(number);
}

static void hideSystemCursorForGesture(void) {
    if (!atomic_exchange(&g_systemCursorHidden, true)) {
        CGDisplayHideCursor(CGMainDisplayID());
    }
}

static void showSystemCursorAfterGesture(void) {
    if (atomic_exchange(&g_systemCursorHidden, false)) {
        CGDisplayShowCursor(CGMainDisplayID());
    }
}

static BOOL mouseButtonEvent(CGEventType type) {
    return type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp ||
           type == kCGEventOtherMouseDragged;
}

static void beginMouseGesture(CGEventRef event, int button) {
    if (atomic_load(&g_gestureActive) || atomic_load(&g_ringOverlayVisible)) return;
    atomic_store(&g_mouseGestureActive, true);
    atomic_store(&g_mouseGestureButton, button);
    atomic_store(&g_gestureActive, true);
    atomic_store(&g_gestureEnding, false);
    hideSystemCursorForGesture();
    g_pointerX = 0.0;
    g_pointerY = 0.0;
    g_selectedIndex = -1;
    g_cursorAtGestureStart = CGEventGetLocation(event);
    uint64_t generation = atomic_fetch_add(&g_gestureGeneration, 1) + 1;
    NSLog(@"[mouse] button %d gesture started", button + 1);
    dispatch_async(dispatch_get_main_queue(), ^{ showRing(generation); });
}

static void beginKeyboardGesture(CGEventRef event) {
    if (atomic_load(&g_gestureActive) || atomic_load(&g_ringOverlayVisible)) return;
    atomic_store(&g_keyboardGestureActive, true);
    atomic_store(&g_gestureActive, true);
    atomic_store(&g_gestureEnding, false);
    hideSystemCursorForGesture();
    g_pointerX = 0.0;
    g_pointerY = 0.0;
    g_selectedIndex = -1;
    g_cursorAtGestureStart = CGEventGetLocation(event);
    uint64_t generation = atomic_fetch_add(&g_gestureGeneration, 1) + 1;
    NSLog(@"[mouse] key gesture started");
    dispatch_async(dispatch_get_main_queue(), ^{ showRing(generation); });
}

// Logi Options+ posts its Back/Forward button actions as a swipe from its own
// agent; trackpad gestures come from the Window Server (pid 0). Returns the
// swipe's phase and, once it ends, the activation value of its direction.
static BOOL logiSwipe(CGEventRef event, CGEventType type, NSEventPhase *phase, int *activation) {
    if (type != kGestureEventType) return NO;
    if (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) == 0) return NO;
    NSEvent *swipe = [NSEvent eventWithCGEvent:event];
    if (swipe.type != NSEventTypeSwipe) return NO;
    *phase = swipe.phase;
    // A positive deltaX is a swipe to the left, which AppKit treats as Back.
    *activation = swipe.deltaX > 0 ? kMouseActivationSwipeBack
        : swipe.deltaX < 0 ? kMouseActivationSwipeForward : -1;
    return YES;
}

static void releaseHeldSwipeBegin(CGEventTapProxy proxy, BOOL post) {
    if (!g_heldSwipeBegin) return;
    if (post) CGEventTapPostEvent(proxy, g_heldSwipeBegin);
    CFRelease(g_heldSwipeBegin);
    g_heldSwipeBegin = NULL;
}

static void finishMouseDrivenGesture(NSInteger selection) {
    atomic_store(&g_mouseGestureActive, false);
    atomic_store(&g_clickGestureActive, false);
    atomic_store(&g_mouseGestureButton, -1);
    atomic_store(&g_gestureEnding, true);
    uint64_t generation = atomic_load(&g_gestureGeneration);
    dispatch_async(dispatch_get_main_queue(), ^{ finishGesture(generation, selection); });
}

static void updateMouseGesture(CGEventRef event) {
    // Quartz deltas are screen points and positive Y points down. Roughly 80
    // points of travel reaches the cards, matching the short trackpad motion.
    double dx = CGEventGetIntegerValueField(event, kCGMouseEventDeltaX) / 1000.0;
    double dy = -CGEventGetIntegerValueField(event, kCGMouseEventDeltaY) / 1000.0;
    moveRingPointer(dx, dy, atomic_load(&g_windowEntryCount));
    NSInteger selection = pointerSelection(atomic_load(&g_windowEntryCount), g_selectedIndex);
    if (selection != g_selectedIndex) g_selectedIndex = selection;
    scheduleSelectionUpdate(atomic_load(&g_gestureGeneration), g_selectedIndex,
                            NSMakePoint(g_pointerX, g_pointerY));
    // An event tap can consume the movement while still letting the Window
    // Server advance the visible cursor on some mouse drivers. Pin it to the
    // press location after reading the raw deltas used by the ring.
    CGWarpMouseCursorPosition(g_cursorAtGestureStart);
    CGAssociateMouseAndMouseCursorPosition(true);
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
    int configuredButton = atomic_load(&g_settingMouseButton);
    int eventButton = mouseButtonEvent(type)
        ? (int)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) : -1;
    CGKeyCode keyCode = (type == kCGEventKeyDown || type == kCGEventKeyUp)
        ? (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) : UINT16_MAX;
    BOOL keyRepeat = type == kCGEventKeyDown &&
        CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
    NSEventPhase swipePhase = NSEventPhaseNone;
    int swipeActivation = -1;
    if (logiSwipe(event, type, &swipePhase, &swipeActivation)) {
        BOOL watching = atomic_load(&g_mouseButtonLearning) ||
            configuredButton == kMouseActivationSwipeBack ||
            configuredButton == kMouseActivationSwipeForward;
        if (!watching) return event;
        if (swipePhase == NSEventPhaseBegan) {
            releaseHeldSwipeBegin(proxy, YES);
            g_heldSwipeBegin = (CGEventRef)CFRetain(event);
            return NULL;
        }
        if (swipeActivation == -1) {
            releaseHeldSwipeBegin(proxy, YES);
            return event;
        }
        if (atomic_exchange(&g_mouseButtonLearning, false)) {
            releaseHeldSwipeBegin(proxy, NO);
            persistMouseActivationSetting(swipeActivation);
            NSLog(@"[mouse] learned activation %d", swipeActivation);
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:kMouseButtonLearnedNotification
                                  object:nil
                                userInfo:@{@"button": @(swipeActivation)}];
            });
            return NULL;
        }
        if (swipeActivation != configuredButton) {
            releaseHeldSwipeBegin(proxy, YES);
            return event;
        }
        releaseHeldSwipeBegin(proxy, NO);
        if (atomic_load(&g_clickGestureActive)) {
            finishMouseDrivenGesture(g_selectedIndex);
        } else if (!atomic_load(&g_gestureActive)) {
            beginMouseGesture(event, configuredButton);
            if (atomic_load(&g_mouseGestureActive)) atomic_store(&g_clickGestureActive, true);
        }
        return NULL;
    }
    if (type == kCGEventLeftMouseUp && atomic_exchange(&g_swallowLeftMouseUp, false)) {
        return NULL;
    }
    if (type == kCGEventOtherMouseUp && eventButton >= 0 &&
        atomic_compare_exchange_strong(&g_swallowOtherMouseUp, &(int){eventButton}, -1)) {
        return NULL;
    }
    if (atomic_load(&g_clickGestureActive)) {
        if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged ||
            type == kCGEventOtherMouseDragged) {
            updateMouseGesture(event);
            return NULL;
        }
        if (type == kCGEventOtherMouseDown && eventButton == atomic_load(&g_mouseGestureButton)) {
            atomic_store(&g_swallowOtherMouseUp, eventButton);
            finishMouseDrivenGesture(g_selectedIndex);
            return NULL;
        }
        if (type == kCGEventLeftMouseDown) {
            atomic_store(&g_swallowLeftMouseUp, true);
            finishMouseDrivenGesture(g_selectedIndex);
            return NULL;
        }
        if (type == kCGEventKeyDown && keyCode == kEscapeKeyCode) {
            finishMouseDrivenGesture(-1);
            return NULL;
        }
    }
    // While recording, the next mouse button or key press (for example the
    // shortcut Logi Options+ sends for a side button) becomes the activation.
    // Escape cancels recording.
    BOOL learnable = type == kCGEventOtherMouseDown || (type == kCGEventKeyDown && !keyRepeat);
    if (learnable && atomic_exchange(&g_mouseButtonLearning, false)) {
        int learned = -1;
        if (type == kCGEventOtherMouseDown) {
            learned = eventButton;
            atomic_store(&g_learnedButtonAwaitingUp, eventButton);
        } else {
            atomic_store(&g_learnedKeyAwaitingUp, keyCode);
            if (keyCode != kEscapeKeyCode) learned = kMouseActivationKeyBase + keyCode;
        }
        if (learned != -1) {
            persistMouseActivationSetting(learned);
            NSLog(@"[mouse] learned activation %d", learned);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:kMouseButtonLearnedNotification
                              object:nil
                            userInfo:@{@"button": @(learned)}];
        });
        return NULL;
    }
    if (type == kCGEventOtherMouseUp &&
        eventButton == atomic_load(&g_learnedButtonAwaitingUp)) {
        atomic_store(&g_learnedButtonAwaitingUp, -1);
        return NULL;
    }
    if (type == kCGEventKeyUp && keyCode == atomic_load(&g_learnedKeyAwaitingUp)) {
        atomic_store(&g_learnedKeyAwaitingUp, -1);
        return NULL;
    }
    int configuredKey = configuredButton >= kMouseActivationKeyBase &&
        configuredButton < kMouseActivationSwipeBack
        ? configuredButton - kMouseActivationKeyBase : -1;
    if (configuredKey >= 0 && type == kCGEventKeyDown && keyCode == configuredKey) {
        if (!keyRepeat && !atomic_load(&g_gestureActive)) beginKeyboardGesture(event);
        return NULL;
    }
    if (atomic_load(&g_keyboardGestureActive)) {
        if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged ||
            type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged) {
            updateMouseGesture(event);
        } else if (type == kCGEventKeyUp && keyCode == configuredKey) {
            atomic_store(&g_keyboardGestureActive, false);
            atomic_store(&g_gestureEnding, true);
            uint64_t generation = atomic_load(&g_gestureGeneration);
            NSInteger selection = g_selectedIndex;
            dispatch_async(dispatch_get_main_queue(), ^{ finishGesture(generation, selection); });
        }
        return NULL;
    }
    if (configuredButton >= 2 && configuredButton < kMouseActivationKeyBase &&
        type == kCGEventOtherMouseDown &&
        eventButton == configuredButton && !atomic_load(&g_gestureActive)) {
        beginMouseGesture(event, configuredButton);
        return NULL;
    }
    if (atomic_load(&g_mouseGestureActive) && !atomic_load(&g_clickGestureActive)) {
        if (type == kCGEventMouseMoved || type == kCGEventOtherMouseDragged) {
            updateMouseGesture(event);
        } else if (type == kCGEventOtherMouseUp &&
                   eventButton == atomic_load(&g_mouseGestureButton)) {
            if (atomic_load(&g_settingMouseHoldToSelect)) {
                finishMouseDrivenGesture(g_selectedIndex);
            } else {
                atomic_store(&g_clickGestureActive, true);   // stays open until the next click
            }
        }
        return NULL;
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
                                         CGEventMaskBit(kCGEventOtherMouseDragged) |
                                         CGEventMaskBit(kCGEventKeyDown) |
                                         CGEventMaskBit(kCGEventKeyUp) |
                                         CGEventMaskBit(kGestureEventType);
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
    // Backdrop (blur or plain dimming), the direction light, then the cards.
    NSRect contentFrame = NSMakeRect(0, 0, NSWidth(screen.frame), NSHeight(screen.frame));
    NSView *content = [[NSView alloc] initWithFrame:contentFrame];
    content.wantsLayer = YES;
    g_dimView = [[NSView alloc] initWithFrame:contentFrame];
    g_dimView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    g_dimView.wantsLayer = YES;
    [content addSubview:g_dimView];
    g_glowView = [[SectorGlowView alloc] initWithFrame:contentFrame];
    g_glowView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:g_glowView];
    g_ringView = [[RingView alloc] initWithFrame:contentFrame];
    g_ringView.wantsLayer = YES;
    g_ringView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    g_ringView.glowView = g_glowView;
    g_ringView.entries = g_windowEntries;
    g_ringView.selectedIndex = -1;
    [content addSubview:g_ringView];
    g_panel.contentView = content;
}

// The window server blurs what is behind the panel on the GPU, so the blur
// costs no drawing in this process.
static void setPanelBlur(int radius) {
    if (g_panel) CGSSetWindowBackgroundBlurRadius(CGSMainConnectionID(), g_panel.windowNumber, radius);
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
    if (count <= 3) {
        // With three cards or fewer the full-screen ring left a wide empty
        // middle. Pull the cards in until they keep a clear gap to each other
        // and to the hub.
        const CGFloat gap = 48.0;
        CGFloat previewWidth = safeCardWidthForRing(count, finalRadius, finalRadius, size.width) * 0.94;
        CGFloat previewHeight = previewWidth * 0.60;
        CGFloat needed = previewHeight / 2.0 + kHubRadius + gap;   // top card clears the hub
        if (count == 3) {
            // Lower cards sit at -30 and -150 degrees.
            needed = MAX(needed, (previewWidth + gap) / (2.0 * cos(M_PI / 6.0)));
            needed = MAX(needed, (previewHeight + gap) / 1.5);
            // Their inner corner must clear the hub too: either the top edge
            // passes below it or the inner edge passes beside it.
            CGFloat clearBelow = 2.0 * (previewHeight / 2.0 + kHubRadius + gap);
            CGFloat clearBeside = (previewWidth / 2.0 + kHubRadius + gap) / cos(M_PI / 6.0);
            needed = MAX(needed, MIN(clearBelow, clearBeside));
        }
        finalRadius = MIN(finalRadius, needed);
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
    [g_ringView resetSelectionVisuals];
    [g_ringView movePointerTo:NSZeroPoint];
    // Blur and dimming appear at once with the cards, no fade.
    int blurRadius = atomic_load(&g_settingBlurRadius);
    setPanelBlur(blurRadius);
    g_dimView.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.02 alpha:blurRadius > 0 ? 0.12 : 0.27].CGColor;
    for (RingEntry *entry in g_windowEntries) (void)resolvedThumbnail(entry);
    [g_ringView setNeedsDisplay:YES];
    // Avoid forcing a synchronous draw before the panel is ordered onscreen.
    [g_panel setFrame:screen.frame display:NO];
    atomic_store(&g_ringOverlayVisible, true);
    [g_panel orderFrontRegardless];
    atomic_store(&g_ringShownGeneration, generation);
    fprintf(stderr, "[ring] overlay shown at screen center; %lu entries\n", (unsigned long)g_windowEntries.count);

    // The cached ring is already on screen. Fresh pictures of the visible
    // windows, above all the one being left, replace it as they arrive.
    refreshThumbnailsNow(0, 1.0);
    loadHiddenChromeTabs(generation);

    // Pruning may issue CG/AX queries. Run it after the cached ring is already
    // visible, away from the main queue and gesture-start path.
    dispatch_async(g_windowScanQueue, ^{
        if (generation == atomic_load(&g_gestureGeneration) && atomic_load(&g_gestureActive)) {
            pruneDeadWindowEntriesLive();
        }
    });
}

static AXUIElementRef findTabButton(AXUIElementRef parent, NSString *title, int depth);
static BOOL setChromeActiveTabWithIndex(NSString *windowID, NSString *tabID, NSUInteger tabIndex1Based);

static void activateApplication(NSRunningApplication *application) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // Only the application, not every one of its windows.
    [application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
}

// Our own settings window in front of every other app, as Diktat does it.
// The newer [NSApp activate] only asks, and macOS kept the window behind the
// app that was active when the menu bar icon was clicked.
static void activateSelf(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
}

// Brings one exact window to the front and switches to its Space, including
// a full-screen space, the way AltTab does. Needs no Accessibility access.
// Private SkyLight calls, looked up at run time; missing ones just return NO.
typedef CGError (*SetFrontProcessWithOptionsFunction)(ProcessSerialNumber *, CGWindowID, uint32_t);
typedef CGError (*PostEventRecordToFunction)(ProcessSerialNumber *, uint8_t *);
static BOOL focusWindowExactly(pid_t pid, CGWindowID windowID) {
    static SetFrontProcessWithOptionsFunction setFrontProcess;
    static PostEventRecordToFunction postEventRecord;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        setFrontProcess = (SetFrontProcessWithOptionsFunction)dlsym(RTLD_DEFAULT, "_SLPSSetFrontProcessWithOptions");
        postEventRecord = (PostEventRecordToFunction)dlsym(RTLD_DEFAULT, "SLPSPostEventRecordTo");
    });
    if (!setFrontProcess || !postEventRecord || windowID == kCGNullWindowID) return NO;
    ProcessSerialNumber process = {0, 0};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (GetProcessForPID(pid, &process) != noErr) return NO;
#pragma clang diagnostic pop
    const uint32_t kUserGenerated = 0x200;
    if (setFrontProcess(&process, windowID, kUserGenerated) != kCGErrorSuccess) return NO;
    // Make it the key window of its app (the event record AltTab and yabai use).
    uint8_t record[0xf8] = {0};
    record[0x04] = 0xf8;
    record[0x3a] = 0x10;
    memcpy(record + 0x3c, &windowID, sizeof(windowID));
    memset(record + 0x20, 0xff, 0x10);
    record[0x08] = 0x01;
    postEventRecord(&process, record);
    record[0x08] = 0x02;
    postEventRecord(&process, record);
    return YES;
}

static void raiseWindowForEntry(RingEntry *entry, uint64_t generation) {
    if (generation != atomic_load(&g_gestureGeneration)) return;
    if (!entry.application || entry.application.isTerminated) return;
    pid_t pid = entry.application.processIdentifier;

    // Chrome profiles are separate windows in one app. Activating Chrome keeps
    // the last used profile in front unless that window is made index 1.
    if (generation == atomic_load(&g_gestureGeneration) && entry.isTab &&
        entry.chromeWindowID.length) {
        BOOL switched = setChromeActiveTabWithIndex(entry.chromeWindowID, entry.chromeTabID,
                                                    entry.tabIndex + 1);
        if (switched) {
            focusWindowExactly(pid, entry.windowID);
            return;
        }
        NSLog(@"[Chrome tabs] could not activate window %@ tab %@ index %lu",
              entry.chromeWindowID, entry.chromeTabID, (unsigned long)(entry.tabIndex + 1));
    }

    // The exact window, even in another Space or full screen. The AX raise
    // below still runs when Accessibility is allowed, for apps that need it.
    focusWindowExactly(pid, entry.windowID);

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

static void selectWindowImmediately(uint64_t generation, NSInteger selection, NSPoint pointer) {
    if (generation != atomic_load(&g_gestureGeneration) || !atomic_load(&g_gestureActive) || !g_panel) return;
    g_ringView.selectedIndex = selection;
    [g_ringView movePointerTo:pointer];
}

// Touch frames arrive faster than the screen refreshes. Only the latest
// pointer and selection reach the main queue.
static void scheduleSelectionUpdate(uint64_t generation, NSInteger selection, NSPoint pointer) {
    BOOL shouldDispatch = NO;
    os_unfair_lock_lock(&g_selectionLock);
    g_pendingSelection = selection;
    g_pendingPointer = pointer;
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
        NSPoint latestPointer = g_pendingPointer;
        uint64_t latestGeneration = g_pendingSelectionGeneration;
        g_selectionUpdatePending = NO;
        os_unfair_lock_unlock(&g_selectionLock);
        selectWindowImmediately(latestGeneration, latestSelection, latestPointer);
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

// With three-finger drag turned on, macOS moves the cursor while the fingers
// pick a card. Put it back where it was when the gesture began.
static void restoreCursorAfterGesture(void) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return;
    CGPoint now = CGEventGetLocation(event);
    CFRelease(event);
    if (hypot(now.x - g_cursorAtGestureStart.x, now.y - g_cursorAtGestureStart.y) < 2.0) return;
    CGWarpMouseCursorPosition(g_cursorAtGestureStart);
    CGAssociateMouseAndMouseCursorPosition(true);
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
    // Hidden Chrome tabs shown for their pictures are put back, except in the
    // window of the card being picked.
    RingEntry *picked = selection >= 0 && selection < (NSInteger)g_windowEntries.count
        ? g_windowEntries[(NSUInteger)selection] : nil;
    setRingPick(picked != nil, picked.isTab ? picked.chromeWindowID : nil);
    atomic_store(&g_gestureActive, false);
    atomic_store(&g_gestureEnding, false);
    if (g_panel) [g_panel orderOut:nil];
    atomic_store(&g_ringOverlayVisible, false);
    showSystemCursorAfterGesture();
    restoreCursorAfterGesture();
    releaseDecodedThumbnails();
    // Changes that happened while the ring was open were not applied.
    scanWindowsNow();
    if (selection < 0 || selection >= (NSInteger)g_windowEntries.count) {
        return;
    }

    RingEntry *entry = g_windowEntries[(NSUInteger)selection];
    if (!entry.application || entry.application.isTerminated) {
        return;
    }
    playRingSound(g_activateSound);
    // Tell the media rules right away, before Chrome even switches, so the
    // video starts without waiting for a tab check.
    if (entry.isTab && entry.chromeWindowID.length) {
        RingMediaTabSwitchedByRing(entry.chromeWindowID, entry.chromeTabID);
    }
    // Activate first, from the main thread, as before: a background app may
    // not bring another app forward otherwise. raiseWindowForEntry then puts
    // the exact window in front, in its own Space if needed.
    activateApplication(entry.application);
    BOOL captureChromeAfterRaise =
        [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"] &&
        entry.windowID != kCGNullWindowID;
    NSString *chromeTabKey = captureChromeAfterRaise ? [tabThumbnailKey(entry) copy] : nil;
    CGWindowID chromeWindowID = entry.windowID;
    // The window being left was captured when the ring opened, so raising the
    // selection does not wait for a screenshot.
    dispatch_async(g_windowActivationQueue, ^{
        raiseWindowForEntry(entry, generation);
        if (!chromeTabKey.length) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC),
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
    // With one card per app, the app name says it all.
    if (atomic_load(&g_settingCardGrouping) == CardGroupingApps) {
        return entry.application.localizedName ?: @"Aplikacija";
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

// The icon in a picture card's lower left corner: the site's icon for a
// Chrome tab (Chrome's own when the site has none), the app icon for other
// windows. Returns the width it takes, so the title starts after it.
static CGFloat drawCardBadgeIcon(RingEntry *entry, NSRect cardRect) {
    NSImage *icon = nil;
    if ([entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"] && atomic_load(&g_settingShowSiteIcons)) {
        icon = RingFaviconForURL(entry.tabURL) ?: entry.icon;
    } else if (atomic_load(&g_settingShowAppIcons)) {
        icon = entry.icon;
    }
    if (!icon) return 0;
    // No backing plate; a soft shadow keeps it readable on light pictures.
    NSRect iconRect = NSMakeRect(NSMinX(cardRect) + 8.0, NSMinY(cardRect) + 6.0, kCardBadgeIconSize, kCardBadgeIconSize);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowBlurRadius = 6.0;
    shadow.shadowOffset = NSMakeSize(0, -1);
    shadow.shadowColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.55];
    [shadow set];
    [icon drawInRect:iconRect fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    return kCardBadgeIconSize + 6.0;
}

static void drawCardLabel(NSString *text, NSRect cardRect, BOOL truncateMiddle, CGFloat leading) {
    if (!text.length) return;
    cardRect.origin.x += leading;
    cardRect.size.width -= leading;
    NSDictionary *measure = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0]
    };
    NSSize textSize = [text sizeWithAttributes:measure];
    CGFloat maxBadgeW = MAX(24.0, NSWidth(cardRect) - 16.0);
    CGFloat badgeW = MIN(maxBadgeW, textSize.width + 16.0);
    CGFloat badgeH = 22.0;
    // Next to an icon the title sits on the icon's middle line.
    CGFloat badgeY = leading > 0 ? NSMinY(cardRect) + 6.0 + (kCardBadgeIconSize - badgeH) / 2.0 : NSMinY(cardRect) + 8.0;
    NSRect badgeRect = NSMakeRect(NSMinX(cardRect) + 8.0, badgeY, badgeW, badgeH);
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

// Window titles are shortened differently by the app and by the window server
// ("runs..." against "run…."), so a shared beginning also counts as a match.
static BOOL windowTitlesMatch(NSString *a, NSString *b) {
    if (!a.length || !b.length) return NO;
    if ([a localizedCaseInsensitiveContainsString:b] || [b localizedCaseInsensitiveContainsString:a]) return YES;
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@"….· "];
    NSString *left = [[a lowercaseString] stringByTrimmingCharactersInSet:trim];
    NSString *right = [[b lowercaseString] stringByTrimmingCharactersInSet:trim];
    NSString *common = [left commonPrefixWithString:right options:0];
    return common.length >= MIN((NSUInteger)16, MIN(left.length, right.length));
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
        // Chrome keeps hidden helper surfaces (1x1, a 30 px strip, popups).
        // They are never the browser window.
        if ([candidate[@"Width"] doubleValue] < 100 || [candidate[@"Height"] doubleValue] < 60) continue;
        double score = fabs(bounds.origin.x - [candidate[@"X"] doubleValue]) +
            fabs(bounds.origin.y - [candidate[@"Y"] doubleValue]) +
            fabs(bounds.size.width - [candidate[@"Width"] doubleValue]) +
            fabs(bounds.size.height - [candidate[@"Height"] doubleValue]);
        NSString *candidateTitle = info[(id)kCGWindowName];
        if (windowTitle.length) {
            if (windowTitlesMatch(candidateTitle, windowTitle)) {
                score -= 1000000.0;
            } else {
                // An untitled surface is no better than a window with another title.
                score += 10000.0;
            }
        }
        // Bounds can differ a lot (Stage Manager shrinks windows), so a window
        // that is actually on screen beats a hidden one.
        if (![info[(id)kCGWindowIsOnscreen] boolValue]) score += 5000.0;
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

static CGWindowID axWindowID(AXUIElementRef window) {
    CGWindowID windowID = kCGNullWindowID;
    if (!window || _AXUIElementGetWindow(window, &windowID) != kAXErrorSuccess) return kCGNullWindowID;
    return windowID;
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

// Same page for screenshot purposes. YouTube keeps the video ID while other
// query parameters (playlist index, time) change.
static NSString *chromePageIdentity(NSString *tabURL) {
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
    NSString *url = chromePageIdentity(entry.tabURL) ?: @"";
    NSString *previous = g_tabCachedURL[tabKey];
    if (previous && ![previous isEqualToString:url]) {
        [g_tabThumbnailCache removeObjectForKey:tabKey];
        [g_tabLastCaptured removeObjectForKey:tabKey];
        if (entry.windowID != kCGNullWindowID) g_chromeWindowLastCapture[@(entry.windowID)] = @0;
        entry.thumbnailData = nil;
        entry.thumbnail = nil;
    }
    g_tabCachedURL[tabKey] = url;
}

// Only a real screenshot of the page. A tab that was never visible keeps the
// title card instead of a site poster (YouTube used to show the video cover).
static void applyBestChromeThumbnail(RingEntry *entry) {
    NSData *real = g_tabThumbnailCache[tabThumbnailKey(entry)];
    if (real.length || entry.thumbnailData) applyThumbnailDataToEntry(entry, real);
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
                applyBestChromeThumbnail(entry);
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

// A window off this desktop that was never captured could only show its app
// icon, and such cards (a Terminal helper, a window left in another Space)
// usually did not open anything. They stay out of the ring until the window is
// on screen and gets its picture. Chrome tabs keep their title card.
static NSArray<RingEntry *> *entriesWorthShowing(NSArray<RingEntry *> *entries) {
    // Without Screen Recording no card has a picture; keep them all.
    if (!g_thumbnailPreviewsEnabled || !CGPreflightScreenCaptureAccess()) return entries;
    NSMutableSet<NSNumber *> *onScreenIDs = [NSMutableSet set];
    CFArrayRef onScreen = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                     kCGNullWindowID);
    if (onScreen) {
        for (NSDictionary *info in (__bridge NSArray *)onScreen) {
            if (info[(id)kCGWindowNumber]) [onScreenIDs addObject:info[(id)kCGWindowNumber]];
        }
        CFRelease(onScreen);
    }
    NSIndexSet *shown = [entries indexesOfObjectsPassingTest:^BOOL(RingEntry *entry, NSUInteger index, BOOL *stop) {
        (void)index; (void)stop;
        return entry.thumbnailData.length > 0 ||
            [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"] ||
            [onScreenIDs containsObject:@(entry.windowID)];
    }];
    return shown.count == entries.count ? entries : [entries objectsAtIndexes:shown];
}

// "windowID:tabID" of every open Chrome tab, or nil when that cannot be known
// right now (Chrome not running, no Automation access, script error).
static NSSet<NSString *> *liveChromeTabs(void) {
    BOOL chromeRunning = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.google.Chrome"].count > 0;
    if (!chromeRunning || !ensureChromeAutomation(NO)) return nil;
    static NSAppleScript *s_script;
    if (!s_script) {
        s_script = [[NSAppleScript alloc] initWithSource:
            @"set output to \"\"\n"
             "tell application \"Google Chrome\"\n"
             "repeat with chromeWindow in windows\n"
             "set windowID to (id of chromeWindow) as text\n"
             "set tabIDs to id of every tab of chromeWindow\n"
             "repeat with tabIndex from 1 to count of tabIDs\n"
             "set output to output & windowID & \":\" & ((item tabIndex of tabIDs) as text) & linefeed\n"
             "end repeat\n"
             "end repeat\n"
             "end tell\n"
             "return output"];
        [s_script compileAndReturnError:nil];
    }
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = nil;
    @synchronized ([NSAppleScript class]) {
        result = [s_script executeAndReturnError:&error];
    }
    if (error || !result.stringValue.length) return nil;
    NSMutableSet<NSString *> *tabs = [NSMutableSet set];
    for (NSString *line in [result.stringValue componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length) [tabs addObject:line];
    }
    return tabs;
}

static void pruneDeadWindowEntriesLive(void) {
    if (!g_windowEntries || !g_windowEntries.count) return;
    // A tab closed in Chrome keeps its window, so the CG check below misses it.
    BOOL hasChromeTabs = NO;
    for (RingEntry *entry in g_windowEntries) {
        if (entry.chromeTabID.length) { hasChromeTabs = YES; break; }
    }
    NSSet<NSString *> *openChromeTabs = hasChromeTabs ? liveChromeTabs() : nil;

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

        if (openChromeTabs && entry.chromeTabID.length && entry.chromeWindowID.length &&
            ![openChromeTabs containsObject:[NSString stringWithFormat:@"%@:%@", entry.chromeWindowID, entry.chromeTabID]]) {
            changed = YES;
            [deadTabKeys addObject:tabThumbnailKey(entry)];
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
                    [g_windowLastCaptured removeObjectForKey:wid];
                    [g_windowLastSeen removeObjectForKey:wid];
                    [g_windowPIDMap removeObjectForKey:wid];
                }
            }
            if (g_tabThumbnailCache) {
                for (NSString *tKey in deadTabKeys) {
                    [g_tabThumbnailCache removeObjectForKey:tKey];
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

static BOOL runChromeScript(NSString *source) {
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
    return [result.stringValue isEqualToString:@"ok"];
}

// Video and audio in the tabs are handled by ring_media.m, which notices the
// switch on its own.
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
          "return \"ok\"\n"
          "end if\n"
          "end repeat\n", tabID];
    }
    if (tabIndex1Based > 0) {
        [source appendFormat:
         @"set tabCount to count of tabs of targetWindow\n"
          "if %@ <= tabCount then\n"
          "set active tab index of targetWindow to %@\n"
          "return \"ok\"\n"
          "end if\n", @(tabIndex1Based), @(tabIndex1Based)];
    }
    [source appendString:
         @"return \"ok\"\n"
          "end try\n"
          "end tell\n"
          "return \"failed\""];
    return runChromeScript(source);
}

// A second surface of an already listed window: no title and mostly inside
// it, or the same title in practically the same frame. Affinity adds one when
// a document opens; without this check it became a duplicate card. Callers
// compare only windows that are both visible or both hidden, so two maximized
// windows with one title in different Spaces stay two cards.
static BOOL isTwinSurface(CGRect bounds, NSString *title, RingEntry *listed) {
    CGRect overlap = CGRectIntersection(bounds, listed.windowBounds);
    if (CGRectIsNull(overlap) || bounds.size.width <= 0 || bounds.size.height <= 0) return NO;
    if (!title.length) {
        return overlap.size.width * overlap.size.height >= bounds.size.width * bounds.size.height * 0.85;
    }
    BOOL sameFrame = fabs(bounds.origin.x - listed.windowBounds.origin.x) <= 12 &&
                     fabs(bounds.origin.y - listed.windowBounds.origin.y) <= 12 &&
                     fabs(bounds.size.width - listed.windowBounds.size.width) <= 12 &&
                     fabs(bounds.size.height - listed.windowBounds.size.height) <= 12;
    return sameFrame && [listed.windowTitle isEqualToString:title];
}

static NSArray<RingEntry *> *collectOpenWindows(void) {
    NSMutableDictionary<NSNumber *, NSRunningApplication *> *appsByPID = [NSMutableDictionary dictionary];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        // Our own settings window makes this app regular while it is open; it
        // is never a card, and raising it from the activation queue crashed
        // AppKit (window ordering is main-thread only).
        if (app.activationPolicy == NSApplicationActivationPolicyRegular && !app.isTerminated &&
            app.processIdentifier != getpid()) {
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
    // Apps that have a real titled window. Their untitled hidden windows are
    // helpers (WhatsApp and Terminal keep a 500x500 one), not extra cards.
    NSMutableSet<NSNumber *> *pidsWithTitledWindow = [NSMutableSet set];
    for (NSDictionary *info in windowInfos) {
        if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
        NSString *name = info[(id)kCGWindowName];
        if ([name isKindOfClass:[NSString class]] && name.length && info[(id)kCGWindowOwnerPID]) {
            [pidsWithTitledWindow addObject:info[(id)kCGWindowOwnerPID]];
        }
    }
    NSMutableSet<NSNumber *> *onScreenWindowIDs = [NSMutableSet set];
    for (NSDictionary *info in windowInfos) {
        if ([info[(id)kCGWindowIsOnscreen] boolValue] && info[(id)kCGWindowNumber]) {
            [onScreenWindowIDs addObject:info[(id)kCGWindowNumber]];
        }
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
                // Chrome's AX window title holds the active tab title, and the
                // AX window knows its exact ID. Needs Accessibility; without it
                // the list stays empty and matching falls back to CG data.
                NSMutableArray<NSDictionary *> *chromeAXWindows = [NSMutableArray array];
                AXUIElementRef chromeElement = AXUIElementCreateApplication(app.processIdentifier);
                if (chromeElement) {
                    AXUIElementSetMessagingTimeout(chromeElement, 0.3f);
                    CFTypeRef axWindowsValue = NULL;
                    if (AXUIElementCopyAttributeValue(chromeElement, kAXWindowsAttribute, &axWindowsValue) == kAXErrorSuccess &&
                        axWindowsValue && CFGetTypeID(axWindowsValue) == CFArrayGetTypeID()) {
                        for (id axWindow in (__bridge NSArray *)axWindowsValue) {
                            CGWindowID axID = axWindowID((__bridge AXUIElementRef)axWindow);
                            NSString *axTitle = axStringAttribute((__bridge AXUIElementRef)axWindow, kAXTitleAttribute);
                            if (axID != kCGNullWindowID && axTitle.length) {
                                [chromeAXWindows addObject:@{@"id": @(axID), @"title": axTitle}];
                            }
                        }
                    }
                    if (axWindowsValue) CFRelease(axWindowsValue);
                    CFRelease(chromeElement);
                }
                for (NSDictionary *tabInfo in chromeTabs) {
                    CGRect bounds = NSRectToCGRect([tabInfo[@"bounds"] rectValue]);
                    NSString *windowTitle = tabInfo[@"windowTitle"] ?: @"";
                    NSNumber *windowIndex = tabInfo[@"windowIndex"];
                    NSNumber *mappedWindowID = chromeWindowIDs[windowIndex];
                    CGWindowID windowID = mappedWindowID ? mappedWindowID.unsignedIntValue : kCGNullWindowID;
                    if (!mappedWindowID) {
                        for (NSDictionary *axWindow in chromeAXWindows) {
                            if ([matchedWindowIDs containsObject:axWindow[@"id"]]) continue;
                            if (!windowTitlesMatch(axWindow[@"title"], windowTitle)) continue;
                            windowID = [axWindow[@"id"] unsignedIntValue];
                            break;
                        }
                        if (windowID == kCGNullWindowID) {
                            windowID = matchingCGWindowID(app.processIdentifier, bounds, windowTitle,
                                                          windowInfos, matchedWindowIDs);
                        }
                    }
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
                CGWindowID windowID = axWindowID(axWindow);
                if (windowID == kCGNullWindowID || [matchedWindowIDs containsObject:@(windowID)]) {
                    windowID = matchingCGWindowID(app.processIdentifier, bounds, windowTitle,
                                                  windowInfos, matchedWindowIDs);
                }
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
        if (!title.length && ![info[(id)kCGWindowIsOnscreen] boolValue] && [pidsWithTitledWindow containsObject:pid]) {
            // Stage Manager shrinks the main window, so "inside the window"
            // below no longer catches these helpers.
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
        BOOL twin = NO;
        BOOL onScreen = [info[(id)kCGWindowIsOnscreen] boolValue];
        for (RingEntry *listed in entries) {
            if (listed.application.processIdentifier != pid.intValue || listed.isTab) continue;
            if ([onScreenWindowIDs containsObject:@(listed.windowID)] != onScreen) continue;
            if (isTwinSurface(windowBounds, title, listed)) { twin = YES; break; }
        }
        if (twin) continue;   // the window list is front to back, so the first one stays
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

    // Finder tabs of one window can share a single card: the tab on screen
    // stands for the window. Separate Finder windows keep their own cards.
    if (atomic_load(&g_settingFinderTabsOneCard)) {
        NSMutableDictionary<NSValue *, RingEntry *> *finderCardByWindow = [NSMutableDictionary dictionary];
        for (RingEntry *entry in entries) {
            if (!entry.isTab || !entry.accessibilityWindowObject ||
                ![entry.application.bundleIdentifier isEqualToString:@"com.apple.finder"]) continue;
            NSValue *windowKey = [NSValue valueWithPointer:(__bridge const void *)entry.accessibilityWindowObject];
            RingEntry *current = finderCardByWindow[windowKey];
            if (!current || (!current.isSelectedTab && entry.isSelectedTab)) finderCardByWindow[windowKey] = entry;
        }
        NSMutableArray<RingEntry *> *mergedFinderEntries = [NSMutableArray arrayWithCapacity:entries.count];
        for (RingEntry *entry in entries) {
            if (entry.isTab && entry.accessibilityWindowObject &&
                [entry.application.bundleIdentifier isEqualToString:@"com.apple.finder"]) {
                NSValue *windowKey = [NSValue valueWithPointer:(__bridge const void *)entry.accessibilityWindowObject];
                if (finderCardByWindow[windowKey] != entry) continue;
            }
            [mergedFinderEntries addObject:entry];
        }
        entries = mergedFinderEntries;
    }
    // "Only apps": one card per app, showing the window used last. Chrome
    // keeps a card per window, because separate windows are usually separate
    // profiles.
    if (atomic_load(&g_settingCardGrouping) == CardGroupingApps) {
        NSMutableDictionary<NSNumber *, NSNumber *> *stackOrder = [NSMutableDictionary dictionary];
        [windowInfos enumerateObjectsUsingBlock:^(NSDictionary *info, NSUInteger index, BOOL *stop) {
            (void)stop;
            if (info[(id)kCGWindowNumber]) stackOrder[info[(id)kCGWindowNumber]] = @(index);   // front to back
        }];
        NSMutableDictionary<NSString *, RingEntry *> *cardByGroup = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *groups = [NSMutableArray array];
        for (RingEntry *entry in entries) {
            BOOL isChrome = [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"];
            NSString *group = isChrome
                ? [NSString stringWithFormat:@"%d:%u", entry.application.processIdentifier, entry.windowID]
                : [NSString stringWithFormat:@"%d", entry.application.processIdentifier];
            RingEntry *current = cardByGroup[group];
            if (!current) {
                [groups addObject:group];
                cardByGroup[group] = entry;
                continue;
            }
            // The tab on screen beats hidden tabs; then the window in front wins.
            BOOL entryShown = !entry.isTab || entry.isSelectedTab;
            BOOL currentShown = !current.isTab || current.isSelectedTab;
            NSInteger entryDepth = stackOrder[@(entry.windowID)] ? stackOrder[@(entry.windowID)].integerValue : NSIntegerMax;
            NSInteger currentDepth = stackOrder[@(current.windowID)] ? stackOrder[@(current.windowID)].integerValue : NSIntegerMax;
            if ((entryShown && !currentShown) || (entryShown == currentShown && entryDepth < currentDepth)) {
                cardByGroup[group] = entry;
            }
        }
        NSMutableArray<RingEntry *> *appCards = [NSMutableArray arrayWithCapacity:groups.count];
        for (NSString *group in groups) [appCards addObject:cardByGroup[group]];
        entries = appCards;
    }
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

// Capture in the window's own proportions. A fixed 640x384 frame around a
// narrower window (Stage Manager shrinks the active one) was padded with white.
static void configureThumbnailSize(SCStreamConfiguration *configuration, SCWindow *window) {
    CGFloat width = window.frame.size.width, height = window.frame.size.height;
    size_t pixelHeight = kThumbnailPixelHeight;
    if (width > 1 && height > 1) {
        pixelHeight = (size_t)MIN(MAX(lround(kThumbnailPixelWidth * height / width), 120), 960);
    }
    configuration.width = kThumbnailPixelWidth;
    configuration.height = pixelHeight;
    configuration.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
}

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

static CGRect currentWindowBounds(CGWindowID windowID) {
    CGRect bounds = CGRectNull;
    const void *ids[] = { (const void *)(uintptr_t)windowID };
    CFArrayRef idArray = CFArrayCreate(NULL, ids, 1, NULL);
    CFArrayRef descriptions = idArray ? CGWindowListCreateDescriptionFromArray(idArray) : NULL;
    if (descriptions && CFArrayGetCount(descriptions) > 0) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(descriptions, 0);
        CFDictionaryRef boundsDict = (__bridge CFDictionaryRef)info[(id)kCGWindowBounds];
        if (boundsDict) CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds);
    }
    if (descriptions) CFRelease(descriptions);
    if (idArray) CFRelease(idArray);
    return bounds;
}

static BOOL boundsClose(CGRect a, CGRect b) {
    if (CGRectIsNull(a) || CGRectIsNull(b)) return NO;
    return fabs(a.origin.x - b.origin.x) <= 2 && fabs(a.origin.y - b.origin.y) <= 2 &&
           fabs(a.size.width - b.size.width) <= 2 && fabs(a.size.height - b.size.height) <= 2;
}

// A window in the middle of an animation (Stage Manager moving it to or from
// its strip, a resize, app switching) gives a skewed picture on a black
// background. The window must have the size ScreenCaptureKit listed and must
// not move while it is captured; otherwise the old picture stays.
static BOOL windowIsSettled(SCWindow *window, CGRect *boundsOut) {
    CGRect bounds = currentWindowBounds(window.windowID);
    if (boundsOut) *boundsOut = bounds;
    return !CGRectIsNull(bounds) &&
           fabs(bounds.size.width - window.frame.size.width) <= 2 &&
           fabs(bounds.size.height - window.frame.size.height) <= 2;
}

static CGImageRef captureWindowImage(SCWindow *window) {
    CGRect boundsBefore = CGRectNull;
    if (!windowIsSettled(window, &boundsBefore)) return NULL;
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
    SCStreamConfiguration *configuration = [SCStreamConfiguration new];
    configureThumbnailSize(configuration, window);
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
    if (result && !boundsClose(boundsBefore, currentWindowBounds(window.windowID))) {
        CGImageRelease(result);   // moved during the capture
        result = NULL;
    }
    return result;
}

static void noteChromeSelectionChanges(NSArray<RingEntry *> *entries) {
    @synchronized ([NSMutableDictionary class]) {
        if (!g_lastSelectedChromeTabKeys) g_lastSelectedChromeTabKeys = [NSMutableDictionary dictionary];
        if (!g_chromeForceCaptureKeys) g_chromeForceCaptureKeys = [NSMutableSet set];
        NSMutableDictionary<NSNumber *, NSString *> *latest = [NSMutableDictionary dictionary];
        for (RingEntry *entry in entries) {
            if (!entry.isTab || !entry.isSelectedTab) continue;
            if (![entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"]) continue;
            if (entry.windowID == kCGNullWindowID) continue;
            NSNumber *windowKey = @(entry.windowID);
            NSString *tabKey = tabThumbnailKey(entry);
            latest[windowKey] = tabKey;
            NSString *previous = g_lastSelectedChromeTabKeys[windowKey];
            if (previous.length && ![previous isEqualToString:tabKey]) {
                [g_chromeForceCaptureKeys addObject:tabKey];
                g_chromeWindowLastCapture[windowKey] = @0;
                [g_tabLastCaptured removeObjectForKey:tabKey];
            }
        }
        g_lastSelectedChromeTabKeys = latest;
    }
}

// Chrome's active tab and its page, read at capture time. The periodic scan can
// be two seconds old, and a screenshot stored under the wrong tab stays there.
static NSString *chromeActiveTab(NSString *windowID, NSString **urlOut) {
    if (!validChromeID(windowID) || !ensureChromeAutomation(NO)) return nil;
    NSString *source = [NSString stringWithFormat:
        @"tell application \"Google Chrome\"\n"
         "set targetTab to active tab of (first window whose id is \"%@\")\n"
         "return ((id of targetTab) as text) & (ASCII character 31) & ((URL of targetTab) as text)\n"
         "end tell", windowID];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = nil;
    @synchronized ([NSAppleScript class]) {
        result = [script executeAndReturnError:&error];
    }
    if (error) return nil;
    NSArray<NSString *> *parts = [result.stringValue componentsSeparatedByString:@"\x1f"];
    if (parts.count < 2 || !validChromeID(parts[0])) return nil;
    if (urlOut) *urlOut = parts[1];
    return parts[0];
}

static NSMutableDictionary<NSNumber *, NSValue *> *g_windowFullSize;

static BOOL stageManagerEnabled(void) {
    static NSTimeInterval s_checkedAt = -10;
    static BOOL s_enabled = NO;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - s_checkedAt > 2.0) {
        s_checkedAt = now;
        CFPreferencesAppSynchronize(CFSTR("com.apple.WindowManager"));
        Boolean valid = false;
        s_enabled = CFPreferencesGetAppBooleanValue(CFSTR("GloballyEnabled"), CFSTR("com.apple.WindowManager"), &valid) && valid;
    }
    return s_enabled;
}

// On-screen windows worth a screenshot. Stage Manager keeps other windows on
// screen as small tilted previews in its strip; capturing those gave cut-off
// pictures with a white background. Such a window keeps its last full picture.
static NSMutableSet<NSNumber *> *capturableOnScreenWindowIDs(void) {
    NSMutableSet<NSNumber *> *windowIDs = [NSMutableSet set];
    CFArrayRef onScreenWindows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!onScreenWindows) return windowIDs;
    BOOL stageManager = stageManagerEnabled();
    @synchronized ([NSMutableDictionary class]) {
        if (!g_windowFullSize) g_windowFullSize = [NSMutableDictionary dictionary];
        for (CFIndex i = 0; i < CFArrayGetCount(onScreenWindows); i++) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(onScreenWindows, i);
            NSNumber *wid = info[(id)kCGWindowNumber];
            NSDictionary *bounds = info[(id)kCGWindowBounds];
            if (!wid || ![bounds isKindOfClass:[NSDictionary class]]) continue;
            CGFloat width = [bounds[@"Width"] doubleValue], height = [bounds[@"Height"] doubleValue];
            NSSize fullSize = g_windowFullSize[wid].sizeValue;
            BOOL shrunk = width < fullSize.width * 0.6 || height < fullSize.height * 0.6;
            BOOL stripSized = stageManager && width < 320 && height < 320;
            if (shrunk || stripSized) continue;
            if (width * height > fullSize.width * fullSize.height) {
                g_windowFullSize[wid] = [NSValue valueWithSize:NSMakeSize(width, height)];
            }
            [windowIDs addObject:wid];
        }
    }
    CFRelease(onScreenWindows);
    return windowIDs;
}

// Captures visible windows right away instead of waiting for the periodic
// planner: the app being left (onlyPID) or, when the ring opens, every visible
// window whose picture is older than minAge. Results are stored in one pass so
// an open ring redraws once.
static void refreshThumbnailsNow(pid_t onlyPID, NSTimeInterval minAge) {
    if (!g_thumbnailPreviewsEnabled || !g_liveCaptureQueue || !CGPreflightScreenCaptureAccess()) return;
    NSMutableSet<NSNumber *> *onScreenIDs = capturableOnScreenWindowIDs();

    pid_t frontPID = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSMutableDictionary<NSNumber *, RingEntry *> *entryByWindow = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *windowOrder = [NSMutableArray array];
    for (RingEntry *entry in g_windowEntries) {
        NSNumber *windowKey = @(entry.windowID);
        if (entry.windowID == kCGNullWindowID || ![onScreenIDs containsObject:windowKey]) continue;
        if (onlyPID > 0 && entry.application.processIdentifier != onlyPID) continue;
        RingEntry *current = entryByWindow[windowKey];
        if (!current) [windowOrder addObject:windowKey];
        // Tabs share one window and only the selected tab is on screen.
        if (!current || (!current.isSelectedTab && entry.isSelectedTab)) entryByWindow[windowKey] = entry;
    }

    NSMutableArray<NSDictionary *> *targets = [NSMutableArray array];
    @synchronized ([NSMutableDictionary class]) {
        for (NSNumber *windowKey in windowOrder) {
            RingEntry *entry = entryByWindow[windowKey];
            NSString *tabKey = entry.isTab ? tabThumbnailKey(entry) : nil;
            NSTimeInterval last = tabKey ? g_tabLastCaptured[tabKey].doubleValue
                                         : g_windowLastCaptured[windowKey].doubleValue;
            if (last > 0 && now - last < minAge) continue;
            NSMutableDictionary *target = [@{
                @"window": windowKey,
                @"pid": @(entry.application.processIdentifier)
            } mutableCopy];
            if (tabKey) target[@"tabKey"] = tabKey;
            if (entry.isTab && entry.chromeWindowID.length) target[@"chromeWindowID"] = entry.chromeWindowID;
            // The window the user is looking at goes first.
            if (entry.application.processIdentifier == frontPID) [targets insertObject:target atIndex:0];
            else [targets addObject:target];
        }
    }
    if (!targets.count) return;

    dispatch_async(g_liveCaptureQueue, ^{
        dispatch_semaphore_t listed = dispatch_semaphore_create(0);
        __block NSArray<SCWindow *> *shareableWindows = nil;
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
                                                    completionHandler:^(SCShareableContent *content, NSError *error) {
            (void)error;
            shareableWindows = content.windows;
            dispatch_semaphore_signal(listed);
        }];
        if (dispatch_semaphore_wait(listed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC))) != 0) return;

        NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
        for (NSDictionary *target in targets) {
            NSNumber *windowKey = target[@"window"];
            SCWindow *window = nil;
            for (SCWindow *candidate in shareableWindows) {
                if (candidate.windowID == windowKey.unsignedIntValue) { window = candidate; break; }
            }
            if (!window) continue;
            NSString *tabKey = target[@"tabKey"];
            NSString *pageURL = nil;
            NSString *chromeWindowID = target[@"chromeWindowID"];
            if (chromeWindowID.length) {
                NSString *activeTabID = chromeActiveTab(chromeWindowID, &pageURL);
                // Unknown tab: no picture is better than a picture on the wrong tab.
                if (!activeTabID) continue;
                tabKey = [NSString stringWithFormat:@"%d:chrome:%@:%@", [target[@"pid"] intValue],
                          chromeWindowID, activeTabID];
            }
            CGImageRef image = captureWindowImage(window);
            if (!image) continue;
            NSData *data = encodedThumbnailFromCGImage(image);
            CGImageRelease(image);
            if (!data) continue;
            NSMutableDictionary *result = [@{@"window": windowKey, @"data": data} mutableCopy];
            if (tabKey) result[@"tabKey"] = tabKey;
            if (pageURL) result[@"pageURL"] = pageURL;
            [results addObject:result];
        }
        if (!results.count) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized ([NSMutableDictionary class]) {
                NSNumber *stamp = @(NSProcessInfo.processInfo.systemUptime);
                for (NSDictionary *result in results) {
                    NSNumber *windowKey = result[@"window"];
                    NSString *tabKey = result[@"tabKey"];
                    NSData *data = result[@"data"];
                    recordThumbnailCaptureSuccess(windowKey);
                    if (tabKey) {
                        g_tabThumbnailCache[tabKey] = data;
                        g_tabLastCaptured[tabKey] = stamp;
                        if (result[@"pageURL"]) {
                            g_tabCachedURL[tabKey] = chromePageIdentity(result[@"pageURL"]) ?: @"";
                            g_chromeWindowLastCapture[windowKey] = stamp;
                        }
                    } else {
                        g_thumbnailCache[windowKey] = data;
                        g_windowLastCaptured[windowKey] = stamp;
                    }
                    for (RingEntry *entry in g_windowEntries) {
                        if (entry.windowID != windowKey.unsignedIntValue) continue;
                        BOOL matches = tabKey ? (entry.isTab && [tabThumbnailKey(entry) isEqualToString:tabKey])
                                              : !entry.isTab;
                        if (matches) applyThumbnailDataToEntry(entry, data);
                    }
                }
            }
            if (g_ringView && atomic_load(&g_ringOverlayVisible)) [g_ringView setNeedsDisplay:YES];
        });
    });
}

static void finishChromePrefetch(BOOL succeeded) {
    @synchronized ([NSMutableDictionary class]) {
        g_chromePrefetchRetryAfter = succeeded ? 0 : NSProcessInfo.processInfo.systemUptime + 3.0;
    }
    atomic_store(&g_chromePrefetchActive, false);
}

static void scheduleChromeBackgroundPrefetch(NSArray<RingEntry *> *entries) {
    (void)entries;
}


// Chrome tabs that were never on screen have no picture, because Chrome paints
// only the tab in front. While the ring is open, its blur hides the windows
// behind it, so those tabs are loaded and captured there:
//   1. every such tab is put in front for an instant, which makes Chrome start
//      loading all of them at once, in the background;
//   2. one by one, each is put in front again, captured once its page has
//      loaded, and the tab each window showed before is put back.
// A Chrome window hidden behind other windows is not painted by Chrome, so it
// is raised for this (without activating Chrome) and the window that was in
// front is raised again afterwards. The tab under the fingers goes first.
static _Atomic(bool) g_hiddenTabLoaderRunning = false;
static os_unfair_lock g_ringPickLock = OS_UNFAIR_LOCK_INIT;
static BOOL g_ringPickMade;
static NSString *g_ringPickedChromeWindow;   // Chrome window of the card just picked

static void setRingPick(BOOL made, NSString *chromeWindowID) {
    os_unfair_lock_lock(&g_ringPickLock);
    g_ringPickMade = made;
    g_ringPickedChromeWindow = [chromeWindowID copy];
    os_unfair_lock_unlock(&g_ringPickLock);
}

static BOOL ringPickMade(NSString **chromeWindowOut) {
    os_unfair_lock_lock(&g_ringPickLock);
    BOOL made = g_ringPickMade;
    if (chromeWindowOut) *chromeWindowOut = g_ringPickedChromeWindow;
    os_unfair_lock_unlock(&g_ringPickLock);
    return made;
}

// Puts one tab in front inside its window, without raising the window or Chrome.
static BOOL showChromeTabQuietly(NSString *windowID, NSString *tabID) {
    if (!validChromeID(windowID) || !validChromeID(tabID)) return NO;
    return runChromeScript([NSString stringWithFormat:
        @"tell application \"Google Chrome\"\n"
         "try\n"
         "set targetWindow to first window whose id is \"%@\"\n"
         "repeat with tabIndex from 1 to count of tabs of targetWindow\n"
         "if (id of tab tabIndex of targetWindow) as text is \"%@\" then\n"
         "set active tab index of targetWindow to tabIndex\n"
         "return \"ok\"\n"
         "end if\n"
         "end repeat\n"
         "end try\n"
         "end tell\n"
         "return \"failed\"", windowID, tabID]);
}

// Moves a Chrome window above the other apps' windows. Chrome stays in the
// background; only the order of the windows changes.
static BOOL raiseChromeWindowQuietly(NSString *windowID) {
    if (!validChromeID(windowID)) return NO;
    return runChromeScript([NSString stringWithFormat:
        @"tell application \"Google Chrome\"\n"
         "try\n"
         "set index of (first window whose id is \"%@\") to 1\n"
         "return \"ok\"\n"
         "end try\n"
         "end tell\n"
         "return \"failed\"", windowID]);
}

static BOOL chromeTabIsLoading(NSString *windowID, NSString *tabID) {
    if (!validChromeID(windowID) || !validChromeID(tabID)) return NO;
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:
        @"tell application \"Google Chrome\"\n"
         "return (loading of (first tab of (first window whose id is \"%@\") whose id is \"%@\")) as text\n"
         "end tell", windowID, tabID]];
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = nil;
    @synchronized ([NSAppleScript class]) {
        result = [script executeAndReturnError:&error];
    }
    return !error && [result.stringValue isEqualToString:@"true"];
}

static BOOL ringStillOpen(uint64_t generation) {
    return generation == atomic_load(&g_gestureGeneration) && atomic_load(&g_gestureActive);
}

// Chrome stops painting a window that other windows cover completely, and a
// capture would show the tab that was there before.
static BOOL windowFullyCovered(CGWindowID windowID) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenAboveWindow | kCGWindowListExcludeDesktopElements,
                                                    windowID);
    if (!windows) return NO;
    CGRect bounds = currentWindowBounds(windowID);
    BOOL covered = NO;
    for (NSDictionary *info in (__bridge NSArray *)windows) {
        if ([info[(id)kCGWindowLayer] intValue] != 0 || [info[(id)kCGWindowOwnerPID] intValue] == getpid()) continue;
        if ([info[(id)kCGWindowAlpha] doubleValue] < 1.0) continue;
        CGRect above = CGRectNull;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &above)) continue;
        if (!CGRectIsNull(bounds) && CGRectContainsRect(above, bounds)) { covered = YES; break; }
    }
    CFRelease(windows);
    return covered;
}

// Chrome tabs without a picture in windows on this desktop, on the main
// queue. The tab under the fingers comes first.
static NSArray<RingEntry *> *hiddenTabsToLoad(NSSet<NSString *> *tried) {
    NSArray<RingEntry *> *entries = g_ringView.entries;
    NSMutableSet<NSNumber *> *onScreenIDs = capturableOnScreenWindowIDs();
    NSInteger selected = g_ringView.selectedIndex;
    NSMutableArray<RingEntry *> *tabs = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)entries.count; i++) {
        RingEntry *entry = entries[(NSUInteger)i];
        if (!entry.isTab || entry.isSelectedTab || entry.thumbnailData.length ||
            !validChromeID(entry.chromeWindowID) || !validChromeID(entry.chromeTabID) ||
            ![onScreenIDs containsObject:@(entry.windowID)]) continue;
        NSString *key = tabThumbnailKey(entry);
        if ([tried containsObject:key]) continue;
        @synchronized ([NSMutableDictionary class]) {
            if (g_tabThumbnailCache[key]) continue;
        }
        if (i == selected) [tabs insertObject:entry atIndex:0];
        else [tabs addObject:entry];
    }
    return tabs;
}

static void storeLoadedTabPicture(NSString *tabKey, CGWindowID windowID, NSString *pageURL, NSData *data) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized ([NSMutableDictionary class]) {
            g_tabThumbnailCache[tabKey] = data;
            g_tabLastCaptured[tabKey] = @(NSProcessInfo.processInfo.systemUptime);
            if (pageURL) g_tabCachedURL[tabKey] = chromePageIdentity(pageURL) ?: @"";
            for (RingEntry *entry in g_windowEntries) {
                if (entry.windowID == windowID && entry.isTab && [tabThumbnailKey(entry) isEqualToString:tabKey]) {
                    applyThumbnailDataToEntry(entry, data);
                }
            }
        }
        if (g_ringView && atomic_load(&g_ringOverlayVisible)) [g_ringView setNeedsDisplay:YES];
    });
}

static SCWindow *shareableWindow(CGWindowID windowID) {
    dispatch_semaphore_t listed = dispatch_semaphore_create(0);
    __block SCWindow *window = nil;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
                                                completionHandler:^(SCShareableContent *content, NSError *error) {
        (void)error;
        for (SCWindow *candidate in content.windows) {
            if (candidate.windowID == windowID) { window = candidate; break; }
        }
        dispatch_semaphore_signal(listed);
    }];
    if (dispatch_semaphore_wait(listed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC))) != 0) return nil;
    return window;
}

static void loadHiddenChromeTabs(uint64_t generation) {
    if (!g_thumbnailPreviewsEnabled || !g_liveCaptureQueue || !CGPreflightScreenCaptureAccess() ||
        !ensureChromeAutomation(NO)) return;
    NSArray<RingEntry *> *firstTargets = hiddenTabsToLoad([NSSet set]);
    if (!firstTargets.count) return;
    if (atomic_exchange(&g_hiddenTabLoaderRunning, true)) return;
    setRingPick(NO, nil);
    if (!g_chromePrefetchQueue) {
        g_chromePrefetchQueue = dispatch_queue_create("touchpad.ring.chrome-prefetch", DISPATCH_QUEUE_SERIAL);
    }
    // The window in front now, raised again if a Chrome window had to come up.
    pid_t frontPID = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    CGWindowID frontWindow = kCGNullWindowID;
    CFArrayRef onScreen = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                     kCGNullWindowID);
    if (onScreen) {
        for (NSDictionary *info in (__bridge NSArray *)onScreen) {
            if ([info[(id)kCGWindowLayer] intValue] == 0 && [info[(id)kCGWindowOwnerPID] intValue] == frontPID) {
                frontWindow = [info[(id)kCGWindowNumber] unsignedIntValue];
                break;
            }
        }
        CFRelease(onScreen);
    }

    dispatch_async(g_chromePrefetchQueue, ^{
        NSMutableDictionary<NSString *, NSString *> *originalTabs = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSData *> *lastPicture = [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *raisedWindows = [NSMutableSet set];
        NSMutableSet<NSString *> *tried = [NSMutableSet set];
        RingMediaIgnoreTabChanges(30.0);

        // 1. Start loading every tab at once. Steps run on the live capture
        //    queue, so a capture from the ring's opening never sees a tab half
        //    painted.
        dispatch_sync(g_liveCaptureQueue, ^{
            for (RingEntry *entry in firstTargets) {
                if (!originalTabs[entry.chromeWindowID]) {
                    NSString *originalTab = chromeActiveTab(entry.chromeWindowID, NULL);
                    if (!originalTab) continue;
                    originalTabs[entry.chromeWindowID] = originalTab;
                }
                @synchronized ([NSAppleScript class]) {
                    if (!ringStillOpen(generation)) return;
                    showChromeTabQuietly(entry.chromeWindowID, entry.chromeTabID);
                }
            }
            for (NSString *chromeWindowID in originalTabs) {
                @synchronized ([NSAppleScript class]) {
                    if (!ringStillOpen(generation)) return;
                    showChromeTabQuietly(chromeWindowID, originalTabs[chromeWindowID]);
                }
            }
        });

        // 2. Capture them one by one.
        while (ringStillOpen(generation)) {
            @autoreleasepool {
                __block RingEntry *target = nil;
                dispatch_sync(dispatch_get_main_queue(), ^{ target = hiddenTabsToLoad(tried).firstObject; });
                if (!target) break;
                NSString *chromeWindowID = target.chromeWindowID, *tabID = target.chromeTabID;
                NSString *tabKey = tabThumbnailKey(target);
                CGWindowID windowID = target.windowID;
                [tried addObject:tabKey];

                dispatch_sync(g_liveCaptureQueue, ^{
                    if (!ringStillOpen(generation)) return;
                    if (windowFullyCovered(windowID) && ![raisedWindows containsObject:chromeWindowID]) {
                        if (!raiseChromeWindowQuietly(chromeWindowID)) return;
                        [raisedWindows addObject:chromeWindowID];
                        usleep(150000);   // Chrome paints the window again
                    }
                    if (windowFullyCovered(windowID)) return;
                    SCWindow *window = shareableWindow(windowID);
                    if (!window) return;
                    if (!originalTabs[chromeWindowID]) {
                        NSString *originalTab = chromeActiveTab(chromeWindowID, NULL);
                        if (!originalTab) return;
                        originalTabs[chromeWindowID] = originalTab;
                    }
                    if (!lastPicture[chromeWindowID]) {
                        // The window as it is now, to tell a repainted tab from an unchanged window.
                        CGImageRef before = captureWindowImage(window);
                        NSData *beforeData = encodedThumbnailFromCGImage(before);
                        if (before) CGImageRelease(before);
                        if (beforeData) lastPicture[chromeWindowID] = beforeData;
                    }
                    // Under the Apple Event lock: once the ring has closed, the
                    // pick may already have switched this window, and wins.
                    BOOL switched = NO;
                    @synchronized ([NSAppleScript class]) {
                        switched = ringStillOpen(generation) && showChromeTabQuietly(chromeWindowID, tabID);
                    }
                    if (!switched) return;

                    // Pages started loading in step 1; most are ready by now.
                    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
                    BOOL loading = YES;
                    while (ringStillOpen(generation) && NSProcessInfo.processInfo.systemUptime - started < 2.0) {
                        usleep(60000);
                        loading = chromeTabIsLoading(chromeWindowID, tabID);
                        if (!loading) break;
                    }
                    // A page still loading would be stored blank; it is tried
                    // again the next time the ring opens.
                    if (loading || !ringStillOpen(generation)) return;
                    usleep(100000);   // a few frames for the page to paint
                    NSString *pageURL = nil;
                    if (![chromeActiveTab(chromeWindowID, &pageURL) isEqualToString:tabID]) return;
                    CGImageRef image = captureWindowImage(window);
                    NSData *data = encodedThumbnailFromCGImage(image);
                    if (image) CGImageRelease(image);
                    // Media that started only because the tab was opened here stops again.
                    RingMediaQuietLoadedTab(chromeWindowID, tabID);
                    if (!data || [data isEqualToData:lastPicture[chromeWindowID]]) return;
                    lastPicture[chromeWindowID] = data;
                    storeLoadedTabPicture(tabKey, windowID, pageURL, data);
                    NSLog(@"[Chrome thumbnails] loaded hidden tab %@", tabKey);
                });
            }
        }

        // Put back the tab each window showed, unless the user just picked a
        // card in that window: the ring switches to it, and the pick wins.
        // The Apple Event lock orders this against the pick's own switch.
        for (NSString *chromeWindowID in originalTabs) {
            @synchronized ([NSAppleScript class]) {
                NSString *pickedWindow = nil;
                ringPickMade(&pickedWindow);
                if ([pickedWindow isEqualToString:chromeWindowID]) continue;
                NSString *originalTab = originalTabs[chromeWindowID];
                if (![chromeActiveTab(chromeWindowID, NULL) isEqualToString:originalTab]) {
                    showChromeTabQuietly(chromeWindowID, originalTab);
                }
            }
        }
        // A raised Chrome window goes back behind the window that was in
        // front, unless a card was picked: then that card's window comes up.
        if (raisedWindows.count && frontWindow != kCGNullWindowID && !ringPickMade(NULL)) {
            focusWindowExactly(frontPID, frontWindow);
        }
        RingMediaIgnoreTabChanges(0.4);
        atomic_store(&g_hiddenTabLoaderRunning, false);
    });
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
    NSMutableSet<NSNumber *> *onScreenIDs = capturableOnScreenWindowIDs();

    NSCountedSet<NSNumber *> *tabWindowIDCounts = [NSCountedSet set];
    for (RingEntry *entry in entries) {
        if (entry.isTab && entry.windowID != kCGNullWindowID) {
            [tabWindowIDCounts addObject:@(entry.windowID)];
        }
    }

    for (RingEntry *entry in entries) {
        NSNumber *key = @(entry.windowID);
        if (entry.windowID != kCGNullWindowID && ![onScreenIDs containsObject:key]) continue;
        if (entry.isTab) {
            BOOL isChromeTab = [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"];
            if (isChromeTab) {
                if (!entry.isSelectedTab) continue;
                NSString *tabKey = tabThumbnailKey(entry);
                NSTimeInterval lastAttempt = g_chromeWindowLastCapture[key].doubleValue;
                NSTimeInterval lastCaptured = tabLastCapturedSnapshot[tabKey].doubleValue;
                BOOL justBecameSelected = [g_chromeForceCaptureKeys containsObject:tabKey];
                if (justBecameSelected) [g_chromeForceCaptureKeys removeObject:tabKey];
                BOOL hasRealShot = tabThumbnailSnapshot[tabKey] != nil;
                NSTimeInterval refresh = entry.application.isActive ? 3.0 : 8.0;
                BOOL captureDue = justBecameSelected || !hasRealShot ||
                    (now - lastCaptured >= refresh);
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
        if (!entry.isTab && entry.windowID != kCGNullWindowID &&
            !thumbnailCaptureIsCoolingDown(key) &&
            ![g_thumbnailRequests containsObject:key]) {
            // Visible windows keep changing; the active app refreshes sooner.
            NSTimeInterval refresh = entry.application.isActive ? 3.0 : 12.0;
            if (!thumbnailSnapshot[key] || now - g_windowLastCaptured[key].doubleValue >= refresh) {
                [wantedIDs addObject:key];
            }
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
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
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
            CGRect boundsBefore = CGRectNull;
            BOOL settled = windowIsSettled(window, &boundsBefore);
            SCStreamConfiguration *configuration = [SCStreamConfiguration new];
            configureThumbnailSize(configuration, window);
            configuration.showsCursor = NO;
            configuration.ignoreShadowsSingleWindow = YES;
            [SCScreenshotManager captureImageWithFilter:[[SCContentFilter alloc] initWithDesktopIndependentWindow:window]
                                       configuration:configuration
                                       completionHandler:^(CGImageRef capturedImage, NSError *captureError) {
                // A window that was animating keeps its previous picture and
                // is tried again after the short failure backoff.
                CGImageRef image = settled && boundsClose(boundsBefore, currentWindowBounds(window.windowID))
                    ? capturedImage : NULL;
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
                    if (!chromeTabKey.length) g_windowLastCaptured[windowKey] = @(NSProcessInfo.processInfo.systemUptime);
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
            [g_windowLastCaptured removeObjectForKey:key];
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

// Finger travel moves the pointer at one constant speed, like a plain cursor.
// Only the direction selects, so no acceleration is needed. dx and dy are in
// trackpad widths, so both axes move alike.
static void moveRingPointer(double dx, double dy, NSInteger count) {
    const double kGain = 1.0 / 0.08;   // about 8% of the trackpad width reaches the ring
    // Motion back toward the center counts triple, so changing your mind
    // (up, then down; left, then right) is a short move. Motion around the
    // ring keeps the normal speed, so picking a neighbor stays precise.
    const double kInwardBoost = 3.0;
    double length = hypot(g_pointerX, g_pointerY);
    if (length > kPointerDeadZone) {
        double unitX = g_pointerX / length, unitY = g_pointerY / length;
        double radial = dx * unitX + dy * unitY;
        if (radial < 0) {
            // Boosted up to the center; motion past it continues at normal speed.
            double inward = -radial;
            double toCenter = length / kGain;
            double boosted = inward * kInwardBoost <= toCenter
                ? inward * kInwardBoost
                : toCenter + (inward - toCenter / kInwardBoost);
            dx += (inward - boosted) * unitX;
            dy += (inward - boosted) * unitY;
        }
    }
    g_pointerX += dx * kGain;
    g_pointerY += dy * kGain;

    // Keep the pointer inside the ring; pushing further slides it around the
    // ring, which turns the selection to the neighboring card.
    CGFloat radiusX = 1.0, radiusY = 1.0;
    ringEllipseRadii((NSUInteger)MAX(count, 1), 1.0, &radiusX, &radiusY);
    double norm = hypot(g_pointerX / radiusX, g_pointerY / radiusY);
    if (norm > kPointerReach) {
        g_pointerX *= kPointerReach / norm;
        g_pointerY *= kPointerReach / norm;
    }
}

// Selection by direction, like the CS buy wheel: as soon as the pointer leaves
// the center circle, the card whose sector it points into is chosen. A small
// margin keeps the choice from flickering on the line between two sectors.
static NSInteger pointerSelection(NSInteger count, NSInteger currentIndex) {
    if (count <= 0 || hypot(g_pointerX, g_pointerY) < kPointerDeadZone) return -1;
    double pointerAngle = atan2(g_pointerY, g_pointerX);
    NSInteger best = -1;
    double bestOffset = DBL_MAX, currentOffset = DBL_MAX;
    for (NSInteger i = 0; i < count; i++) {
        double offset = fabs(remainder(pointerAngle - cardScreenAngle(i, (NSUInteger)count), 2.0 * M_PI));
        if (i == currentIndex) currentOffset = offset;
        if (offset < bestOffset) { bestOffset = offset; best = i; }
    }
    double switchMargin = 0.18 * M_PI / (double)count;
    if (currentIndex >= 0 && currentIndex < count && currentOffset - bestOffset < switchMargin) return currentIndex;
    return best;
}

static NSInteger selectionForLift(void) {
    return g_selectedIndex;
}

static int ringTouchCallback(MTDeviceRef device, MTTouch *touches, int numTouches, double timestamp, int frame) {
    (void)frame;
    @autoreleasepool {
        static BOOL suppressUntilFourFingerLift = NO;
        static double allFingersUpSince = -1.0;
        static BOOL liftCompletionScheduled = NO;
        static uint64_t fourFingerAbortGeneration = 0;
        static BOOL threeFingersLastFrame = NO;
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
        BOOL hadThreeFingers = threeFingersLastFrame;
        threeFingersLastFrame = activeCount == 3;

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
            hideSystemCursorForGesture();
            allFingersUpSince = -1.0;
            liftCompletionScheduled = NO;
            g_previousX = x;
            g_previousY = y;
            g_pointerX = 0.0;
            g_pointerY = 0.0;
            g_selectedIndex = -1;
            int surfaceWidth = 0, surfaceHeight = 0;
            if (MTDeviceGetSensorSurfaceDimensions(device, &surfaceWidth, &surfaceHeight) == 0 &&
                surfaceWidth > 0 && surfaceHeight > 0) {
                g_trackpadAspect = (double)surfaceHeight / (double)surfaceWidth;
            }
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
                if (hadThreeFingers) {
                    moveRingPointer(x - g_previousX, (y - g_previousY) * g_trackpadAspect,
                                    atomic_load(&g_windowEntryCount));
                }
                // After a finger is lifted and put back, its new spot is not motion.
                g_previousX = x;
                g_previousY = y;
                NSInteger selection = pointerSelection(atomic_load(&g_windowEntryCount), g_selectedIndex);
                if (selection != g_selectedIndex) {
                    g_selectedIndex = selection;
                    fprintf(stderr, "[touch] selected entry %ld\n", (long)selection);
                }
                scheduleSelectionUpdate(atomic_load(&g_gestureGeneration), g_selectedIndex,
                                        NSMakePoint(g_pointerX, g_pointerY));
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

// The app being left is still on screen for a moment, so its picture matches
// what the user last saw.
- (void)applicationDeactivated:(NSNotification *)notification {
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    if (!app || app.processIdentifier == getpid() || atomic_load(&g_gestureActive)) return;
    // With Stage Manager the window being left starts flying into the strip
    // right now; the capture made when the ring opened covers it instead.
    if (stageManagerEnabled()) return;
    refreshThumbnailsNow(app.processIdentifier, 1.0);
}

- (void)applicationTerminated:(NSNotification *)notification {
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    if (!app || atomic_load(&g_gestureActive)) return;
    pid_t pid = app.processIdentifier;
    NSIndexSet *remaining = [g_windowEntries indexesOfObjectsPassingTest:^BOOL(RingEntry *entry, NSUInteger index, BOOL *stop) {
        (void)index; (void)stop;
        return entry.application.processIdentifier != pid;
    }];
    if (remaining.count != g_windowEntries.count) {
        g_windowEntries = [g_windowEntries objectsAtIndexes:remaining];
        atomic_store(&g_windowEntryCount, (int)g_windowEntries.count);
        if (g_ringView) g_ringView.entries = g_windowEntries;
    }
    scanWindowsNow();
}

- (void)appearanceChanged:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[thumbnails] light/dark change; recapturing visible windows");
        @synchronized ([NSMutableDictionary class]) {
            [g_thumbnailCache removeAllObjects];
            [g_windowLastCaptured removeAllObjects];
            [g_tabThumbnailCache removeAllObjects];
            [g_tabLastCaptured removeAllObjects];
            [g_chromeWindowLastCapture removeAllObjects];
            if (!g_chromeForceCaptureKeys) g_chromeForceCaptureKeys = [NSMutableSet set];
            [g_chromeForceCaptureKeys removeAllObjects];
            for (RingEntry *entry in g_windowEntries) {
                entry.thumbnailData = nil;
                entry.thumbnail = nil;
                if (entry.isTab && entry.isSelectedTab &&
                    [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"]) {
                    [g_chromeForceCaptureKeys addObject:tabThumbnailKey(entry)];
                }
            }
        }
        if (g_thumbnailPreviewsEnabled) schedulePendingThumbnailCapture(g_windowEntries);
    });
}
@end

static TouchpadWakeObserver *g_wakeObserver;

// Full window scan (AX, AppleScript, CG) on the scan queue. Runs every two
// seconds and at once when something changes. Never during a gesture: the
// ring keeps the list it opened with.
static void scanWindowsNow(void) {
    dispatch_async(g_windowScanQueue, ^{
        if (atomic_load(&g_gestureActive)) return;
        if (atomic_exchange(&g_isScanning, true)) return;
        @autoreleasepool {
            NSArray<RingEntry *> *entries = collectOpenWindows();
            pruneThumbnailCaches(entries);
            populateThumbnailsFromCache(entries);
            entries = entriesWorthShowing(entries);
            noteChromeSelectionChanges(entries);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!atomic_load(&g_gestureActive)) {
                    g_windowEntries = entries;
                    atomic_store(&g_windowEntryCount, (int)entries.count);
                    if (g_ringView) g_ringView.entries = entries;
                    if (atomic_load(&g_settingShowSiteIcons)) {
                        for (RingEntry *entry in entries) if (entry.tabURL.length) (void)RingFaviconForURL(entry.tabURL);
                    }
                    if (g_thumbnailPreviewsEnabled) schedulePendingThumbnailCapture(entries);
                    if (g_thumbnailPreviewsEnabled) scheduleChromeBackgroundPrefetch(entries);
                }
                atomic_store(&g_isScanning, false);
            });
        }
    });
}

// A closed window or app should leave the ring at once, not after the next
// two-second scan. The visible windows and their titles are cheap to read, so
// they are compared a few times a second; closing a Chrome tab changes its
// window's title. Any change starts a full scan.
static dispatch_source_t g_windowChangeTimer;
static void startWindowChangeWatch(void) {
    static NSString *s_lastSignature;
    dispatch_queue_t queue = dispatch_queue_create("touchpad.ring.window-watch", DISPATCH_QUEUE_SERIAL);
    g_windowChangeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(g_windowChangeTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 3)),
                              NSEC_PER_SEC / 3, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_windowChangeTimer, ^{
        if (atomic_load(&g_gestureActive)) return;
        @autoreleasepool {
            CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                            kCGNullWindowID);
            if (!windows) return;
            NSMutableString *signature = [NSMutableString string];
            for (NSDictionary *info in (__bridge NSArray *)windows) {
                if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
                [signature appendFormat:@"%@|%@\n", info[(id)kCGWindowNumber], info[(id)kCGWindowName] ?: @""];
            }
            CFRelease(windows);
            if (s_lastSignature && ![signature isEqualToString:s_lastSignature]) scanWindowsNow();
            s_lastSignature = signature;
        }
    });
    dispatch_resume(g_windowChangeTimer);
}

static BOOL settingBool(CFStringRef key, BOOL fallback) {
    Boolean valid = false;
    Boolean value = CFPreferencesGetAppBooleanValue(key, kSettingsID, &valid);
    return valid ? value : fallback;
}

// A per-user LaunchAgent opens the installed app at login. Keep this separate
// from a manually added Login Item, so the setting can remove exactly its own job.
static NSString *loginAgentPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/LaunchAgents/com.milev.touchpad-switcher.autostart.plist"];
}

static BOOL syncLoginAgent(BOOL enabled, NSError **error) {
    NSString *installed = @"/Applications/Touchpad Switcher.app";
    // Running the development bundle must not change the installed app's login setting.
    if (![NSBundle.mainBundle.bundlePath.stringByStandardizingPath isEqualToString:installed]) return YES;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *path = loginAgentPath();
    if (enabled) {
        if (![files fileExistsAtPath:installed]) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError
                                               userInfo:@{NSFilePathErrorKey: installed}];
            return NO;
        }
        NSDictionary *job = @{
            @"Label": @"com.milev.touchpad-switcher.autostart",
            @"ProgramArguments": @[@"/usr/bin/open", @"-a", installed],
            @"RunAtLoad": @YES,
        };
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:job
                                         format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
        if (!data) return NO;
        NSString *folder = path.stringByDeletingLastPathComponent;
        if (![files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:error]) return NO;
        NSData *old = [NSData dataWithContentsOfFile:path];
        return [old isEqualToData:data] || [data writeToFile:path options:NSDataWritingAtomic error:error];
    }
    if (![files fileExistsAtPath:path]) return YES;
    // An already loaded job is removed as well; a missing job is harmless.
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = @[@"bootout", [NSString stringWithFormat:@"gui/%d/com.milev.touchpad-switcher.autostart", getuid()]];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if ([task launchAndReturnError:nil]) [task waitUntilExit];
    return [files removeItemAtPath:path error:error];
}

static void storeSetting(CFStringRef key, CFPropertyListRef value) {
    CFPreferencesSetAppValue(key, value, kSettingsID);
    CFPreferencesAppSynchronize(kSettingsID);
}

static void loadSettings(void) {
    Boolean valid = false;
    CFIndex titles = CFPreferencesGetAppIntegerValue(CFSTR("CardTitles"), kSettingsID, &valid);
    atomic_store(&g_settingCardTitles, valid && titles >= CardTitlesAll && titles <= CardTitlesNone
                                           ? (int)titles : CardTitlesAll);
    // AutoPauseMedia replaces PauseVideoOnTabSwitch and keeps its old value.
    g_mediaOptions.pauseWhenLeaving = settingBool(CFSTR("AutoPauseMedia"),
                                                  settingBool(CFSTR("PauseVideoOnTabSwitch"), YES));
    g_mediaOptions.resumeWhenReturning = settingBool(CFSTR("AutoResumeMedia"), YES);
    g_mediaOptions.resumeManuallyPaused = settingBool(CFSTR("MediaResumeManuallyPaused"), NO);
    g_mediaOptions.followAllTabChanges = settingBool(CFSTR("MediaFollowAllTabChanges"), YES);
    g_mediaOptions.onlyWhenNextTabHasVideo = settingBool(CFSTR("MediaOnlyWhenNextTabHasVideo"), NO);
    g_mediaOptions.rewindAfterLongPause = settingBool(CFSTR("MediaRewindAfterLongPause"), YES);
    atomic_store(&g_settingFinderTabsOneCard, settingBool(CFSTR("FinderTabsAsOneCard"), YES));
    Boolean groupingValid = false;
    CFIndex grouping = CFPreferencesGetAppIntegerValue(CFSTR("CardGrouping"), kSettingsID, &groupingValid);
    atomic_store(&g_settingCardGrouping, groupingValid && grouping == CardGroupingApps ? CardGroupingApps : CardGroupingWindows);
    atomic_store(&g_settingSoundEffects, settingBool(CFSTR("SoundEffects"), NO));
    atomic_store(&g_settingMouseHoldToSelect, settingBool(CFSTR("MouseHoldToSelect"), YES));
    atomic_store(&g_settingShowSiteIcons, settingBool(CFSTR("ShowSiteIcons"), YES));
    atomic_store(&g_settingShowAppIcons, settingBool(CFSTR("ShowAppIcons"), YES));
    Boolean pointerValid = false;
    CFIndex pointerStyle = CFPreferencesGetAppIntegerValue(CFSTR("PointerStyle"), kSettingsID, &pointerValid);
    atomic_store(&g_settingPointerStyle, pointerValid && pointerStyle >= PointerStyleArrow && pointerStyle <= PointerStyleHidden
                                             ? (int)pointerStyle : PointerStyleHidden);
    Boolean blurValid = false;
    CFIndex blurRadius = CFPreferencesGetAppIntegerValue(CFSTR("BlurRadius"), kSettingsID, &blurValid);
    atomic_store(&g_settingBlurRadius, blurValid ? (int)MIN(MAX(blurRadius, 0), 40) : 15);
    Boolean mouseButtonValid = false;
    CFIndex mouseButton = CFPreferencesGetAppIntegerValue(CFSTR("MouseActivationButton"), kSettingsID,
                                                          &mouseButtonValid);
    if (mouseButtonValid && mouseButton == kMouseActivationLegacyF18) {
        mouseButton = kMouseActivationKeyBase + 79;   // earlier builds stored F18 as 100
    }
    BOOL mouseButtonKnown = (mouseButton >= 2 && mouseButton <= 31) ||
        (mouseButton >= kMouseActivationKeyBase && mouseButton <= kMouseActivationKeyBase + 127) ||
        mouseButton == kMouseActivationSwipeBack || mouseButton == kMouseActivationSwipeForward;
    atomic_store(&g_settingMouseButton, mouseButtonValid && mouseButtonKnown ? (int)mouseButton : -1);
    g_selectSound = [[NSSound soundNamed:@"Tink"] copy];
    g_selectSound.volume = 0.3;
    g_activateSound = [[NSSound soundNamed:@"Pop"] copy];
    g_activateSound.volume = 0.45;
    BOOL hideIcon = settingBool(CFSTR("HideMenuBarIcon"), NO);
    // Opening the app again while it runs is the way back to a hidden icon.
    if (hideIcon && g_replacedRunningInstance) {
        hideIcon = NO;
        storeSetting(CFSTR("HideMenuBarIcon"), kCFBooleanFalse);
    }
    atomic_store(&g_settingHideMenuIcon, hideIcon);
    NSError *loginError = nil;
    if (!syncLoginAgent(settingBool(CFSTR("StartAtLogin"), YES), &loginError)) {
        NSLog(@"Automatsko pokretanje nije podešeno: %@", loginError);
    }
}

// macOS gestures that also use three fingers: three-finger drag moves the
// cursor during a pick, three-finger swipes switch Spaces or open Mission
// Control at the same time. Built-in and Magic Trackpad keep separate values.
static BOOL threeFingerSystemGesturesOn(void) {
    CFStringRef domains[] = {CFSTR("com.apple.AppleMultitouchTrackpad"),
                             CFSTR("com.apple.driver.AppleBluetoothMultitouch.trackpad")};
    for (size_t i = 0; i < sizeof(domains) / sizeof(domains[0]); i++) {
        CFStringRef domain = domains[i];
        CFPreferencesAppSynchronize(domain);
        Boolean valid = false;
        if (CFPreferencesGetAppBooleanValue(CFSTR("TrackpadThreeFingerDrag"), domain, &valid) && valid) return YES;
        if (CFPreferencesGetAppIntegerValue(CFSTR("TrackpadThreeFingerHorizSwipeGesture"), domain, &valid) == 2 && valid) return YES;
        if (CFPreferencesGetAppIntegerValue(CFSTR("TrackpadThreeFingerVertSwipeGesture"), domain, &valid) == 2 && valid) return YES;
    }
    return NO;
}

// Media switches in the order the panel shows them; the tag of each checkbox
// is its index here.
typedef struct { CFStringRef key; NSString *title; } MediaOptionRow;
static BOOL *mediaOptionField(RingMediaOptions *options, NSInteger row) {
    switch (row) {
        case 0: return &options->pauseWhenLeaving;
        case 1: return &options->resumeWhenReturning;
        case 2: return &options->resumeManuallyPaused;
        case 3: return &options->followAllTabChanges;
        case 4: return &options->onlyWhenNextTabHasVideo;
        default: return &options->rewindAfterLongPause;
    }
}
static MediaOptionRow mediaOptionRow(NSInteger row) {
    switch (row) {
        case 0: return (MediaOptionRow){CFSTR("AutoPauseMedia"), @"Zaustavi video kad napustiš tab ili Chrome"};
        case 1: return (MediaOptionRow){CFSTR("AutoResumeMedia"), @"Pokreni ga ponovo kad se vratiš"};
        case 2: return (MediaOptionRow){CFSTR("MediaResumeManuallyPaused"), @"Pokreni i video koji si sam pauzirao"};
        case 3: return (MediaOptionRow){CFSTR("MediaFollowAllTabChanges"), @"Važi i za klik na tab i prečice"};
        case 4: return (MediaOptionRow){CFSTR("MediaOnlyWhenNextTabHasVideo"), @"Zaustavi samo ako novi tab ima video"};
        default: return (MediaOptionRow){CFSTR("MediaRewindAfterLongPause"), @"Posle duže pauze vrati malo unazad"};
    }
}
static const NSInteger kMediaOptionRowCount = 6;

// Updating from GitHub. `make install-ring` stores the folder the app was
// built from; the Update button pulls there, rebuilds and starts the new
// version, which replaces this one (single instance).
static NSString *sourceRepositoryPath(void) {
    NSString *path = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("SourceRepository"), kSettingsID));
    if (![path isKindOfClass:[NSString class]]) return nil;
    BOOL isFolder = NO;
    NSString *gitFolder = [path stringByAppendingPathComponent:@".git"];
    return [NSFileManager.defaultManager fileExistsAtPath:gitFolder isDirectory:&isFolder] && isFolder ? path : nil;
}

static int runTool(NSString *folder, NSArray<NSString *> *arguments, NSString **outputOut) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = arguments;
    task.currentDirectoryURL = [NSURL fileURLWithPath:folder];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    // Apps started from Finder get a short PATH; git's GitHub login helper
    // (gh) usually lives in Homebrew.
    environment[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    environment[@"GIT_TERMINAL_PROMPT"] = @"0";   // never wait for a password nobody can type
    task.environment = environment;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        if (outputOut) *outputOut = error.localizedDescription;
        return -1;
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (outputOut) *outputOut = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return task.terminationStatus;
}

// Last line of a tool's output, short enough for the panel.
static NSString *lastOutputLine(NSString *output) {
    NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString *line in lines.reverseObjectEnumerator) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) return trimmed.length > 160 ? [[trimmed substringToIndex:160] stringByAppendingString:@"…"] : trimmed;
    }
    return @"nepoznata greška";
}

// The settings window behaves like Diktat's: the menu bar icon toggles it, and
// Esc, Cmd+W or a click into another app closes it. It handles Esc and Cmd+W
// itself because a menu bar app has no main menu to route them.
@interface SettingsWindow : NSWindow
@end

@implementation SettingsWindow
- (BOOL)canBecomeKeyWindow { return YES; }

- (void)sendEvent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (event.type == NSEventTypeKeyDown && event.keyCode == kEscapeKeyCode && flags == 0) {
        [self performClose:nil];
        return;
    }
    if (event.type == NSEventTypeKeyDown && flags == NSEventModifierFlagCommand &&
        [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"w"]) {
        [self performClose:nil];
        return;
    }
    [super sendEvent:event];
}
@end

@interface SettingsMenu : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) SettingsWindow *window;
@property(nonatomic, strong) NSTextField *javaScriptHint;
@property(nonatomic, strong) NSTextField *blurLabel;
@property(nonatomic, strong) NSTextField *gestureWarning;
@property(nonatomic, strong) NSTextField *mouseActivationLabel;
@property(nonatomic, strong) NSTextField *mouseLearnStatus;
@property(nonatomic, strong) NSButton *updateButton;
@property(nonatomic, strong) NSTextField *updateStatus;
@property(nonatomic, strong) RingRelease *latestRelease;
@property(nonatomic) NSTimeInterval lastUpdateCheck;
@end

@implementation SettingsMenu
- (instancetype)init {
    self = [super init];
    if (self) {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(mouseButtonLearned:)
                                                   name:kMouseButtonLearnedNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSString *)mouseActivationTitle:(int)value {
    if (value == kMouseActivationSwipeBack) return @"bočno dugme Back";
    if (value == kMouseActivationSwipeForward) return @"bočno dugme Forward";
    if (value >= kMouseActivationKeyBase) {
        int keyCode = value - kMouseActivationKeyBase;
        static const struct { int code; const char *name; } functionKeys[] = {
            {105, "F13"}, {107, "F14"}, {113, "F15"}, {106, "F16"},
            {64, "F17"}, {79, "F18"}, {80, "F19"}, {90, "F20"},
        };
        for (size_t i = 0; i < sizeof(functionKeys) / sizeof(functionKeys[0]); i++) {
            if (functionKeys[i].code == keyCode) {
                return [NSString stringWithFormat:@"taster %s", functionKeys[i].name];
            }
        }
        return [NSString stringWithFormat:@"taster (kod %d)", keyCode];
    }
    if (value == 2) return @"srednje dugme miša";
    if (value > 2) return [NSString stringWithFormat:@"dugme miša %d", value + 1];
    return @"isključeno";
}

- (void)refreshMouseActivationLabel {
    self.mouseActivationLabel.stringValue = [NSString stringWithFormat:@"Trenutno: %@",
        [self mouseActivationTitle:atomic_load(&g_settingMouseButton)]];
}

- (void)mouseButtonLearned:(NSNotification *)notification {
    int learned = [notification.userInfo[@"button"] intValue];
    [self refreshMouseActivationLabel];
    if (learned == -1) {
        self.mouseLearnStatus.stringValue = @"Snimanje otkazano.";
        self.mouseLearnStatus.textColor = NSColor.secondaryLabelColor;
    } else {
        self.mouseLearnStatus.stringValue = [NSString stringWithFormat:@"Snimljeno: %@.",
                                             [self mouseActivationTitle:learned]];
        self.mouseLearnStatus.textColor = NSColor.systemGreenColor;
    }
    self.mouseLearnStatus.hidden = NO;
    [self fitWindow];
}

- (void)showIcon {
    if (self.statusItem) return;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"hand.draw" accessibilityDescription:@"Touchpad Switcher"];
    if (image) {
        image.template = YES;
        self.statusItem.button.image = image;
    } else {
        self.statusItem.button.title = @"TS";
    }
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePanel:);
}

// The window is laid out like Diktat's settings: buttons centered on top and
// three columns side by side instead of one tall column.
static const CGFloat kSettingsColumnWidth = 330;
static const CGFloat kSettingsColumnGap = 22;   // on each side of the divider line
static const CGFloat kSettingsSectionGap = 26;  // before a section title
static const CGFloat kSettingsTitleGap = 12;    // after a section title

- (NSTextField *)noteWithText:(NSString *)text {
    NSTextField *note = [NSTextField wrappingLabelWithString:text];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;
    note.preferredMaxLayoutWidth = kSettingsColumnWidth;
    return note;
}

- (NSTextField *)sectionTitle:(NSString *)text {
    NSTextField *title = [NSTextField labelWithString:text];
    title.font = [NSFont boldSystemFontOfSize:15];
    return title;
}

- (NSStackView *)settingsColumn:(NSArray<NSView *> *)rows {
    NSStackView *column = [NSStackView stackViewWithViews:rows];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeLeading;
    column.spacing = 8;
    [column.widthAnchor constraintEqualToConstant:kSettingsColumnWidth].active = YES;
    // A row wider than the column was centered and lost its left margin.
    // Rows may not be squeezed: labels gave way first and vanished, instead
    // of the window growing to fit them.
    for (NSView *row in rows) {
        [row.widthAnchor constraintLessThanOrEqualToConstant:kSettingsColumnWidth].active = YES;
        [row setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                      forOrientation:NSLayoutConstraintOrientationVertical];
    }
    return column;
}

- (NSView *)panelContent {
    self.gestureWarning = [self noteWithText:
        @"macOS takođe koristi tri prsta (prevlačenje ili prelazak između ekrana), pa se kursor ili ekran pomera dok biraš. "
         "Isključi prevlačenje sa tri prsta u System Settings > Accessibility > Pointer Control > Trackpad Options, "
         "a pokrete za Mission Control i ekrane prebaci na četiri prsta u System Settings > Trackpad > More Gestures."];
    self.gestureWarning.textColor = NSColor.systemOrangeColor;

    NSTextField *cardsTitle = [self sectionTitle:@"Kartice"];
    NSSegmentedControl *grouping = [NSSegmentedControl segmentedControlWithLabels:@[@"Prozori i tabovi", @"Samo aplikacije"]
                                                                     trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                           target:self
                                                                           action:@selector(cardGroupingChanged:)];
    grouping.controlSize = NSControlSizeSmall;
    grouping.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    grouping.selectedSegment = atomic_load(&g_settingCardGrouping);

    NSTextField *titlesLabel = [self noteWithText:@"Naslovi na karticama"];
    NSSegmentedControl *titles = [NSSegmentedControl segmentedControlWithLabels:@[@"Svi prozori", @"Finder i Chrome", @"Bez naslova"]
                                                                   trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                         target:self
                                                                         action:@selector(cardTitlesChanged:)];
    titles.controlSize = NSControlSizeSmall;
    titles.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    titles.selectedSegment = atomic_load(&g_settingCardTitles);

    NSButton *siteIcons = [NSButton checkboxWithTitle:@"Ikonice sajtova na Chrome karticama"
                                               target:self action:@selector(siteIconsChanged:)];
    siteIcons.state = atomic_load(&g_settingShowSiteIcons) ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton *appIcons = [NSButton checkboxWithTitle:@"Ikonice aplikacija na karticama"
                                              target:self action:@selector(appIconsChanged:)];
    appIcons.state = atomic_load(&g_settingShowAppIcons) ? NSControlStateValueOn : NSControlStateValueOff;

    NSTextField *pointerLabel = [self noteWithText:@"Pokazivač"];
    NSSegmentedControl *pointer = [NSSegmentedControl segmentedControlWithLabels:@[@"Strelica", @"Krug", @"Nevidljiv"]
                                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                          target:self
                                                                          action:@selector(pointerStyleChanged:)];
    pointer.controlSize = NSControlSizeSmall;
    pointer.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    pointer.selectedSegment = atomic_load(&g_settingPointerStyle);

    NSTextField *mouseTitle = [self sectionTitle:@"Aktivacija mišem"];
    self.mouseActivationLabel = [NSTextField labelWithString:@""];
    self.mouseActivationLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [self refreshMouseActivationLabel];
    NSButton *learnMouseButton = [NSButton buttonWithTitle:@"Snimi dugme"
                                                   target:self
                                                   action:@selector(learnMouseButton:)];
    learnMouseButton.controlSize = NSControlSizeSmall;
    NSButton *disableMouseButton = [NSButton buttonWithTitle:@"Isključi"
                                                     target:self
                                                     action:@selector(disableMouseActivation:)];
    disableMouseButton.controlSize = NSControlSizeSmall;
    NSStackView *mouseButtons = [NSStackView stackViewWithViews:@[learnMouseButton, disableMouseButton]];
    mouseButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    mouseButtons.spacing = 8;
    self.mouseLearnStatus = [self noteWithText:@""];
    self.mouseLearnStatus.hidden = YES;
    NSButton *holdToSelect = [NSButton checkboxWithTitle:@"Drži dugme i pusti ga na kartici"
                                                 target:self action:@selector(mouseHoldChanged:)];
    holdToSelect.state = atomic_load(&g_settingMouseHoldToSelect) ? NSControlStateValueOn : NSControlStateValueOff;
    NSTextField *mouseNote = [self noteWithText:
        @"Klikni „Snimi dugme“, pa pritisni željeno dugme miša (Esc otkazuje). Bez držanja: klik otvara meni, pomeri miš ka kartici, pa isto dugme ili levi klik bira. "
         "Logi Back/Forward ne javlja kad je dugme pušteno, pa uvek radi na klik; za držanje mu u Logi Options+ dodeli Middle button."];

    NSTextField *mediaTitle = [self sectionTitle:@"Video u Chrome-u"];
    NSMutableArray<NSView *> *mediaRows = [NSMutableArray array];
    for (NSInteger row = 0; row < kMediaOptionRowCount; row++) {
        NSButton *box = [NSButton checkboxWithTitle:mediaOptionRow(row).title
                                             target:self action:@selector(mediaOptionChanged:)];
        box.tag = row;
        box.state = *mediaOptionField(&g_mediaOptions, row) ? NSControlStateValueOn : NSControlStateValueOff;
        [mediaRows addObject:box];
    }
    NSTextField *mediaNote = [self noteWithText:
        @"Bez treće opcije pokreće se samo video koji je ova aplikacija zaustavila. Sa opcijom „samo ako novi tab ima video“ "
         "stari video svira dalje dok ne pređeš na tab sa videom, a izlazak iz Chrome-a ga ne zaustavlja. "
         "Unazad: 2 s posle pola minuta, 5 s posle 5 minuta."];
    self.javaScriptHint = [self noteWithText:
        @"Chrome ne dozvoljava upravljanje videom. U Chrome-u uključi View > Developer > Allow JavaScript from Apple Events."];
    self.javaScriptHint.textColor = NSColor.systemOrangeColor;

    NSButton *finderTabs = [NSButton checkboxWithTitle:@"Finder tabovi jednog prozora kao jedna kartica"
                                                target:self action:@selector(finderTabsChanged:)];
    finderTabs.state = atomic_load(&g_settingFinderTabsOneCard) ? NSControlStateValueOn : NSControlStateValueOff;

    NSButton *sounds = [NSButton checkboxWithTitle:@"Zvučni efekti pri izboru i otvaranju"
                                            target:self action:@selector(soundEffectsChanged:)];
    sounds.state = atomic_load(&g_settingSoundEffects) ? NSControlStateValueOn : NSControlStateValueOff;

    self.blurLabel = [self noteWithText:@""];
    [self updateBlurLabel];
    NSSlider *blur = [NSSlider sliderWithValue:atomic_load(&g_settingBlurRadius) minValue:0 maxValue:40
                                        target:self action:@selector(blurRadiusChanged:)];
    blur.controlSize = NSControlSizeSmall;
    [blur.widthAnchor constraintEqualToConstant:kSettingsColumnWidth].active = YES;

    NSButton *hideIcon = [NSButton checkboxWithTitle:@"Sakrij ikonicu iz gornje trake"
                                              target:self action:@selector(hideIconChanged:)];
    NSTextField *hideNote = [self noteWithText:@"Ikonica se vraća kad ponovo otvoriš aplikaciju."];
    NSButton *startAtLogin = [NSButton checkboxWithTitle:@"Pokreni pri uključivanju računara"
                                                  target:self action:@selector(startAtLoginChanged:)];
    startAtLogin.state = settingBool(CFSTR("StartAtLogin"), YES)
        ? NSControlStateValueOn : NSControlStateValueOff;

    NSButton *quit = [NSButton buttonWithTitle:@"Ugasi Touchpad Switcher" target:NSApp action:@selector(terminate:)];
    NSString *installedVersion = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    self.updateButton = [NSButton buttonWithTitle:[NSString stringWithFormat:@"Proveri ažuriranje (%@)", installedVersion]
                                         target:self action:@selector(updateApp:)];
    self.updateStatus = [self noteWithText:@""];
    self.updateStatus.hidden = YES;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.updateButton, quit]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 8;

    NSTextField *lookTitle = [self sectionTitle:@"Izgled menija"];
    NSTextField *menuBarTitle = [self sectionTitle:@"Gornja traka"];

    NSStackView *cardsColumn = [self settingsColumn:@[cardsTitle, grouping, titlesLabel, titles, siteIcons, appIcons,
                                                      finderTabs, lookTitle, pointerLabel, pointer,
                                                      self.blurLabel, blur, sounds]];
    [cardsColumn setCustomSpacing:kSettingsTitleGap afterView:cardsTitle];
    [cardsColumn setCustomSpacing:14 afterView:grouping];
    [cardsColumn setCustomSpacing:4 afterView:titlesLabel];
    [cardsColumn setCustomSpacing:14 afterView:titles];
    [cardsColumn setCustomSpacing:kSettingsSectionGap afterView:finderTabs];
    [cardsColumn setCustomSpacing:kSettingsTitleGap afterView:lookTitle];
    [cardsColumn setCustomSpacing:4 afterView:pointerLabel];
    [cardsColumn setCustomSpacing:14 afterView:pointer];
    [cardsColumn setCustomSpacing:4 afterView:self.blurLabel];
    [cardsColumn setCustomSpacing:14 afterView:blur];

    NSStackView *mouseColumn = [self settingsColumn:@[mouseTitle, self.mouseActivationLabel, mouseButtons, holdToSelect,
                                                      self.mouseLearnStatus, mouseNote, menuBarTitle, hideIcon, hideNote,
                                                      startAtLogin]];
    [mouseColumn setCustomSpacing:kSettingsTitleGap afterView:mouseTitle];
    [mouseColumn setCustomSpacing:kSettingsSectionGap afterView:mouseNote];
    [mouseColumn setCustomSpacing:kSettingsTitleGap afterView:menuBarTitle];
    [mouseColumn setCustomSpacing:4 afterView:hideIcon];

    NSMutableArray<NSView *> *mediaColumnRows = [NSMutableArray arrayWithObject:mediaTitle];
    [mediaColumnRows addObjectsFromArray:mediaRows];
    [mediaColumnRows addObjectsFromArray:@[mediaNote, self.javaScriptHint]];
    NSStackView *mediaColumn = [self settingsColumn:mediaColumnRows];
    [mediaColumn setCustomSpacing:kSettingsTitleGap afterView:mediaTitle];
    [mediaColumn setCustomSpacing:14 afterView:mediaRows.lastObject];

    // Thin vertical lines between the columns, as tall as the tallest column.
    NSStackView *columns = [NSStackView stackViewWithViews:@[cardsColumn]];
    columns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    columns.alignment = NSLayoutAttributeTop;
    columns.spacing = kSettingsColumnGap;
    for (NSStackView *column in @[mouseColumn, mediaColumn]) {
        NSBox *divider = [NSBox new];
        divider.boxType = NSBoxSeparator;
        [columns addArrangedSubview:divider];
        [divider.widthAnchor constraintEqualToConstant:1].active = YES;
        [divider.heightAnchor constraintEqualToAnchor:columns.heightAnchor].active = YES;
        [columns addArrangedSubview:column];
    }
    CGFloat columnsWidth = 3 * kSettingsColumnWidth + 4 * kSettingsColumnGap + 2;

    self.gestureWarning.preferredMaxLayoutWidth = columnsWidth;
    self.gestureWarning.alignment = NSTextAlignmentCenter;
    self.updateStatus.alignment = NSTextAlignmentCenter;
    self.updateStatus.preferredMaxLayoutWidth = columnsWidth;

    NSStackView *stack = [NSStackView stackViewWithViews:@[buttons, self.updateStatus, self.gestureWarning, columns]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 12;
    [stack setCustomSpacing:28 afterView:self.gestureWarning];
    [stack setCustomSpacing:28 afterView:self.updateStatus];
    [stack setCustomSpacing:28 afterView:buttons];
    [self.gestureWarning.widthAnchor constraintLessThanOrEqualToConstant:columnsWidth].active = YES;
    // Margins as constraints on a container: the stack's own edgeInsets were
    // left out of fittingSize, so the window came out too small and clipped.
    NSView *content = [NSView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-32],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:32],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-32],
        [stack.widthAnchor constraintEqualToConstant:columnsWidth],
    ]];
    return content;
}

- (void)fitWindow {
    if (!self.window) return;
    NSSize size = self.window.contentView.fittingSize;
    NSRect frame = [self.window frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
    NSRect old = self.window.frame;
    // Grow or shrink from the top edge so the title bar stays where it was.
    frame.origin = NSMakePoint(old.origin.x, NSMaxY(old) - frame.size.height);
    [self.window setFrame:frame display:YES];
}

- (void)centerWindow {
    NSScreen *screen = NSScreen.mainScreen ?: self.window.screen;
    if (!screen) return;
    NSRect visible = screen.visibleFrame;
    NSRect frame = self.window.frame;
    [self.window setFrameOrigin:NSMakePoint(round(NSMidX(visible) - frame.size.width / 2),
                                            round(NSMidY(visible) - frame.size.height / 2))];
}

- (void)togglePanel:(id)sender {
    (void)sender;
    if (self.window.isVisible) {
        [self.window performClose:nil];
        return;
    }
    if (!self.window) {
        self.window = [[SettingsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 340, 600)
                                                        styleMask:NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskMiniaturizable
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
        self.window.title = @"Touchpad Switcher — Podešavanja";
        self.window.releasedWhenClosed = NO;
        // Its own place in Mission Control instead of a helper panel above
        // another app's window.
        self.window.collectionBehavior = NSWindowCollectionBehaviorManaged;
        self.window.contentView = [self panelContent];
        self.window.delegate = self;
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationResignedActive:)
                                                   name:NSApplicationDidResignActiveNotification
                                                 object:nil];
    }
    self.gestureWarning.hidden = !threeFingerSystemGesturesOn();
    [self updateJavaScriptHint];
    [self fitWindow];
    [self centerWindow];
    // A regular app while the window is open: Dock icon, Cmd+Tab and Mission
    // Control. windowWillClose: returns to a menu bar app.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self.window makeKeyAndOrderFront:nil];
    activateSelf();
    if (NSDate.date.timeIntervalSince1970 - self.lastUpdateCheck > 60) [self checkForUpdate];
    // The policy change settles on the next turn of the run loop; activating
    // only before it left the window unfocused, so Esc and clicks elsewhere
    // never reached it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!self.window.isVisible) return;
        activateSelf();
        [self.window makeKeyAndOrderFront:nil];
    });
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

// A click into another app closes the window, the same as Esc. The app is
// watched rather than the window, so the menu bar icon still toggles it.
- (void)applicationResignedActive:(NSNotification *)notification {
    (void)notification;
    if (self.window.isVisible) [self.window performClose:nil];
}

- (void)setUpdateMessage:(NSString *)message done:(BOOL)done {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.updateStatus.stringValue = message;
        self.updateStatus.hidden = NO;
        if (done) self.updateButton.enabled = YES;
        [self fitWindow];
    });
}

- (void)checkForUpdate {
    self.lastUpdateCheck = NSDate.date.timeIntervalSince1970;
    self.updateButton.enabled = NO;
    [self setUpdateMessage:@"Proveravam novu verziju na GitHub-u…" done:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        RingRelease *release = RingLatestRelease(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.updateButton.enabled = YES;
            if (!release) {
                self.updateStatus.stringValue = [@"Provera nije uspela: " stringByAppendingString:error.localizedDescription ?: @"GitHub nije dostupan."];
            } else {
                self.latestRelease = release;
                NSString *current = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
                if (RingVersionNewer(current, release.version)) {
                    self.updateButton.title = [NSString stringWithFormat:@"Ažuriraj %@ → %@", current, release.version];
                    self.updateStatus.stringValue = [NSString stringWithFormat:@"Dostupna je nova verzija %@.", release.version];
                } else {
                    self.updateButton.title = [NSString stringWithFormat:@"Proveri ažuriranje (%@)", current];
                    self.updateStatus.stringValue = [NSString stringWithFormat:@"Imaš najnoviju verziju (%@).", current];
                }
            }
            self.updateStatus.hidden = NO;
            [self fitWindow];
        });
    });
}

- (void)updateApp:(NSButton *)button {
    NSString *current = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    RingRelease *release = self.latestRelease;
    if (!release || !RingVersionNewer(current, release.version)) {
        [self checkForUpdate];
        return;
    }
    button.enabled = NO;
    [self setUpdateMessage:[NSString stringWithFormat:@"Preuzimam verziju %@…", release.version] done:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        if (!RingInstallRelease(release, &error)) {
            [self setUpdateMessage:[@"Ažuriranje nije uspelo: " stringByAppendingString:error.localizedDescription ?: @"nepoznata greška"] done:YES];
            return;
        }
        [self setUpdateMessage:@"Gotovo, pokrećem novu verziju…" done:NO];
        // The new instance ends this one as it starts.
        runTool(NSHomeDirectory(), @[@"open", @"-n", @"/Applications/Touchpad Switcher.app"], NULL);
    });
}

- (void)cardTitlesChanged:(NSSegmentedControl *)control {
    int mode = (int)control.selectedSegment;
    atomic_store(&g_settingCardTitles, mode);
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &mode);
    storeSetting(CFSTR("CardTitles"), value);
    CFRelease(value);
}

- (void)siteIconsChanged:(NSButton *)button {
    BOOL on = button.state == NSControlStateValueOn;
    atomic_store(&g_settingShowSiteIcons, on);
    storeSetting(CFSTR("ShowSiteIcons"), on ? kCFBooleanTrue : kCFBooleanFalse);
}

- (void)appIconsChanged:(NSButton *)button {
    BOOL on = button.state == NSControlStateValueOn;
    atomic_store(&g_settingShowAppIcons, on);
    storeSetting(CFSTR("ShowAppIcons"), on ? kCFBooleanTrue : kCFBooleanFalse);
}

- (void)cardGroupingChanged:(NSSegmentedControl *)control {
    int grouping = control.selectedSegment == CardGroupingApps ? CardGroupingApps : CardGroupingWindows;
    atomic_store(&g_settingCardGrouping, grouping);
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &grouping);
    storeSetting(CFSTR("CardGrouping"), value);
    CFRelease(value);
    scanWindowsNow();   // the next ring already shows the new cards
}

- (void)pointerStyleChanged:(NSSegmentedControl *)control {
    int style = (int)MIN(MAX(control.selectedSegment, PointerStyleArrow), PointerStyleHidden);
    atomic_store(&g_settingPointerStyle, style);
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &style);
    storeSetting(CFSTR("PointerStyle"), value);
    CFRelease(value);
    [g_ringView resetPointer];   // rebuilt with the new shape on the next open
}

- (void)disableMouseActivation:(NSButton *)button {
    (void)button;
    atomic_store(&g_mouseButtonLearning, false);
    persistMouseActivationSetting(-1);
    [self refreshMouseActivationLabel];
    self.mouseLearnStatus.hidden = YES;
    [self fitWindow];
}

- (void)learnMouseButton:(NSButton *)button {
    (void)button;
    atomic_store(&g_mouseButtonLearning, true);
    self.mouseLearnStatus.stringValue = @"Čekam… pritisni željeno dugme miša (Esc otkazuje).";
    self.mouseLearnStatus.textColor = NSColor.systemOrangeColor;
    self.mouseLearnStatus.hidden = NO;
    [self fitWindow];
}

- (void)mediaOptionChanged:(NSButton *)button {
    BOOL on = button.state == NSControlStateValueOn;
    *mediaOptionField(&g_mediaOptions, button.tag) = on;
    storeSetting(mediaOptionRow(button.tag).key, on ? kCFBooleanTrue : kCFBooleanFalse);
    RingMediaSetOptions(g_mediaOptions);
    [self updateJavaScriptHint];
}

- (void)updateJavaScriptHint {
    self.javaScriptHint.hidden = !(RingMediaJavaScriptBlocked() &&
                                   (g_mediaOptions.pauseWhenLeaving || g_mediaOptions.resumeWhenReturning));
    [self fitWindow];
}

- (void)finderTabsChanged:(NSButton *)button {
    BOOL on = button.state == NSControlStateValueOn;
    atomic_store(&g_settingFinderTabsOneCard, on);
    storeSetting(CFSTR("FinderTabsAsOneCard"), on ? kCFBooleanTrue : kCFBooleanFalse);
}

- (void)mouseHoldChanged:(NSButton *)button {
    BOOL on = button.state == NSControlStateValueOn;
    atomic_store(&g_settingMouseHoldToSelect, on);
    storeSetting(CFSTR("MouseHoldToSelect"), on ? kCFBooleanTrue : kCFBooleanFalse);
}

- (void)soundEffectsChanged:(NSButton *)button {
    BOOL on = button.state == NSControlStateValueOn;
    atomic_store(&g_settingSoundEffects, on);
    storeSetting(CFSTR("SoundEffects"), on ? kCFBooleanTrue : kCFBooleanFalse);
    if (on) playRingSound(g_activateSound);
}

- (void)updateBlurLabel {
    int radius = atomic_load(&g_settingBlurRadius);
    self.blurLabel.stringValue = radius > 0
        ? [NSString stringWithFormat:@"Zamućenje pozadine: %d", radius]
        : @"Zamućenje pozadine: isključeno";
}

- (void)blurRadiusChanged:(NSSlider *)slider {
    int radius = (int)lround(slider.doubleValue);
    atomic_store(&g_settingBlurRadius, radius);
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &radius);
    storeSetting(CFSTR("BlurRadius"), value);
    CFRelease(value);
    [self updateBlurLabel];
}

- (void)hideIconChanged:(NSButton *)button {
    if (button.state != NSControlStateValueOn) return;
    atomic_store(&g_settingHideMenuIcon, true);
    storeSetting(CFSTR("HideMenuBarIcon"), kCFBooleanTrue);
    [self.window performClose:nil];
    if (self.statusItem) [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
    self.statusItem = nil;
}

- (void)startAtLoginChanged:(NSButton *)button {
    BOOL enabled = button.state == NSControlStateValueOn;
    NSError *error = nil;
    if (!syncLoginAgent(enabled, &error)) {
        button.state = enabled ? NSControlStateValueOff : NSControlStateValueOn;
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Automatsko pokretanje nije podešeno";
        alert.informativeText = error.localizedDescription ?: @"Proveri dozvole za LaunchAgents folder.";
        [alert runModal];
        return;
    }
    storeSetting(CFSTR("StartAtLogin"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
}
@end

static SettingsMenu *g_settingsMenu;

static void handleSignal(int signalNumber) {
    (void)signalNumber;
    printf("\nStopping Touchpad Ring Test...\n");
    showSystemCursorAfterGesture();
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
        loadSettings();
        g_settingsMenu = [SettingsMenu new];
        if (!atomic_load(&g_settingHideMenuIcon)) [g_settingsMenu showIcon];
        RingMediaStart(g_mediaOptions);
        RingFaviconsSetLoadedHandler(^{
            if (g_ringView && atomic_load(&g_ringOverlayVisible)) [g_ringView setNeedsDisplay:YES];
        });
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
        g_lastSelectedChromeTabKeys = [NSMutableDictionary dictionary];
        g_chromeForceCaptureKeys = [NSMutableSet set];
        g_thumbnailRequests = [NSMutableSet set];
        g_tabThumbnailRequests = [NSMutableSet set];
        g_tabLastCaptured = [NSMutableDictionary dictionary];
        g_windowLastCaptured = [NSMutableDictionary dictionary];
        g_tabCachedURL = [NSMutableDictionary dictionary];
        g_chromeCaptureURLs = [NSMutableDictionary dictionary];
        g_windowActivationQueue = dispatch_queue_create("touchpad.ring.window-activation", DISPATCH_QUEUE_SERIAL);
        g_liveCaptureQueue = dispatch_queue_create("touchpad.ring.live-capture", DISPATCH_QUEUE_SERIAL);
        g_windowEntries = collectOpenWindows();
        populateThumbnailsFromCache(g_windowEntries);
        g_windowEntries = entriesWorthShowing(g_windowEntries);
        atomic_store(&g_windowEntryCount, (int)g_windowEntries.count);
        if (g_thumbnailPreviewsEnabled) schedulePendingThumbnailCapture(g_windowEntries);
        if (g_thumbnailPreviewsEnabled) scheduleChromeBackgroundPrefetch(g_windowEntries);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ensureChromeAutomation(YES)) {
                NSArray<RingEntry *> *entries = collectOpenWindows();
                populateThumbnailsFromCache(entries);
                entries = entriesWorthShowing(entries);
                g_windowEntries = entries;
                atomic_store(&g_windowEntryCount, (int)entries.count);
                if (g_ringView) g_ringView.entries = entries;
                if (g_thumbnailPreviewsEnabled) schedulePendingThumbnailCapture(entries);
                if (g_thumbnailPreviewsEnabled) scheduleChromeBackgroundPrefetch(entries);
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
        [workspaceCenter addObserver:g_wakeObserver
                            selector:@selector(applicationTerminated:)
                                name:NSWorkspaceDidTerminateApplicationNotification
                              object:nil];
        [workspaceCenter addObserver:g_wakeObserver
                            selector:@selector(applicationDeactivated:)
                                name:NSWorkspaceDidDeactivateApplicationNotification
                              object:nil];
        [[NSDistributedNotificationCenter defaultCenter] addObserver:g_wakeObserver
                                                            selector:@selector(appearanceChanged:)
                                                                name:@"AppleInterfaceThemeChangedNotification"
                                                              object:nil];
        g_windowScanQueue = dispatch_queue_create("touchpad.ring.window-scan", DISPATCH_QUEUE_SERIAL);
        g_scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_windowScanQueue);
        dispatch_source_set_timer(g_scanTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                  (uint64_t)(2.0 * NSEC_PER_SEC),
                                  (uint64_t)(100 * NSEC_PER_MSEC));
        dispatch_source_set_event_handler(g_scanTimer, ^{ scanWindowsNow(); });
        startWindowChangeWatch();
        dispatch_resume(g_scanTimer);
        [NSApp run];
    }
    return 0;
}
