// Experimental three-finger radial window switcher.
// A deliberate movement selects a window direction; lifting all three fingers activates it.

#import <Cocoa/Cocoa.h>
#import <ScriptingBridge/ScriptingBridge.h>
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
@property(nonatomic) BOOL isSettings;
@property(nonatomic) BOOL isShortcut;
@property(nonatomic) BOOL opensNewChromeTab;
@property(nonatomic) BOOL minimizesAllWindows;
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
@property(nonatomic) CGFloat ringRadiusY;
@property(nonatomic, strong) NSArray<NSValue *> *layoutRects;
@property(nonatomic, strong) NSArray<RingEntry *> *layoutEntries;
@property(nonatomic) NSSize layoutSize;
@property(nonatomic, strong) NSArray<NSNumber *> *layoutThumbnailShapes;
@property(nonatomic) NSUInteger layoutAdornmentFlags;
@property(nonatomic, strong) NSView *pointerView;
@property(nonatomic, strong) CAShapeLayer *pointerArrow;
@property(nonatomic, weak) NSView *glowView;
@property(nonatomic) NSPoint lastPointer;
@property(nonatomic) CGFloat pointerAngle;
@property(nonatomic, strong) NSMutableArray<CALayer *> *cardLayers;
@property(nonatomic, strong) CALayer *hubLayer;
@property(nonatomic, strong) RingEntry *currentEntry;
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

// Šira centralna zona poništava izbor. Različita granica pri izlasku
// sprečava treperenje izbora kada se prsti zadrže blizu sredine.
static const double kPointerDeadZone = 0.22;
static const double kPointerSelectZone = 0.28;
// Half the size of the center area in points: the selected app's icon lives
// there, the arrow rides on its edge and the light starts from it.
static const CGFloat kHubRadius = 56.0;
// The pointer stays inside the ring of cards; only its direction matters.
static const double kPointerReach = 0.80;

// Settings from the menu bar panel. Stored under one ID so the bare binary
// and the .app bundle share them; read from the scan, touch and main threads.
#define kSettingsID CFSTR("com.milev.touchpad-switcher")
typedef enum { CardTitlesAll = 0, CardTitlesFinderAndChrome = 1, CardTitlesNone = 2 } CardTitlesMode;
static _Atomic(int) g_settingCardTitles = CardTitlesNone;
static RingMediaOptions g_mediaOptions;   // main thread; the media module keeps its own copy
static _Atomic(bool) g_settingFinderTabsOneCard = false;
typedef enum { CardGroupingWindows = 0, CardGroupingApps = 1 } CardGrouping;
static _Atomic(int) g_settingCardGrouping = CardGroupingWindows;
// Poseban meni prečica: nema ga, drži se Cmd, dodaje se četvrti prst, ili oba.
typedef enum {
    ShortcutTriggerNone = 0,
    ShortcutTriggerCommand = 1,
    ShortcutTriggerFourFingers = 2,
    ShortcutTriggerBoth = 3,
} ShortcutTrigger;
static _Atomic(int) g_settingShortcutTrigger = ShortcutTriggerCommand;
static _Atomic(bool) g_settingHideMenuIcon = false;
static _Atomic(bool) g_settingSoundEffects = false;
// Mouse activation by holding the button and releasing it on a card. Off: one
// click opens the ring and a second click (or a left click) picks the card.
static _Atomic(bool) g_settingMouseHoldToSelect = true;
static _Atomic(bool) g_settingShowSiteIcons = true;   // Chrome tabs: the site's icon
static _Atomic(bool) g_settingShowAppIcons = true;    // other windows: the app's icon
static _Atomic(int) g_settingBlurRadius = 20;   // 0 turns the blur off
static _Atomic(int) g_settingBackdropZoom = 5;  // percentage beyond screen size
static _Atomic(bool) g_settingCurrentWindowInCenter = false;
// -1 disables mouse activation. Values 2...31 are Quartz mouse button numbers
// (middle is 2, the usual side buttons 3 and 4); kMouseActivationKeyBase plus a
// key code is a recorded key, such as F18 sent by Logi Options+.
// kMouseActivationSwipeBack/Forward are the side buttons with Logi Options+'s
// default Back/Forward assignment, which arrive as a synthetic swipe.
static _Atomic(int) g_settingMouseButton = -1;
typedef enum { PointerStyleArrow = 0, PointerStyleDot = 1, PointerStyleHidden = 2 } PointerStyle;
static _Atomic(int) g_settingPointerStyle = PointerStyleHidden;
// Boja pokazivača i svetla iza kartica: akcentna boja
// color from System Settings > Appearance, like the rest of macOS, or white.
typedef enum { HighlightSystem = 0, HighlightWhite = 1 } HighlightColor;
static _Atomic(int) g_settingHighlightColor = HighlightSystem;
static _Atomic(bool) g_settingShowLight = true;   // light in the direction of the fingers
// The backdrop behind the cards: a color laid over the (blurred) screen.
static _Atomic(int) g_settingBackdropDimming = 50;   // percent
static NSColor *g_backdropColor;                     // main thread; nil is near black

static NSColor *ringHighlightColor(void) {
    if (atomic_load(&g_settingHighlightColor) == HighlightWhite) return [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1];
    return [NSColor.controlAccentColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.systemBlueColor;
}
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
    if (entry.isShortcut) return YES;
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

static const CGFloat kSelectedCardScale = 1.20;
// I izbor po smeru prati elipsu koja je izračunata za trenutne prozore.
static _Atomic(double) g_layoutAxisRatio = 1.0;
static _Atomic(double) g_layoutCardAngles[512];
static _Atomic(NSUInteger) g_layoutAngleCount = 0;
static CGFloat cardFooterHeight(CGFloat width) {
    if (atomic_load(&g_settingCardTitles)==CardTitlesNone)
        return MIN(56.0,MAX(24.0,width*0.15))*0.40+4;
    return MAX(26.0,width*0.14);
}

// Elipsa sabija prazninu po visini kada su snimci pretežno horizontalni.
static void ringEllipseRadii(NSUInteger count, CGFloat baseRadius, CGFloat *outRadiusX, CGFloat *outRadiusY) {
    if (outRadiusX) *outRadiusX = baseRadius;
    if (outRadiusY) *outRadiusY = baseRadius * atomic_load(&g_layoutAxisRatio);
}

static CGFloat rawItemAngle(NSInteger i, NSUInteger count) {
    return count ? (CGFloat)M_PI_2 - (CGFloat)(2.0 * M_PI * i / count) : 0;
}

// Najkraći razmak između ivica dva pravougaonika, uključujući dijagonalu.
static CGFloat rectangleGap(NSPoint a, NSSize sa, NSPoint b, NSSize sb) {
    return hypot(MAX(0, fabs(a.x - b.x) - (sa.width + sb.width) / 2),
                 MAX(0, fabs(a.y - b.y) - (sa.height + sb.height) / 2));
}

// Samo jedna kartica može biti uvećana. Za svaku osu čuva se prostor
// za veći od oba moguća izbora, umesto za dva istovremena zooma.
static CGFloat zoomReservedPairGap(NSPoint a, NSSize scaledA, NSPoint b, NSSize scaledB) {
    CGFloat halfX=MAX(scaledA.width+scaledB.width/kSelectedCardScale,
                      scaledA.width/kSelectedCardScale+scaledB.width)/2;
    CGFloat halfY=MAX(scaledA.height+scaledB.height/kSelectedCardScale,
                      scaledA.height/kSelectedCardScale+scaledB.height)/2;
    return hypot(MAX(0,fabs(a.x-b.x)-halfX),MAX(0,fabs(a.y-b.y)-halfY));
}

static NSSize layoutCardSize(NSSize unit, CGFloat longSide) {
    CGFloat width = unit.width * longSide;
    return NSMakeSize(width, unit.height * longSide + cardFooterHeight(width));
}

static NSRect visibleCardRect(RingEntry *entry, NSRect card);

// Traži najkrupnije snimke i najkompaktniju elipsu bez sudara, sa prostorom
// za selekciju, susede i centralnu ikonicu. Računa se jednom po otvaranju.
static NSArray<NSValue *> *adaptiveCardLayout(NSArray<RingEntry *> *entries, NSSize screen,
                                             CGFloat *outX, CGFloat *outY) {
    NSUInteger count = entries.count;
    if (!count) { *outX = *outY = 0; return @[]; }
    NSSize *units = calloc(count, sizeof(NSSize));
    NSSize *sizes = calloc(count, sizeof(NSSize));
    NSPoint *directions = calloc(count, sizeof(NSPoint));
    for (NSUInteger i = 0; i < count; i++) {
        NSImage *image = resolvedThumbnail(entries[i]);
        NSSize size = image.size;
        CGFloat longest = MAX(size.width, size.height);
        units[i] = longest > 0 ? NSMakeSize(size.width / longest, size.height / longest) : NSMakeSize(0.28, 0.28);
        CGFloat angle = rawItemAngle(i, count);
        directions[i] = NSMakePoint(cos(angle), sin(angle));
    }
    CGFloat bestSize = 0, bestRadius = 0, bestRatio = 1, bestArea = CGFLOAT_MAX;
    for (int shape = 0; shape <= 36; shape++) {
        CGFloat ratio = 0.35 + shape * 0.05;
        // Veličinu ograničava slobodan prostor ekrana, umesto fiksnih 480 pt.
        CGFloat low = 0, high = MIN(screen.width, screen.height) * 0.85;
        CGFloat acceptedRadius = 0;
        for (int pass = 0; pass < 19; pass++) {
            CGFloat candidate = (low + high) / 2;
            CGFloat maximumRadius = CGFLOAT_MAX;
            for (NSUInteger i = 0; i < count; i++) {
                sizes[i] = layoutCardSize(units[i], candidate);
                sizes[i].width *= kSelectedCardScale;
                sizes[i].height *= kSelectedCardScale;
                CGFloat x = fabs(directions[i].x), y = fabs(directions[i].y) * ratio;
                if (x > 0.001) maximumRadius = MIN(maximumRadius, (screen.width / 2 - 44 - sizes[i].width / 2) / x);
                if (y > 0.001) maximumRadius = MIN(maximumRadius, (screen.height / 2 - 44 - sizes[i].height / 2) / y);
            }
            CGFloat minimumRadius = 0, upperRadius = MAX(0, maximumRadius);
            BOOL fits = maximumRadius > 0;
            // Binarna pretraga najmanjeg poluprečnika pri zadatoj veličini.
            for (int radiusPass = 0; radiusPass < 17; radiusPass++) {
                CGFloat radius = (minimumRadius + upperRadius) / 2;
                BOOL clear = YES;
                for (NSUInteger i = 0; i < count && clear; i++) {
                    NSPoint a = NSMakePoint(directions[i].x * radius, directions[i].y * radius * ratio);
                    clear = rectangleGap(a, sizes[i], NSZeroPoint, NSMakeSize(kHubRadius * 2, kHubRadius * 2)) >= 30;
                    for (NSUInteger j = i + 1; j < count && clear; j++) {
                        NSPoint b = NSMakePoint(directions[j].x * radius, directions[j].y * radius * ratio);
                        clear = zoomReservedPairGap(a, sizes[i], b, sizes[j]) >= 24;
                    }
                }
                if (clear) upperRadius = radius;
                else minimumRadius = radius;
            }
            // Provera i na gornjoj granici sprečava prihvatanje nemogućeg rasporeda.
            for (NSUInteger i = 0; i < count && fits; i++) {
                NSPoint a = NSMakePoint(directions[i].x * upperRadius, directions[i].y * upperRadius * ratio);
                fits = rectangleGap(a, sizes[i], NSZeroPoint, NSMakeSize(kHubRadius * 2, kHubRadius * 2)) >= 29.99;
                for (NSUInteger j = i + 1; j < count && fits; j++) {
                    NSPoint b = NSMakePoint(directions[j].x * upperRadius, directions[j].y * upperRadius * ratio);
                    fits = zoomReservedPairGap(a, sizes[i], b, sizes[j]) >= 23.99;
                }
            }
            if (fits) { low = candidate; acceptedRadius = upperRadius; }
            else high = candidate;
        }
        CGFloat area = acceptedRadius * acceptedRadius * ratio;
        if (low > bestSize + 0.1 || (fabs(low - bestSize) <= 0.1 && area < bestArea)) {
            bestSize = low; bestRadius = acceptedRadius; bestRatio = ratio; bestArea = area;
        }
    }
    NSPoint *positions = calloc(count, sizeof(NSPoint));
    NSPoint *adjustments = calloc(count, sizeof(NSPoint));
    for (NSUInteger i = 0; i < count; i++) {
        sizes[i] = layoutCardSize(units[i], bestSize);
        positions[i] = NSMakePoint(directions[i].x * bestRadius, directions[i].y * bestRadius * bestRatio);
    }
    // Zatvara preostale praznine između suseda. Sile deluju po najkraćoj
    // liniji između ivica, umesto po rastojanju centara pravougaonika.
    for (int pass = 0; pass < 180; pass++) {
        memset(adjustments, 0, count * sizeof(NSPoint));
        for (NSUInteger i = 0; i < count; i++) {
            for (NSUInteger j = i + 1; j < count; j++) {
                CGFloat dx = positions[j].x - positions[i].x;
                CGFloat dy = positions[j].y - positions[i].y;
                CGFloat halfX = MAX(sizes[i].width*kSelectedCardScale+sizes[j].width,
                                    sizes[i].width+sizes[j].width*kSelectedCardScale)/2;
                CGFloat halfY = MAX(sizes[i].height*kSelectedCardScale+sizes[j].height,
                                    sizes[i].height+sizes[j].height*kSelectedCardScale)/2;
                CGFloat gapX = MAX(0, fabs(dx) - halfX), gapY = MAX(0, fabs(dy) - halfY);
                CGFloat distance = hypot(gapX, gapY);
                BOOL neighbors = j == i + 1 || (i == 0 && j == count - 1);
                CGFloat force = neighbors ? (distance - 24) * 0.10 : MIN(0, distance - 24) * 0.20;
                CGFloat nx, ny;
                if (distance > 0.001) {
                    nx = copysign(gapX / distance, dx); ny = copysign(gapY / distance, dy);
                } else {
                    BOOL horizontal = halfX - fabs(dx) < halfY - fabs(dy);
                    nx = horizontal ? (dx >= 0 ? 1 : -1) : 0;
                    ny = horizontal ? 0 : (dy >= 0 ? 1 : -1);
                    force = -(24 + MIN(halfX - fabs(dx), halfY - fabs(dy))) * 0.20;
                }
                adjustments[i].x += nx * force; adjustments[i].y += ny * force;
                adjustments[j].x -= nx * force; adjustments[j].y -= ny * force;
            }
        }
        for (NSUInteger i = 0; i < count; i++) {
            positions[i].x += adjustments[i].x;
            positions[i].y += adjustments[i].y;
            CGFloat halfX = sizes[i].width * kSelectedCardScale / 2 + kHubRadius;
            CGFloat halfY = sizes[i].height * kSelectedCardScale / 2 + kHubRadius;
            CGFloat gapX = MAX(0, fabs(positions[i].x) - halfX);
            CGFloat gapY = MAX(0, fabs(positions[i].y) - halfY);
            CGFloat distance = hypot(gapX, gapY);
            if (distance < 30) {
                if (distance > 0.001) {
                    positions[i].x += copysign(gapX / distance * (30-distance), positions[i].x);
                    positions[i].y += copysign(gapY / distance * (30-distance), positions[i].y);
                } else if (halfX - fabs(positions[i].x) < halfY - fabs(positions[i].y)) {
                    positions[i].x = copysign(halfX + 30, positions[i].x);
                } else {
                    positions[i].y = copysign(halfY + 30, positions[i].y);
                }
            }
            CGFloat limitX = MAX(0, screen.width/2 - 44 - sizes[i].width*kSelectedCardScale/2);
            CGFloat limitY = MAX(0, screen.height/2 - 44 - sizes[i].height*kSelectedCardScale/2);
            positions[i].x = MAX(-limitX, MIN(limitX, positions[i].x));
            positions[i].y = MAX(-limitY, MIN(limitY, positions[i].y));
        }
    }
    // Kompaktiranje se prihvata samo kada ostanu redosled, razmaci i rezerva
    // za susede. Složena kombinacija zadržava prethodno proverenu elipsu.
    BOOL compactFits = YES;
    for (NSUInteger i = 0; i < count && compactFits; i++) {
        NSSize scaled = NSMakeSize(sizes[i].width*kSelectedCardScale, sizes[i].height*kSelectedCardScale);
        compactFits = rectangleGap(positions[i], scaled, NSZeroPoint, NSMakeSize(kHubRadius*2,kHubRadius*2)) >= 28;
        if (count > 2) {
            NSPoint next = positions[(i+1)%count];
            CGFloat step = fmod(atan2(positions[i].y,positions[i].x)-atan2(next.y,next.x)+2*M_PI,2*M_PI);
            compactFits = compactFits && step > 0.02 && step < M_PI-0.02;
        }
        for (NSUInteger j = i+1; j < count && compactFits; j++) {
            NSSize other = NSMakeSize(sizes[j].width*kSelectedCardScale, sizes[j].height*kSelectedCardScale);
            compactFits = zoomReservedPairGap(positions[i],scaled,positions[j],other) >= 24;
        }
    }
    if (!compactFits) for (NSUInteger i = 0; i < count; i++) {
        positions[i] = NSMakePoint(directions[i].x * bestRadius, directions[i].y * bestRadius * bestRatio);
    }
    // Posle sabijanja koristi preostale margine za uvećanje cele grupe.
    // Proporcije snimaka ostaju iste, a rezerva obuhvata zoom i pomeranje suseda.
    CGFloat expansionLow=1,expansionHigh=2;
    for (int pass=0;pass<18;pass++) {
        CGFloat scale=(expansionLow+expansionHigh)/2;
        NSRect envelope=NSMakeRect(-kHubRadius,-kHubRadius,kHubRadius*2,kHubRadius*2);
        NSRect visible=envelope;
        for (NSUInteger i=0;i<count;i++) {
            NSSize expanded=layoutCardSize(units[i],bestSize*scale);
            NSPoint center=NSMakePoint(positions[i].x*scale,positions[i].y*scale);
            NSRect card=NSMakeRect(center.x-expanded.width/2,center.y-expanded.height/2,expanded.width,expanded.height);
            visible=NSUnionRect(visible,visibleCardRect(entries[i],card));
            envelope=NSUnionRect(envelope,NSMakeRect(center.x-expanded.width*kSelectedCardScale/2,
                center.y-expanded.height*kSelectedCardScale/2,expanded.width*kSelectedCardScale,expanded.height*kSelectedCardScale));
        }
        BOOL fits=NSMinX(envelope)-NSMidX(visible)>=-screen.width/2+26 &&
                  NSMaxX(envelope)-NSMidX(visible)<=screen.width/2-26 &&
                  NSMinY(envelope)-NSMidY(visible)>=-screen.height/2+26 &&
                  NSMaxY(envelope)-NSMidY(visible)<=screen.height/2-26;
        if (fits) expansionLow=scale;
        else expansionHigh=scale;
    }
    for (NSUInteger i=0;i<count;i++) {
        positions[i].x*=expansionLow;
        positions[i].y*=expansionLow;
        sizes[i]=layoutCardSize(units[i],bestSize*expansionLow);
    }
    bestRadius*=expansionLow;
    NSMutableArray *rects = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSSize size = sizes[i];
        NSPoint center = NSMakePoint(screen.width / 2 + positions[i].x, screen.height / 2 + positions[i].y);
        [rects addObject:[NSValue valueWithRect:NSMakeRect(center.x - size.width / 2,
                                                         center.y - size.height / 2, size.width, size.height)]];
    }
    free(positions); free(adjustments);
    free(units); free(sizes); free(directions);
    *outX = bestRadius; *outY = bestRadius * bestRatio;
    return rects;
}

// Najveći slobodan krug za centralnu ikonicu u srednjem delu rasporeda.
// Računaju se ivice sa rezervom za zoom, a ne prosek centara slika.
static CGFloat hubClearance(NSArray<NSValue *> *rects, NSPoint point) {
    CGFloat clearance = CGFLOAT_MAX;
    for (NSValue *value in rects) {
        NSRect rect = value.rectValue;
        NSSize size = NSMakeSize(NSWidth(rect)*kSelectedCardScale, NSHeight(rect)*kSelectedCardScale);
        clearance = MIN(clearance, rectangleGap(point, NSMakeSize(kHubRadius*2,kHubRadius*2),
            NSMakePoint(NSMidX(rect),NSMidY(rect)), size));
    }
    return clearance;
}

// Vidljiva površina kartice, bez prazne rezerve oko ikonice i naziva.
static NSRect visibleCardRect(RingEntry *entry, NSRect card) {
    CGFloat footer = cardFooterHeight(NSWidth(card));
    NSRect content = NSMakeRect(NSMinX(card), NSMinY(card)+footer,
                                NSWidth(card), MAX(1,NSHeight(card)-footer));
    NSImage *thumbnail = resolvedThumbnail(entry);
    NSRect visible;
    if (thumbnail.size.width>0 && thumbnail.size.height>0) {
        CGFloat fit = MIN(NSWidth(content)/thumbnail.size.width,NSHeight(content)/thumbnail.size.height);
        NSSize size = NSMakeSize(thumbnail.size.width*fit,thumbnail.size.height*fit);
        visible = NSMakeRect(NSMidX(content)-size.width/2,NSMidY(content)-size.height/2,size.width,size.height);
        BOOL chrome = [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"];
        BOOL badge = (chrome && atomic_load(&g_settingShowSiteIcons)) || atomic_load(&g_settingShowAppIcons);
        if (badge && entry.icon) {
            CGFloat side = MIN(56.0,MAX(24.0,NSWidth(card)*0.15));
            visible = NSUnionRect(visible,NSMakeRect(NSMidX(content)-side/2,NSMinY(content)-side*0.40,side,side));
        }
    } else {
        CGFloat side = MIN(144.0,NSHeight(content)*0.85);
        visible = NSMakeRect(NSMidX(content)-side/2,NSMidY(content)-side/2,side,side);
    }
    if (shouldDrawCardLabel(entry) && cardLabelText(entry).length)
        visible = NSUnionRect(visible,NSMakeRect(NSMinX(card),NSMinY(card),NSWidth(card),16));
    return visible;
}

// Ujednačava razmake do vidljivih ivica, uz rezervu za uvećanje kartica.
static CGFloat hubGapVariation(NSArray<NSValue *> *visibleRects, NSPoint point) {
    CGFloat sum=0, squares=0;
    for (NSValue *value in visibleRects) {
        NSRect rect=value.rectValue;
        CGFloat gap=rectangleGap(point,NSMakeSize(kHubRadius*2,kHubRadius*2),
            NSMakePoint(NSMidX(rect),NSMidY(rect)),rect.size);
        sum+=gap;
        squares+=gap*gap;
    }
    CGFloat mean=sum/MAX(1,visibleRects.count);
    return sqrt(MAX(0,squares/MAX(1,visibleRects.count)-mean*mean));
}

static NSPoint balancedHubPoint(NSArray<RingEntry *> *entries, NSArray<NSValue *> *rects, NSSize screen) {
    NSPoint origin=NSMakePoint(screen.width/2,screen.height/2);
    if (rects.count<3) return origin;
    NSMutableArray *visible=[NSMutableArray arrayWithCapacity:rects.count];
    for (NSUInteger i=0;i<rects.count;i++)
        [visible addObject:[NSValue valueWithRect:visibleCardRect(entries[i],rects[i].rectValue)]];
    NSPoint best=origin;
    CGFloat range=MIN(100.0,MIN(screen.width,screen.height)*0.16);
    CGFloat step=range/3;
    CGFloat minimumClearance=MIN(28.0,hubClearance(rects,origin));
    CGFloat score=hubGapVariation(visible,best);
    for (int pass=0;pass<8;pass++) {
        NSPoint center=best;
        for (int x=-3;x<=3;x++) for (int y=-3;y<=3;y++) {
            NSPoint candidate=NSMakePoint(center.x+x*step,center.y+y*step);
            if (fabs(candidate.x-origin.x)>range || fabs(candidate.y-origin.y)>range ||
                hubClearance(rects,candidate)<minimumClearance ||
                candidate.x<kHubRadius || candidate.x>screen.width-kHubRadius ||
                candidate.y<kHubRadius || candidate.y>screen.height-kHubRadius) continue;
            CGFloat candidateScore=hubGapVariation(visible,candidate)+hypot(candidate.x-origin.x,candidate.y-origin.y)*0.002;
            if (candidateScore<score) { score=candidateScore; best=candidate; }
        }
        step/=3;
    }
    return best;
}

static NSRect visibleLayoutBounds(NSArray<RingEntry *> *entries, NSArray<NSValue *> *rects, NSPoint hub) {
    NSRect bounds = NSMakeRect(hub.x-kHubRadius,hub.y-kHubRadius,kHubRadius*2,kHubRadius*2);
    for (NSUInteger i=0;i<rects.count;i++) bounds=NSUnionRect(bounds,visibleCardRect(entries[i],rects[i].rectValue));
    return bounds;
}

// Cela grupa se pomera kao jedna celina; međusobni razmaci se ne menjaju.
// Rezerva za izabranu karticu i susede sprečava izlazak pri zoomu.
static NSPoint centeredLayoutOffset(NSArray<RingEntry *> *entries, NSArray<NSValue *> *rects,
                                    NSPoint hub, NSSize screen) {
    if (!rects.count) return NSZeroPoint;
    NSRect visible = visibleLayoutBounds(entries,rects,hub);
    NSPoint offset = NSMakePoint(screen.width/2-NSMidX(visible),screen.height/2-NSMidY(visible));
    NSRect envelope = NSMakeRect(hub.x-kHubRadius,hub.y-kHubRadius,kHubRadius*2,kHubRadius*2);
    for (NSValue *value in rects) {
        NSRect rect=value.rectValue;
        CGFloat halfX=NSWidth(rect)*kSelectedCardScale/2+18;
        CGFloat halfY=NSHeight(rect)*kSelectedCardScale/2+18;
        envelope=NSUnionRect(envelope,NSMakeRect(NSMidX(rect)-halfX,NSMidY(rect)-halfY,halfX*2,halfY*2));
    }
    offset.x=MAX(8-NSMinX(envelope),MIN(screen.width-8-NSMaxX(envelope),offset.x));
    offset.y=MAX(8-NSMinY(envelope),MIN(screen.height-8-NSMaxY(envelope),offset.y));
    return offset;
}

// Direction of a card as seen on screen (the ring is an ellipse, so this is not
// the raw layout angle).
static CGFloat cardScreenAngle(NSInteger i, NSUInteger count) {
    if (i >= 0 && (NSUInteger)i < count && count == atomic_load(&g_layoutAngleCount))
        return atomic_load(&g_layoutCardAngles[i]);
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
    [self refreshColors];
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

// Brightest at the center, fading out toward the edge of the screen along a
// smooth curve, so no ring shows where two straight segments would meet. The
// accent color is kept soft, a little whiter at the center, as macOS draws
// its own highlights; white is fainter still.
- (void)refreshColors {
    NSColor *color = ringHighlightColor();
    BOOL white = atomic_load(&g_settingHighlightColor) == HighlightWhite;
    CGFloat peak = white ? 0.26 : 0.34;
    NSMutableArray *colors = [NSMutableArray array], *locations = [NSMutableArray array];
    const int stops = 12;
    for (int i = 0; i <= stops; i++) {
        CGFloat t = (CGFloat)i / stops;
        CGFloat fade = (1.0 - t) * (1.0 - t);
        CGFloat whiten = 0.35 * fade;
        [colors addObject:(id)[NSColor colorWithSRGBRed:color.redComponent + (1.0 - color.redComponent) * whiten
                                                  green:color.greenComponent + (1.0 - color.greenComponent) * whiten
                                                   blue:color.blueComponent + (1.0 - color.blueComponent) * whiten
                                                  alpha:peak * fade].CGColor];
        [locations addObject:@(t)];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _gradient.colors = colors;
    _gradient.locations = locations;
    [CATransaction commit];
}

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
    if (!atomic_load(&g_settingShowLight)) return;
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
    [self refreshColors];   // the accent color or the style may have changed
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

- (void)prepareCardLayout {
    NSMutableArray<NSNumber *> *shapes = [NSMutableArray arrayWithCapacity:self.entries.count];
    for (RingEntry *entry in self.entries) {
        NSSize size = resolvedThumbnail(entry).size;
        [shapes addObject:@(size.width > 0 && size.height > 0 ? size.height/size.width : 0)];
    }
    NSUInteger flags = atomic_load(&g_settingCardTitles)*4 + atomic_load(&g_settingShowAppIcons)*2 + atomic_load(&g_settingShowSiteIcons);
    if (self.layoutEntries == self.entries && NSEqualSizes(self.layoutSize, self.bounds.size) &&
        self.layoutAdornmentFlags == flags && [self.layoutThumbnailShapes isEqualToArray:shapes]) return;
    self.layoutAdornmentFlags = flags;
    self.layoutThumbnailShapes = shapes;
    CGFloat radiusX, radiusY;
    self.layoutRects = adaptiveCardLayout(self.entries, self.bounds.size, &radiusX, &radiusY);
    self.layoutEntries = self.entries;
    self.layoutSize = self.bounds.size;
    self.ringRadius = radiusX;
    self.ringRadiusY = radiusY;
    self.anchorPoint = balancedHubPoint(self.entries,self.layoutRects,self.bounds.size);
    NSPoint offset = centeredLayoutOffset(self.entries,self.layoutRects,self.anchorPoint,self.bounds.size);
    NSMutableArray *centeredRects = [NSMutableArray arrayWithCapacity:self.layoutRects.count];
    for (NSValue *value in self.layoutRects)
        [centeredRects addObject:[NSValue valueWithRect:NSOffsetRect(value.rectValue,offset.x,offset.y)]];
    self.layoutRects = centeredRects;
    self.anchorPoint = NSMakePoint(self.anchorPoint.x+offset.x,self.anchorPoint.y+offset.y);
    atomic_store(&g_layoutAxisRatio, radiusX > 0 ? radiusY / radiusX : 1);
    NSUInteger count = self.layoutRects.count;
    if (count <= 512) for (NSUInteger i = 0; i < count; i++) {
        NSRect rect = self.layoutRects[i].rectValue;
        atomic_store(&g_layoutCardAngles[i], atan2(NSMidY(rect)-self.anchorPoint.y, NSMidX(rect)-self.anchorPoint.x));
    }
    atomic_store(&g_layoutAngleCount, count <= 512 ? count : 0);
}

- (NSRect)cardRectForIndex:(NSInteger)index {
    [self prepareCardLayout];
    return index >= 0 && index < (NSInteger)self.layoutRects.count ? self.layoutRects[index].rectValue : NSZeroRect;
}

static const CGFloat kCardImagePadding = 24.0;

// Slika kartice sa prostorom za senku oko thumbnaila.
- (id)cardImageForIndex:(NSInteger)index rect:(NSRect)rect {
    CGFloat scale = self.window.backingScaleFactor ?: 2.0;
    NSRect imageRect = NSInsetRect(rect, -kCardImagePadding, -kCardImagePadding);
    size_t pixelsWide = (size_t)ceil(NSWidth(imageRect) * scale);
    size_t pixelsHigh = (size_t)ceil(NSHeight(imageRect) * scale);
    if (pixelsWide == 0 || pixelsHigh == 0) return nil;
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, pixelsWide, pixelsHigh, 8, 0, sRGB,
                                                (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(sRGB);
    if (!bitmap) return nil;
    CGContextScaleCTM(bitmap, scale, scale);
    CGContextTranslateCTM(bitmap, -NSMinX(imageRect), -NSMinY(imageRect));
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:NO];
    [self drawCardForEntry:self.entries[(NSUInteger)index] inRect:rect];
    [NSGraphicsContext restoreGraphicsState];
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    return CFBridgingRelease(image);
}

// Svaka kartica ima svoj sloj, bez duplikata iza uvećanog thumbnaila.
- (void)updateCardLayersAnimated:(BOOL)animated refreshContents:(BOOL)refresh {
    [self prepareCardLayout];
    if (!self.cardLayers) self.cardLayers = [NSMutableArray array];
    BOOL rebuilt = self.cardLayers.count != self.entries.count;
    if (rebuilt) {
        for (CALayer *layer in self.cardLayers) [layer removeFromSuperlayer];
        [self.cardLayers removeAllObjects];
        for (NSUInteger i = 0; i < self.entries.count; i++) {
            CALayer *layer = [CALayer layer];
            [self.layer addSublayer:layer];
            [self.cardLayers addObject:layer];
        }
    }
    NSInteger selected = self.selectedIndex;
    BOOL hasSelection = selected >= 0 && selected < (NSInteger)self.entries.count;
    NSRect selectedRect = hasSelection ? [self cardRectForIndex:selected] : NSZeroRect;
    for (NSUInteger i = 0; i < self.cardLayers.count; i++) {
        CALayer *layer = self.cardLayers[i];
        CALayer *shown = (CALayer *)layer.presentationLayer ?: layer;
        CGPoint fromPosition = shown.position;
        NSNumber *fromScale = [shown valueForKeyPath:@"transform.scale"] ?: @1.0;
        CGFloat fromGlow = shown.shadowOpacity;
        NSRect rect = [self cardRectForIndex:i];
        CGPoint position = CGPointMake(NSMidX(rect), NSMidY(rect));
        BOOL isSelected = hasSelection && (NSInteger)i == selected;
        if (hasSelection && !isSelected) {
            // Oba suseda se odmaknu od izabrane kartice, do 18 tačaka.
            NSUInteger distance = MIN((i + self.entries.count - selected) % self.entries.count,
                                      (selected + self.entries.count - i) % self.entries.count);
            if (distance == 1) {
                CGFloat dx = position.x - NSMidX(selectedRect);
                CGFloat dy = position.y - NSMidY(selectedRect);
                CGFloat length = hypot(dx, dy);
                CGFloat push = MIN(18.0, NSWidth(selectedRect) * 0.055);
                if (length > 0) {
                    position.x += dx / length * push;
                    position.y += dy / length * push;
                }
            }
        }
        CGFloat scale = isSelected ? kSelectedCardScale : 1.0;
        // Uvećanje i pomeranje ostaju unutar ivica ekrana.
        CGFloat halfWidth = NSWidth(rect) * scale / 2.0 + 8.0;
        CGFloat halfHeight = NSHeight(rect) * scale / 2.0 + 8.0;
        position.x = MAX(halfWidth, MIN(NSWidth(self.bounds) - halfWidth, position.x));
        position.y = MAX(halfHeight, MIN(NSHeight(self.bounds) - halfHeight, position.y));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.bounds = CGRectMake(0, 0, NSWidth(rect) + kCardImagePadding * 2,
                                        NSHeight(rect) + kCardImagePadding * 2);
        layer.position = position;
        layer.contentsScale = self.window.backingScaleFactor ?: 2.0;
        if (refresh || rebuilt) layer.contents = [self cardImageForIndex:i rect:rect];
        layer.zPosition = isSelected ? 5 : 1;
        // Mekan sjaj prati oblik kartice, bez okvira i pomerene senke.
        layer.shadowColor = ringHighlightColor().CGColor;
        layer.shadowRadius = 22.0;
        layer.shadowOffset = CGSizeZero;
        layer.shadowOpacity = isSelected ? 0.42 : 0.0;
        CGRect glowRect = CGRectInset(layer.bounds, kCardImagePadding, kCardImagePadding);
        CGFloat footer = cardFooterHeight(NSWidth(rect));
        glowRect.origin.y += footer;
        glowRect.size.height -= footer;
        NSImage *thumbnail = resolvedThumbnail(self.entries[i]);
        if (thumbnail.size.width > 0 && thumbnail.size.height > 0) {
            CGFloat fit = MIN(glowRect.size.width / thumbnail.size.width,
                              glowRect.size.height / thumbnail.size.height);
            CGSize imageSize = CGSizeMake(thumbnail.size.width * fit, thumbnail.size.height * fit);
            glowRect = CGRectMake(CGRectGetMidX(glowRect) - imageSize.width / 2,
                                  CGRectGetMidY(glowRect) - imageSize.height / 2,
                                  imageSize.width, imageSize.height);
        }
        CGPathRef glowPath = thumbnail
            ? CGPathCreateWithRoundedRect(glowRect, 8.0, 8.0, NULL) : NULL;
        layer.shadowPath = glowPath;
        if (glowPath) CGPathRelease(glowPath);
        layer.transform = CATransform3DMakeScale(scale, scale, 1);
        if (animated && !rebuilt) {
            CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
            glow.fromValue = @(fromGlow);
            glow.toValue = @(layer.shadowOpacity);
            glow.duration = 0.18;
            glow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [layer addAnimation:glow forKey:@"glow"];
            CASpringAnimation *move = [CASpringAnimation animationWithKeyPath:@"position"];
            move.fromValue = [NSValue valueWithPoint:NSPointFromCGPoint(fromPosition)];
            move.toValue = [NSValue valueWithPoint:NSPointFromCGPoint(position)];
            move.stiffness = 320;
            move.damping = 25;
            move.duration = move.settlingDuration;
            [layer addAnimation:move forKey:@"move"];
            CASpringAnimation *zoom = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
            zoom.fromValue = fromScale;
            zoom.toValue = @(scale);
            zoom.stiffness = 320;
            zoom.damping = 24;
            zoom.duration = zoom.settlingDuration;
            [layer addAnimation:zoom forKey:@"zoom"];
        }
        [CATransaction commit];
    }
}

- (void)updateHubAnimated:(BOOL)animated {
    if (!self.hubLayer) {
        self.hubLayer = [CALayer layer];
        self.hubLayer.zPosition = 6;
        self.hubLayer.shadowColor = NSColor.blackColor.CGColor;
        self.hubLayer.shadowOpacity = 0.55;
        self.hubLayer.shadowRadius = 12;
        self.hubLayer.shadowOffset = CGSizeMake(0, -2);
        [self.layer addSublayer:self.hubLayer];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSInteger selected = self.selectedIndex;
    BOOL valid = selected >= 0 && selected < (NSInteger)self.entries.count;
    self.hubLayer.hidden = NO;
    if (self.currentEntry) {
        NSImage *thumbnail = resolvedThumbnail(self.currentEntry);
        NSImage *icon = self.currentEntry.icon;
        NSImage *center = [NSImage imageWithSize:NSMakeSize(112, 112) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            NSRect picture = NSMakeRect(5, 24, 102, 78);
            NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:picture xRadius:10 yRadius:10];
            [[NSColor colorWithWhite:0.08 alpha:0.94] setFill];
            [shape fill];
            if (thumbnail) {
                [NSGraphicsContext saveGraphicsState];
                [shape addClip];
                CGFloat ratio = thumbnail.size.width / MAX(thumbnail.size.height, 1);
                NSRect imageRect = picture;
                if (ratio > NSWidth(picture) / NSHeight(picture)) {
                    imageRect.size.width = NSHeight(picture) * ratio;
                    imageRect.origin.x = NSMidX(picture) - imageRect.size.width / 2;
                } else {
                    imageRect.size.height = NSWidth(picture) / MAX(ratio, 0.01);
                    imageRect.origin.y = NSMidY(picture) - imageRect.size.height / 2;
                }
                [thumbnail drawInRect:imageRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                            fraction:1 respectFlipped:YES hints:nil];
                [NSGraphicsContext restoreGraphicsState];
            } else if (icon) {
                [icon drawInRect:NSInsetRect(picture, 25, 13)];
            }
            [[NSColor colorWithWhite:1 alpha:0.8] setStroke];
            shape.lineWidth = 1.5;
            [shape stroke];
            NSString *label = @"Ostani ovde";
            NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                                    NSForegroundColorAttributeName:NSColor.whiteColor};
            NSSize textSize = [label sizeWithAttributes:attrs];
            [label drawAtPoint:NSMakePoint((NSWidth(rect)-textSize.width)/2, 5) withAttributes:attrs];
            return YES;
        }];
        self.hubLayer.shadowColor = NSColor.blackColor.CGColor;
        self.hubLayer.shadowOpacity = 0.65;
        self.hubLayer.shadowRadius = 12;
        self.hubLayer.shadowOffset = CGSizeMake(0, -2);
        self.hubLayer.shadowPath = NULL;
        self.hubLayer.bounds = CGRectMake(0, 0, 112, 112);
        self.hubLayer.position = NSPointToCGPoint(self.anchorPoint);
        self.hubLayer.contentsScale = self.window.backingScaleFactor ?: 2;
        NSRect imageBounds = NSMakeRect(0, 0, 112, 112);
        self.hubLayer.contents = (__bridge id)[center CGImageForProposedRect:&imageBounds context:nil hints:nil];
    } else if (valid) {
        self.hubLayer.shadowColor=NSColor.blackColor.CGColor;
        self.hubLayer.shadowOpacity=0.55;
        self.hubLayer.shadowRadius=12;
        self.hubLayer.shadowOffset=CGSizeMake(0,-2);
        self.hubLayer.shadowPath=NULL;
        RingEntry *entry = self.entries[(NSUInteger)selected];
        NSImage *siteIcon = [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"] &&
                            atomic_load(&g_settingShowSiteIcons) ? RingFaviconForURL(entry.tabURL) : nil;
        NSImage *icon = siteIcon ?: entry.icon;
        CGFloat size = siteIcon ? kHubRadius * 1.25 : kHubRadius * 1.8;
        self.hubLayer.bounds = CGRectMake(0, 0, size, size);
        self.hubLayer.position = NSPointToCGPoint(self.anchorPoint);
        self.hubLayer.contentsScale = self.window.backingScaleFactor ?: 2.0;
        NSRect iconRect = NSMakeRect(0, 0, size, size);
        self.hubLayer.contents = (__bridge id)[icon CGImageForProposedRect:&iconRect context:nil hints:nil];
        if (animated) {
            CALayer *shown = (CALayer *)self.hubLayer.presentationLayer ?: self.hubLayer;
            NSNumber *fromScale = [shown valueForKeyPath:@"transform.scale"] ?: @1.0;
            CAKeyframeAnimation *pop = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
            pop.values = @[fromScale, @0.86, @1.16, @1.0];
            pop.keyTimes = @[@0, @0.16, @0.5, @1];
            pop.duration = 0.34;
            pop.calculationMode = kCAAnimationCubic;
            [self.hubLayer addAnimation:pop forKey:@"pop"];
        }
    } else {
        CALayer *shown=(CALayer *)self.hubLayer.presentationLayer ?: self.hubLayer;
        NSNumber *fromScale=[shown valueForKeyPath:@"transform.scale"] ?: @1;
        self.hubLayer.shadowColor=ringHighlightColor().CGColor;
        self.hubLayer.shadowOpacity=0.42;
        self.hubLayer.shadowRadius=22;
        self.hubLayer.shadowOffset=CGSizeZero;
        BOOL showLabel=atomic_load(&g_settingCardTitles)!=CardTitlesNone;
        NSImage *cancel=[NSImage imageWithSize:NSMakeSize(112,112) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            CGFloat shift=showLabel ? 0 : -13;
            [[NSColor colorWithWhite:0.08 alpha:0.92] setFill];
            NSBezierPath *circle=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(22,35+shift,68,68)];
            [circle fill];
            [[NSColor colorWithSRGBRed:1 green:0.48 blue:0.44 alpha:1] setStroke];
            circle.lineWidth=2; [circle stroke];
            NSBezierPath *cross=[NSBezierPath bezierPath];
            cross.lineWidth=5; cross.lineCapStyle=NSLineCapStyleRound;
            [cross moveToPoint:NSMakePoint(44,57+shift)]; [cross lineToPoint:NSMakePoint(68,81+shift)];
            [cross moveToPoint:NSMakePoint(44,81+shift)]; [cross lineToPoint:NSMakePoint(68,57+shift)];
            [cross stroke];
            NSString *label=@"Otpusti za izlazak";
            NSDictionary *attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName:NSColor.whiteColor};
            NSSize size=[label sizeWithAttributes:attrs];
            if (showLabel) [label drawAtPoint:NSMakePoint((rect.size.width-size.width)/2,12) withAttributes:attrs];
            return YES;
        }];
        CGPathRef cancelGlow=CGPathCreateWithEllipseInRect(CGRectMake(22,showLabel ? 35 : 22,68,68),NULL);
        self.hubLayer.shadowPath=cancelGlow;
        CGPathRelease(cancelGlow);
        self.hubLayer.bounds=CGRectMake(0,0,112,112);
        self.hubLayer.position=NSPointToCGPoint(self.anchorPoint);
        self.hubLayer.contentsScale=self.window.backingScaleFactor ?: 2;
        NSRect rect=NSMakeRect(0,0,112,112);
        self.hubLayer.contents=(__bridge id)[cancel CGImageForProposedRect:&rect context:nil hints:nil];
        if (animated) {
            CAKeyframeAnimation *pop=[CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
            pop.values=@[fromScale,@0.86,@1.16,@1.0];
            pop.keyTimes=@[@0,@0.16,@0.5,@1];
            pop.duration=0.34;
            pop.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [self.hubLayer addAnimation:pop forKey:@"pop"];
        }
    }
    [CATransaction commit];
}

- (void)resetSelectionVisuals {
    for (CALayer *layer in self.cardLayers) [layer removeFromSuperlayer];
    self.cardLayers = nil;
    [self.hubLayer removeFromSuperlayer];
    self.hubLayer = nil;
    [(SectorGlowView *)self.glowView hideAnimated:NO];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    if (_selectedIndex == selectedIndex) return;
    _selectedIndex = selectedIndex;
    [self updateCardLayersAnimated:YES refreshContents:NO];
    [self updateHubAnimated:YES];
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
    BOOL created = !self.pointerView;
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
        arrow.strokeColor = ringHighlightColor().CGColor;
        arrow.lineWidth = 1.5;
        arrow.lineJoin = kCALineJoinRound;
        arrow.shadowColor = ringHighlightColor().CGColor;
        arrow.shadowOpacity = 0.8;
        arrow.shadowRadius = 6.0;
        arrow.shadowOffset = CGSizeZero;
        arrow.affineTransform = CGAffineTransformMakeRotation((CGFloat)M_PI_2);
        [holder.layer addSublayer:arrow];
        holder.hidden = atomic_load(&g_settingPointerStyle) == PointerStyleHidden;
        holder.layer.zPosition = 10;   // iznad kartica
        [self addSubview:holder];
        self.pointerView = holder;
        self.pointerArrow = arrow;
    }
    self.lastPointer = ringPoint;
    [self updateGlow];
    CGFloat radius = hypot(ringPoint.x, ringPoint.y);
    BOOL reset = radius < 0.001;
    // U samom centru sitno podrhtavanje prstiju nema pouzdan pravac.
    CGFloat angle = reset ? M_PI_2 : (radius < 0.025 && !created ? self.pointerAngle : atan2(ringPoint.y, ringPoint.x));
    CGFloat distance = MAX(radius * self.ringRadius, kHubRadius + 16.0);
    CALayer *layer = self.pointerView.layer;
    CALayer *visible = layer.presentationLayer;
    CGPoint start = visible ? visible.position : layer.position;
    CALayer *visibleArrow = self.pointerArrow.presentationLayer;
    CGFloat startAngle = visibleArrow ? [[visibleArrow valueForKeyPath:@"transform.rotation.z"] doubleValue] : self.pointerAngle;
    CGFloat targetAngle = startAngle + remainder(angle - startAngle, 2.0 * M_PI);
    self.pointerAngle = angle;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSSize size = self.pointerView.frame.size;
    [self.pointerView setFrameOrigin:NSMakePoint(self.anchorPoint.x + cos(angle) * distance - size.width / 2.0,
                                                 self.anchorPoint.y + sin(angle) * distance - size.height / 2.0)];
    self.pointerArrow.affineTransform = CGAffineTransformMakeRotation(targetAngle);
    if (!created && !reset && !self.pointerView.hidden) {
        // Nastavi od trenutno prikazanog položaja, bez skoka pri novom uzorku.
        CABasicAnimation *movement = [CABasicAnimation animationWithKeyPath:@"position"];
        movement.fromValue = [NSValue valueWithPoint:NSPointFromCGPoint(start)];
        movement.toValue = [NSValue valueWithPoint:NSPointFromCGPoint(layer.position)];
        movement.duration = 0.065;
        movement.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [layer addAnimation:movement forKey:@"pointerMovement"];
        CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rotation.fromValue = @(startAngle);
        rotation.toValue = @(targetAngle);
        rotation.duration = movement.duration;
        rotation.timingFunction = movement.timingFunction;
        [self.pointerArrow addAnimation:rotation forKey:@"pointerRotation"];
    } else {
        [layer removeAnimationForKey:@"pointerMovement"];
        [self.pointerArrow removeAnimationForKey:@"pointerRotation"];
    }
    [CATransaction commit];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSPoint center = self.anchorPoint;
    NSUInteger count = self.entries.count;
    if (count == 0 && !self.currentEntry) {
        NSDictionary *emptyStyle = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        [@"No open windows" drawInRect:NSMakeRect(center.x - 70, center.y - 30, 140, 16) withAttributes:emptyStyle];
        return;
    }

    // Nov thumbnail ili favicon osveži sadržaj bez ponavljanja animacije.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateCardLayersAnimated:NO refreshContents:YES];
        [self updateHubAnimated:NO];
    });
}

// Bez podloge i okvira; ikonica je centrirana preko donje ivice snimka.
- (void)drawCardForEntry:(RingEntry *)entry inRect:(NSRect)card {
    CGFloat footer = cardFooterHeight(NSWidth(card));
    NSRect content = NSMakeRect(NSMinX(card), NSMinY(card) + footer,
                                NSWidth(card), MAX(1, NSHeight(card) - footer));
    NSImage *thumbnail = resolvedThumbnail(entry);
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    if (thumbnail && thumbnail.size.width > 0 && thumbnail.size.height > 0) {
        CGFloat scale = MIN(NSWidth(content) / thumbnail.size.width, NSHeight(content) / thumbnail.size.height);
        NSSize fitted = NSMakeSize(thumbnail.size.width * scale, thumbnail.size.height * scale);
        NSRect imageRect = NSMakeRect(NSMidX(content) - fitted.width / 2, NSMidY(content) - fitted.height / 2,
                                      fitted.width, fitted.height);
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:imageRect xRadius:8 yRadius:8] addClip];
        [thumbnail drawInRect:imageRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        [NSGraphicsContext restoreGraphicsState];
        drawCardBadgeIcon(entry, content);
    } else {
        BOOL chrome = [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"];
        NSImage *site = chrome && atomic_load(&g_settingShowSiteIcons) ? RingFaviconForURL(entry.tabURL) : nil;
        CGFloat iconSide = MIN(144.0, NSHeight(content) * 0.85);
        [(site ?: entry.icon) drawInRect:NSMakeRect(NSMidX(content) - iconSide / 2,
                                                   NSMidY(content) - iconSide / 2, iconSide, iconSide)];
    }
    if (shouldDrawCardLabel(entry)) {
        BOOL finder = [entry.application.bundleIdentifier isEqualToString:@"com.apple.finder"];
        drawCardLabel(cardLabelText(entry), card, finder && entry.folderPath.length > 0, entry.isShortcut ? 12 : 0);
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
static RingPanel *g_snapshotPanel;
static RingView *g_ringView;
static SectorGlowView *g_glowView;
static NSView *g_dimView;
static CALayer *g_magnifiedBackdrop;
static NSArray<RingEntry *> *g_windowEntries = @[];
static RingEntry *g_currentRingEntry; // retained while the menu is open
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
static _Atomic(uint64_t) g_touchStartedNanos=0;
static _Atomic(bool) g_quickTapEligible=false;
static double g_touchMaxTravel=0;
static const NSInteger kQuickPreviousSelection=-2;
// Istorija i snimak prethodnog prozora pripadaju glavnom redu.
static NSMutableArray<NSString *> *g_recentWindowKeys;
static NSString *g_quickTapWindowKey;
static NSTimer *g_recentWindowTimer;
static NSArray<RingEntry *> *g_ringPageEntries;
static NSUInteger g_ringPage;
static NSTextField *g_ringPageLabel;
static _Atomic(int) g_pendingPageStep=0;
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

static BOOL runChromeScript(NSString *source);
static void setCommandShortcutMode(BOOL enabled);
static void pollCommandShortcuts(uint64_t generation);
static void applyShortcutSection(void);
static BOOL shortcutSectionWanted(int trigger, BOOL commandHeld, BOOL fourFingersHeld);
static BOOL fourFingersCancelOpenMenu(int trigger);
static _Atomic(bool) g_fourFingerShortcutHeld = false;
static _Atomic(uint64_t) g_fourFingerReleaseCandidateNanos = 0;
static RingEntry *settingsEntryIfVisible(void);
static void raiseSettingsWindow(void);
static NSArray<RingEntry *> *g_standardRingEntries;
static BOOL g_commandShortcutMode=NO;
static _Atomic(unsigned) g_shortcutMask=47;
static _Atomic(unsigned) g_persistentShortcutMask=0;
static NSArray<RingEntry *> *entriesWithPersistentShortcuts(NSArray<RingEntry *> *entries);

// Dijagnostika ide u poseban serijski red, bez pisanja na trackpad niti.
static dispatch_queue_t g_diagnosticQueue;
static int g_diagnosticFD=-1;
static NSString *g_diagnosticPath;
static NSUInteger g_diagnosticBytes=0;
static NSUInteger g_diagnosticLimit=4*1024*1024;

static NSString *diagnosticDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/TouchpadSwitcher"];
}

static void startDiagnosticLoggingAt(NSString *directory, NSUInteger limit) {
    NSError *error=nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
        NSLog(@"Dijagnostički dnevnik nije otvoren: %@",error.localizedDescription);
        return;
    }
    g_diagnosticPath=[directory stringByAppendingPathComponent:@"events.jsonl"];
    g_diagnosticLimit=limit;
    g_diagnosticBytes=[NSFileManager.defaultManager attributesOfItemAtPath:g_diagnosticPath error:nil].fileSize;
    g_diagnosticFD=open(g_diagnosticPath.fileSystemRepresentation,O_CREAT|O_WRONLY|O_APPEND,0600);
    if (g_diagnosticFD<0) return;
    g_diagnosticQueue=dispatch_queue_create("touchpad.diagnostics",DISPATCH_QUEUE_SERIAL);
}

static void diagnosticEvent(NSString *event, NSDictionary *details) {
    if (!g_diagnosticQueue) return;
    NSMutableDictionary *record=[NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
    record[@"event"]=event;
    record[@"time"]=@([NSDate date].timeIntervalSince1970);
    record[@"uptime"]=@(NSProcessInfo.processInfo.systemUptime);
    record[@"pid"]=@(getpid());
    record[@"generation"]=@(atomic_load(&g_gestureGeneration));
    record[@"fingers"]=@(atomic_load(&g_activeTouchCount));
    record[@"active"]=@(atomic_load(&g_gestureActive));
    record[@"ending"]=@(atomic_load(&g_gestureEnding));
    dispatch_async(g_diagnosticQueue, ^{
        @autoreleasepool {
            NSData *json=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
            if (!json || g_diagnosticFD<0) return;
            if (g_diagnosticBytes+json.length+1>g_diagnosticLimit) {
                close(g_diagnosticFD);
                NSString *previous=[g_diagnosticPath stringByAppendingString:@".previous"];
                unlink(previous.fileSystemRepresentation);
                rename(g_diagnosticPath.fileSystemRepresentation,previous.fileSystemRepresentation);
                g_diagnosticFD=open(g_diagnosticPath.fileSystemRepresentation,O_CREAT|O_WRONLY|O_APPEND,0600);
                g_diagnosticBytes=0;
                if (g_diagnosticFD<0) return;
            }
            NSMutableData *line=[json mutableCopy];
            [line appendBytes:"\n" length:1];
            const uint8_t *bytes=line.bytes;
            NSUInteger remaining=line.length;
            while (remaining) {
                ssize_t written=write(g_diagnosticFD,bytes,remaining);
                if (written<0 && errno==EINTR) continue;
                if (written<=0) break;
                bytes+=written; remaining-=(NSUInteger)written;
                g_diagnosticBytes+=(NSUInteger)written;
            }
        }
    });
}

static NSDictionary *diagnosticEntry(RingEntry *entry) {
    return @{@"app":entry.application.bundleIdentifier ?: @"", @"window":@(entry.windowID),
        @"chromeWindow":entry.chromeWindowID ?: @"", @"chromeTab":entry.chromeTabID ?: @"",
        @"tabIndex":@(entry.tabIndex), @"shortcut":@(entry.isShortcut), @"settings":@(entry.isSettings)};
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
    atomic_store(&g_fourFingerShortcutHeld, false);
    atomic_store(&g_fourFingerReleaseCandidateNanos, 0);
    atomic_store(&g_gestureActive, true);
    atomic_store(&g_gestureEnding, false);
    hideSystemCursorForGesture();
    g_pointerX = 0.0;
    g_pointerY = 0.0;
    g_selectedIndex = -1;
    g_cursorAtGestureStart = CGEventGetLocation(event);
    uint64_t generation = atomic_fetch_add(&g_gestureGeneration, 1) + 1;
    diagnosticEvent(@"gesture_start",@{@"source":@"mouse",@"button":@(button)});
    NSLog(@"[mouse] button %d gesture started", button + 1);
    dispatch_async(dispatch_get_main_queue(), ^{ showRing(generation); });
}

static void beginKeyboardGesture(CGEventRef event) {
    if (atomic_load(&g_gestureActive) || atomic_load(&g_ringOverlayVisible)) return;
    atomic_store(&g_keyboardGestureActive, true);
    atomic_store(&g_fourFingerShortcutHeld, false);
    atomic_store(&g_fourFingerReleaseCandidateNanos, 0);
    atomic_store(&g_gestureActive, true);
    atomic_store(&g_gestureEnding, false);
    hideSystemCursorForGesture();
    g_pointerX = 0.0;
    g_pointerY = 0.0;
    g_selectedIndex = -1;
    g_cursorAtGestureStart = CGEventGetLocation(event);
    uint64_t generation = atomic_fetch_add(&g_gestureGeneration, 1) + 1;
    diagnosticEvent(@"gesture_start",@{@"source":@"keyboard"});
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
    if (atomic_load(&g_gestureActive) && type==kCGEventFlagsChanged) {
        uint64_t generation=atomic_load(&g_gestureGeneration);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation==atomic_load(&g_gestureGeneration) && atomic_load(&g_gestureActive))
                applyShortcutSection();
        });
        return event;
    }
    if (atomic_load(&g_gestureActive) && (type==kCGEventKeyDown || type==kCGEventKeyUp)) {
        int key=(int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        if (key==123 || key==124) {
            if (type==kCGEventKeyDown && !CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat))
                atomic_store(&g_pendingPageStep,key==123 ? -1 : 1);
            return NULL;
        }
    }
    if (atomic_load(&g_gestureActive) && type==kCGEventKeyDown &&
        CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==kEscapeKeyCode) {
        uint64_t generation=atomic_load(&g_gestureGeneration);
        atomic_store(&g_gestureEnding,true);
        dispatch_async(dispatch_get_main_queue(), ^{ finishGesture(generation,-1); });
        return NULL;
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
                                         CGEventMaskBit(kCGEventFlagsChanged) |
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
    // No window animation: macOS zoomed the blurred backdrop in; it appears at once.
    g_panel.animationBehavior = NSWindowAnimationBehaviorNone;
    // The full-screen panel also catches scrolling if the Quartz event tap
    // misses a trackpad event or is temporarily disabled by the system.
    g_panel.ignoresMouseEvents = NO;
    g_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary |
                                 NSWindowCollectionBehaviorStationary;
    // A separate window lets the existing window-server blur act on the
    // moving screenshot exactly as it acts on the real desktop.
    NSRect contentFrame = NSMakeRect(0, 0, NSWidth(screen.frame), NSHeight(screen.frame));
    g_snapshotPanel = [[RingPanel alloc] initWithContentRect:screen.frame
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
          backing:NSBackingStoreBuffered defer:NO];
    g_snapshotPanel.opaque = NO;
    g_snapshotPanel.backgroundColor = NSColor.clearColor;
    g_snapshotPanel.hasShadow = NO;
    g_snapshotPanel.level = g_panel.level;
    g_snapshotPanel.hidesOnDeactivate = NO;
    g_snapshotPanel.animationBehavior = NSWindowAnimationBehaviorNone;
    g_snapshotPanel.ignoresMouseEvents = YES;
    g_snapshotPanel.collectionBehavior = g_panel.collectionBehavior;
    NSView *snapshotContent = [[NSView alloc] initWithFrame:contentFrame];
    snapshotContent.wantsLayer = YES;
    NSView *content = [[NSView alloc] initWithFrame:contentFrame];
    content.wantsLayer = YES;
    g_magnifiedBackdrop = [CALayer layer];
    g_magnifiedBackdrop.frame = snapshotContent.bounds;
    g_magnifiedBackdrop.contentsGravity = kCAGravityResizeAspectFill;
    g_magnifiedBackdrop.hidden = YES;
    g_magnifiedBackdrop.opacity = 0;
    [snapshotContent.layer addSublayer:g_magnifiedBackdrop];
    g_snapshotPanel.contentView = snapshotContent;
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

// An enlarged screenshot provides real magnification. Its extra margin allows
// movement in either direction without exposing an edge of the captured image.
static void moveMagnifiedBackdrop(NSPoint pointer) {
    if (!g_magnifiedBackdrop || g_magnifiedBackdrop.hidden) return;
    NSSize size = g_panel.contentView.bounds.size;
    CGFloat zoom = 1.0 + atomic_load(&g_settingBackdropZoom) / 100.0;
    CGFloat x = fmax(-1.0, fmin(1.0, pointer.x));
    CGFloat y = fmax(-1.0, fmin(1.0, pointer.y));
    CGFloat marginX = size.width * (zoom - 1.0) / 2.0;
    CGFloat marginY = size.height * (zoom - 1.0) / 2.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g_magnifiedBackdrop.bounds = CGRectMake(0, 0, size.width, size.height);
    g_magnifiedBackdrop.position = CGPointMake(size.width / 2.0 - x * marginX,
                                                size.height / 2.0 - y * marginY);
    g_magnifiedBackdrop.transform = CATransform3DMakeScale(zoom, zoom, 1.0);
    [CATransaction commit];
}

static void captureMagnifiedBackdrop(NSScreen *screen, uint64_t generation, int attempt) {
    NSNumber *displayNumber = screen.deviceDescription[@"NSScreenNumber"];
    if (!displayNumber || atomic_load(&g_settingBackdropZoom) == 0) return;
    CGDirectDisplayID displayID = displayNumber.unsignedIntValue;
    NSInteger captureWidth = (NSInteger)lround(NSWidth(screen.frame));
    NSInteger captureHeight = (NSInteger)lround(NSHeight(screen.frame));
    static dispatch_queue_t captureQueue;
    if (!captureQueue) captureQueue = dispatch_queue_create("touchpad.ring.backdrop",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    dispatch_async(captureQueue, ^{
        if (generation != atomic_load(&g_gestureGeneration)) return;
        if (!CGPreflightScreenCaptureAccess()) return;
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
            completionHandler:^(SCShareableContent *content, NSError *error) {
            if (generation != atomic_load(&g_gestureGeneration)) return;
            if (error) {
                diagnosticEvent(@"backdrop_failed", @{@"stage":@"list", @"error":error.localizedDescription ?: @"unknown"});
                return;
            }
            SCDisplay *display = nil;
            SCRunningApplication *ownApp = nil;
            for (SCDisplay *candidate in content.displays)
                if (candidate.displayID == displayID) { display = candidate; break; }
            for (SCRunningApplication *candidate in content.applications)
                if (candidate.processID == getpid()) { ownApp = candidate; break; }
            if (!display || !ownApp) {
                if (attempt < 2) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        captureMagnifiedBackdrop(screen, generation, attempt + 1);
                    });
                } else {
                    diagnosticEvent(@"backdrop_failed", @{@"stage":@"filter",
                        @"display":@(display != nil), @"ownApp":@(ownApp != nil)});
                }
                return;
            }
            // Excluding this app prevents the visible menu from photographing itself.
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                excludingApplications:@[ownApp] exceptingWindows:@[]];
            SCStreamConfiguration *configuration = [SCStreamConfiguration new];
            configuration.width = captureWidth;
            configuration.height = captureHeight;
            [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
                completionHandler:^(CGImageRef captured, NSError *captureError) {
                if (!captured || captureError) {
                    if (attempt < 2) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC),
                                       dispatch_get_main_queue(), ^{
                            captureMagnifiedBackdrop(screen, generation, attempt + 1);
                        });
                    } else {
                        diagnosticEvent(@"backdrop_failed", @{@"stage":@"capture",
                            @"error":captureError.localizedDescription ?: @"empty image"});
                    }
                    return;
                }
                CGImageRef retained = CGImageRetain(captured);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation == atomic_load(&g_gestureGeneration) &&
                        atomic_load(&g_ringOverlayVisible) && atomic_load(&g_gestureActive)) {
                        [g_snapshotPanel setFrame:screen.frame display:NO];
                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];
                        g_magnifiedBackdrop.contents = (__bridge id)retained;
                        g_magnifiedBackdrop.hidden = NO;
                        g_magnifiedBackdrop.opacity = 1;
                        [CATransaction commit];
                        moveMagnifiedBackdrop(g_ringView.lastPointer);
                        CAMediaTimingFunction *easing = [CAMediaTimingFunction
                            functionWithControlPoints:0.35 :0.0 :0.25 :1.0];
                        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
                        fade.fromValue = @0;
                        fade.toValue = @1;
                        fade.duration = 0.45;
                        fade.timingFunction = easing;
                        [g_magnifiedBackdrop addAnimation:fade forKey:@"backdropFadeIn"];
                        CABasicAnimation *zoom = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
                        zoom.fromValue = @1;
                        zoom.toValue = @(1.0 + atomic_load(&g_settingBackdropZoom) / 100.0);
                        zoom.duration = 0.9;
                        zoom.timingFunction = easing;
                        [g_magnifiedBackdrop addAnimation:zoom forKey:@"backdropZoomIn"];
                        // Order the panel only after both animations exist, so
                        // its first visible frame cannot flash at full opacity.
                        [g_snapshotPanel orderWindow:NSWindowBelow relativeTo:g_panel.windowNumber];
                        diagnosticEvent(@"backdrop_ready", nil);
                    }
                    CGImageRelease(retained);
                });
            }];
        }];
    });
}

static void pruneDeadWindowEntriesLive(void);
static NSArray<RingEntry *> *reconcileChromeEntries(NSArray<RingEntry *> *entries, NSSet<NSString *> *openTabs);
static void refreshChromeMembershipForRing(uint64_t generation);

static NSString *recentWindowKey(RingEntry *entry) {
    if (entry.isShortcut || entry.isSettings || !entry.application || entry.application.isTerminated ||
        entry.windowID==kCGNullWindowID || (entry.isTab && !entry.isSelectedTab)) return nil;
    return [NSString stringWithFormat:@"%d:%u",entry.application.processIdentifier,entry.windowID];
}

static void recordRecentWindow(NSString *key) {
    if (!key.length) return;
    if (!g_recentWindowKeys) g_recentWindowKeys=[NSMutableArray array];
    [g_recentWindowKeys removeObject:key];
    [g_recentWindowKeys insertObject:key atIndex:0];
    if (g_recentWindowKeys.count>64) [g_recentWindowKeys removeLastObject];
}

static void updateRecentWindowHistory(void) {
    if (atomic_load(&g_chromePrefetchActive)) return;
    pid_t frontPID=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if (frontPID==getpid()) return;
    NSMutableDictionary<NSNumber *,NSString *> *keys=[NSMutableDictionary dictionary];
    for (RingEntry *entry in g_windowEntries) {
        NSString *key=recentWindowKey(entry);
        if (key) keys[@(entry.windowID)]=key;
    }
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    // Početni redosled daje rezervu dok se ne zabeleži prva promena fokusa.
    if (!g_recentWindowKeys.count) {
        g_recentWindowKeys=[NSMutableArray array];
        for (NSDictionary *info in windows) {
            NSString *key=keys[info[(id)kCGWindowNumber]];
            if (key && [info[(id)kCGWindowLayer] intValue]==0 && ![g_recentWindowKeys containsObject:key])
                [g_recentWindowKeys addObject:key];
        }
    }
    for (NSDictionary *info in windows) {
        if ([info[(id)kCGWindowOwnerPID] intValue]!=frontPID || [info[(id)kCGWindowLayer] intValue]!=0) continue;
        NSString *key=keys[info[(id)kCGWindowNumber]];
        if (key) { recordRecentWindow(key); break; }
    }
}

static NSString *previousRecentWindow(NSArray<RingEntry *> *entries) {
    for (NSUInteger i=1;i<g_recentWindowKeys.count;i++) {
        NSString *key=g_recentWindowKeys[i];
        for (RingEntry *entry in entries) if ([recentWindowKey(entry) isEqualToString:key]) return key;
    }
    return nil;
}

static RingEntry *windowEntryForQuickSwitch(RingEntry *source) {
    if (!source) return nil;
    RingEntry *window=[RingEntry new];
    window.application=source.application;
    window.windowID=source.windowID;
    window.windowTitle=source.windowTitle;
    window.windowBounds=source.windowBounds;
    window.accessibilityWindowObject=source.accessibilityWindowObject;
    window.icon=source.application.icon;
    // Vrati ceo prozor bez menjanja njegovog trenutnog Chrome/Finder taba.
    return window;
}

static NSInteger previousWindowIndex(NSArray<RingEntry *> *entries,NSString *key) {
    if (!key.length) return -1;
    for (NSUInteger i=0;i<entries.count;i++) if ([recentWindowKey(entries[i]) isEqualToString:key]) return (NSInteger)i;
    return -1;
}

static NSArray<RingEntry *> *ringEntriesOnPage(NSArray<RingEntry *> *entries,NSUInteger page) {
    const NSUInteger limit=10;
    if (entries.count<=limit) return entries;
    NSUInteger pages=MAX((NSUInteger)1,(entries.count+limit-1)/limit);
    NSUInteger start=MIN(page,pages-1)*limit;
    return [entries subarrayWithRange:NSMakeRange(start,MIN(limit,entries.count-start))];
}

static void configureRingPage(NSArray<RingEntry *> *entries,NSUInteger page) {
    g_ringPageEntries=entries;
    NSUInteger pages=MAX((NSUInteger)1,(entries.count+9)/10);
    g_ringPage=MIN(page,pages-1);
    g_windowEntries=ringEntriesOnPage(entries,g_ringPage);
    atomic_store(&g_windowEntryCount,(int)g_windowEntries.count);
    if (g_panel) {
        NSSize size=g_panel.contentView.bounds.size;
        CGFloat footer=pages>1 ? 48 : 0;
        g_ringView.frame=NSMakeRect(0,footer,size.width,size.height-footer);
        g_ringView.anchorPoint=NSMakePoint(size.width/2,(size.height-footer)/2);
        if (!g_ringPageLabel) {
            g_ringPageLabel=[NSTextField labelWithString:@""];
            g_ringPageLabel.alignment=NSTextAlignmentCenter;
            g_ringPageLabel.textColor=NSColor.whiteColor;
            g_ringPageLabel.font=[NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
            [g_panel.contentView addSubview:g_ringPageLabel];
        }
        g_ringPageLabel.hidden=pages<=1;
        g_ringPageLabel.frame=NSMakeRect(size.width/2-240,14,480,22);
        g_ringPageLabel.stringValue=[NSString stringWithFormat:@"←   Prethodna      %lu / %lu      Sledeća   →",(unsigned long)g_ringPage+1,(unsigned long)pages];
    }
}

static void changeRingPage(NSInteger direction) {
    if (!atomic_load(&g_gestureActive) || atomic_load(&g_gestureEnding) || !g_ringPageEntries.count) return;
    NSInteger pages=(NSInteger)((g_ringPageEntries.count+9)/10);
    NSInteger next=(NSInteger)g_ringPage+direction;
    if (next<0 || next>=pages) return;
    configureRingPage(g_ringPageEntries,(NSUInteger)next);
    atomic_store(&g_quickTapEligible,false);
    g_selectedIndex=-1; g_pointerX=g_pointerY=0;
    os_unfair_lock_lock(&g_selectionLock);
    g_pendingSelection=-1; g_pendingPointer=NSZeroPoint;
    os_unfair_lock_unlock(&g_selectionLock);
    g_ringView.entries=g_windowEntries;
    g_ringView.layoutEntries=nil;
    g_ringView.selectedIndex=-1;
    [g_ringView updateCardLayersAnimated:NO refreshContents:YES];
    [g_ringView updateHubAnimated:NO];
    [g_ringView movePointerTo:NSZeroPoint];
    [g_ringView setNeedsDisplay:YES];
    diagnosticEvent(@"ring_page",@{@"page":@(g_ringPage+1),@"pages":@(pages)});
}

static RingEntry *frontWindowEntry(NSArray<RingEntry *> *entries) {
    pid_t frontPID = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if (frontPID <= 0 || frontPID == getpid()) return nil;
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *info in windows) {
        if ([info[(id)kCGWindowOwnerPID] intValue] != frontPID ||
            [info[(id)kCGWindowLayer] intValue] != 0) continue;
        CGWindowID windowID = [info[(id)kCGWindowNumber] unsignedIntValue];
        for (RingEntry *entry in entries) {
            if (entry.windowID == windowID && entry.application.processIdentifier == frontPID &&
                !entry.isShortcut && !entry.isSettings && (!entry.isTab || entry.isSelectedTab))
                return entry;
        }
    }
    return nil;
}

static void showRing(uint64_t generation) {
    if (generation != atomic_load(&g_gestureGeneration) || !atomic_load(&g_gestureActive)) return;
    if (atomic_load(&g_ringShownGeneration) == generation) return;
    updateRecentWindowHistory();
    g_quickTapWindowKey=previousRecentWindow(g_windowEntries);
    NSScreen *screen = nil;
    (void)appKitPointFromQuartz(g_cursorAtGestureStart, &screen); // Cursor chooses the display only.
    ensurePanel(screen);
    g_currentRingEntry = atomic_load(&g_settingCurrentWindowInCenter) ? frontWindowEntry(g_windowEntries) : nil;
    if (g_currentRingEntry) {
        NSMutableArray<RingEntry *> *otherEntries = [g_windowEntries mutableCopy];
        [otherEntries removeObjectIdenticalTo:g_currentRingEntry];
        g_windowEntries = otherEntries;
    }
    g_windowEntries=entriesWithPersistentShortcuts(g_windowEntries);
    atomic_store(&g_windowEntryCount,(int)g_windowEntries.count);
    g_standardRingEntries=g_windowEntries;
    g_commandShortcutMode=NO;
    atomic_store(&g_pendingPageStep,0);
    configureRingPage(g_standardRingEntries,0);
    CGFloat width = NSWidth(g_ringView.bounds), height = NSHeight(g_ringView.bounds);
    NSPoint anchor = NSMakePoint(width / 2.0, height / 2.0);
    g_ringView.entries = g_windowEntries;
    g_ringView.currentEntry = g_currentRingEntry;
    g_ringView.selectedIndex = -1;
    g_ringView.anchorPoint = anchor;
    g_ringView.layoutEntries = nil;
    [g_ringView prepareCardLayout];
    [g_ringView resetSelectionVisuals];
    [g_ringView movePointerTo:NSZeroPoint];
    [g_panel setFrame:screen.frame display:NO];
    // The same window-server blur stays active before and after the screenshot
    // panel fades in behind this one.
    int blurRadius = atomic_load(&g_settingBlurRadius);
    BOOL captureBackdrop = atomic_load(&g_settingBackdropZoom) > 0 && CGPreflightScreenCaptureAccess();
    setPanelBlur(blurRadius);
    NSColor *backdrop = g_backdropColor ?: [NSColor colorWithSRGBRed:0.02 green:0.02 blue:0.02 alpha:1];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g_dimView.layer.backgroundColor =
        [backdrop colorWithAlphaComponent:atomic_load(&g_settingBackdropDimming) / 100.0].CGColor;
    [CATransaction commit];
    [g_ringView setNeedsDisplay:YES];
    // Avoid forcing a synchronous draw before the panel is ordered onscreen.
    atomic_store(&g_ringOverlayVisible, true);
    [g_panel orderFrontRegardless];
    atomic_store(&g_ringShownGeneration, generation);
    if (captureBackdrop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            captureMagnifiedBackdrop(screen, generation, 0);
        });
    }
    if (shortcutSectionWanted(atomic_load(&g_settingShortcutTrigger),
                              (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState)&kCGEventFlagMaskCommand)!=0,
                              atomic_load(&g_fourFingerShortcutHeld)))
        setCommandShortcutMode(YES);
    pollCommandShortcuts(generation);
    diagnosticEvent(@"menu_open",@{@"entries":@(g_windowEntries.count),@"cmd":@(g_commandShortcutMode)});
    fprintf(stderr, "[ring] overlay shown at screen center; %lu entries\n", (unsigned long)g_windowEntries.count);

    // The cached ring is already on screen. Fresh pictures of the visible
    // windows, above all the one being left, replace it as they arrive.
    refreshThumbnailsNow(0, 0.15);


    refreshChromeMembershipForRing(generation);

}

static AXUIElementRef findTabButton(AXUIElementRef parent, NSString *title, int depth);
static BOOL setChromeActiveTabWithIndex(pid_t pid, NSString *windowID, NSString *tabID, NSUInteger tabIndex1Based);
static NSString *chromeActiveTab(pid_t pid, NSString *windowID, NSString **urlOut);

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
    if (generation != atomic_load(&g_gestureGeneration)) {
        diagnosticEvent(@"activation_skipped",@{@"requestedGeneration":@(generation),@"reason":@"new_gesture",@"entry":diagnosticEntry(entry)});
        return;
    }
    if (!entry.application || entry.application.isTerminated) {
        diagnosticEvent(@"activation_skipped",@{@"reason":@"app_missing",@"entry":diagnosticEntry(entry)});
        return;
    }
    diagnosticEvent(@"activation_start",@{@"entry":diagnosticEntry(entry)});
    pid_t pid = entry.application.processIdentifier;

    // Chrome profiles are separate windows in one app. Activating Chrome keeps
    // the last used profile in front unless that window is made index 1.
    if (generation == atomic_load(&g_gestureGeneration) && entry.isTab &&
        entry.chromeWindowID.length) {
        BOOL switched = setChromeActiveTabWithIndex(entry.application.processIdentifier, entry.chromeWindowID, entry.chromeTabID,
                                                    entry.tabIndex + 1);
        diagnosticEvent(@"chrome_activation",@{@"success":@(switched),@"entry":diagnosticEntry(entry)});
        if (switched) {
            focusWindowExactly(pid, entry.windowID);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),g_windowActivationQueue, ^{
                if (generation!=atomic_load(&g_gestureGeneration) || atomic_load(&g_gestureActive)) {
                    diagnosticEvent(@"chrome_verify_skipped",@{@"reason":@"new_gesture",@"requestedGeneration":@(generation)});
                    return;
                }
                NSString *actual=chromeActiveTab(entry.application.processIdentifier,entry.chromeWindowID,NULL);
                diagnosticEvent(@"chrome_verify",@{@"expected":entry.chromeTabID ?: @"",@"actual":actual ?: @"",
                    @"window":entry.chromeWindowID,@"readable":@(actual!=nil),
                    @"matches":@(actual && [actual isEqualToString:entry.chromeTabID])});
            });
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

typedef AXError (*WindowAttributeReader)(AXUIElementRef,CFStringRef,CFTypeRef *);
typedef AXError (*WindowAttributeWriter)(AXUIElementRef,CFStringRef,CFTypeRef);
typedef AXError (*WindowActionPerformer)(AXUIElementRef,CFStringRef);

// Proveri stvarno stanje umesto oslanjanja samo na povratnu vrednost zahteva.
static AXError minimizeWindow(AXUIElementRef window,WindowAttributeReader read,WindowAttributeWriter writeAttribute,WindowActionPerformer performAction) {
    CFTypeRef value=NULL;
    AXError result=read(window,kAXMinimizedAttribute,&value);
    BOOL minimized=result==kAXErrorSuccess && value && CFEqual(value,kCFBooleanTrue);
    if (value) CFRelease(value);
    if (minimized) return kAXErrorSuccess;
    result=writeAttribute(window,kAXMinimizedAttribute,kCFBooleanTrue);
    AXError writeResult=result;
    value=NULL;
    result=read(window,kAXMinimizedAttribute,&value);
    minimized=result==kAXErrorSuccess && value && CFEqual(value,kCFBooleanTrue);
    if (value) CFRelease(value);
    if (minimized) return kAXErrorSuccess;
    // Neke aplikacije podržavaju dugme, ali odbijaju direktan upis AXMinimized.
    CFTypeRef button=NULL;
    AXError buttonResult=read(window,kAXMinimizeButtonAttribute,&button);
    if (buttonResult==kAXErrorSuccess && button) {
        AXError pressResult=performAction((AXUIElementRef)button,kAXPressAction);
        CFRelease(button);
        if (pressResult!=kAXErrorSuccess) return pressResult;
        value=NULL;
        result=read(window,kAXMinimizedAttribute,&value);
        minimized=result==kAXErrorSuccess && value && CFEqual(value,kCFBooleanTrue);
        if (value) CFRelease(value);
        return minimized ? kAXErrorSuccess : (result==kAXErrorSuccess ? kAXErrorCannotComplete : result);
    }
    if (button) CFRelease(button);
    return writeResult!=kAXErrorSuccess ? writeResult : (result==kAXErrorSuccess ? kAXErrorCannotComplete : result);
}

// Status dozvole dopuni stvarnim AX zahtevom, bez menjanja sistemskih dozvola.
static BOOL windowAccessAllowsMinimizing(BOOL trusted,AXError probe) {
    return trusted || probe==kAXErrorSuccess;
}

static BOOL canAccessOtherApplicationWindows(void) {
    BOOL trusted=AXIsProcessTrusted();
    if (trusted) return YES;
    NSMutableArray<NSRunningApplication *> *candidates=[NSMutableArray array];
    NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front && front.processIdentifier!=getpid()) [candidates addObject:front];
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"])
        if (![candidates containsObject:app]) [candidates addObject:app];
    for (NSRunningApplication *app in candidates) {
        AXUIElementRef element=AXUIElementCreateApplication(app.processIdentifier);
        AXUIElementSetMessagingTimeout(element,0.4);
        CFTypeRef windows=NULL;
        AXError result=AXUIElementCopyAttributeValue(element,kAXWindowsAttribute,&windows);
        BOOL valid=windows && CFGetTypeID(windows)==CFArrayGetTypeID();
        diagnosticEvent(@"accessibility_probe",@{@"trusted":@(trusted),@"app":app.bundleIdentifier ?: @"",
            @"error":@(result),@"validWindows":@(valid)});
        if (windows) CFRelease(windows);
        CFRelease(element);
        if (valid && windowAccessAllowsMinimizing(trusted,result)) return YES;
    }
    return NO;
}

static _Atomic(bool) g_minimizingAllWindows=false;
static void minimizeAllWindows(void) {
    if (!canAccessOtherApplicationWindows()) {
        diagnosticEvent(@"minimize_all_blocked",@{@"reason":@"accessibility_permission"});
        NSAlert *alert=[NSAlert new];
        alert.messageText=@"macOS ne dozvoljava pristup prozorima";
        NSString *permissionName=NSProcessInfo.processInfo.operatingSystemVersion.majorVersion>=27 ? @"Device Control and Data Access" : @"Accessibility";
        alert.informativeText=[NSString stringWithFormat:@"Otvori System Settings > Privacy & Security > %@ i proveri Touchpad Switcher. Ako je već uključen, isključi ga pa ponovo uključi, zatim ponovo pokreni aplikaciju. Ako to ne pomogne, ukloni samo njen unos i dodaj Touchpad Switcher iz foldera Applications.",permissionName];
        [alert addButtonWithTitle:@"Otvori podešavanja"];
        [alert addButtonWithTitle:@"U redu"];
        if ([alert runModal]==NSAlertFirstButtonReturn)
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
        return;
    }
    if (atomic_exchange(&g_minimizingAllWindows,true)) return;
    NSArray *applications=[NSWorkspace.sharedWorkspace.runningApplications copy];
    __block _Atomic(unsigned) minimized=0,failed=0;
    dispatch_group_t group=dispatch_group_create();
    diagnosticEvent(@"minimize_all_start",nil);
    // Ne čekaj animaciju jedne aplikacije pre slanja zahteva drugima.
    for (NSRunningApplication *app in applications) {
        if (app.isTerminated || app.processIdentifier==getpid() ||
            app.activationPolicy==NSApplicationActivationPolicyProhibited) continue;
        dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            @autoreleasepool {
                AXUIElementRef element=AXUIElementCreateApplication(app.processIdentifier);
                AXUIElementSetMessagingTimeout(element,0.4);
                CFTypeRef windows=NULL;
                AXError enumeration=AXUIElementCopyAttributeValue(element,kAXWindowsAttribute,&windows);
                diagnosticEvent(@"minimize_enumeration",@{@"app":app.bundleIdentifier ?: @"",@"error":@(enumeration),
                    @"windows":@(windows && CFGetTypeID(windows)==CFArrayGetTypeID() ? CFArrayGetCount(windows) : 0)});
                if (enumeration==kAXErrorSuccess && windows && CFGetTypeID(windows)==CFArrayGetTypeID()) {
                    for (id item in (__bridge NSArray *)windows) {
                        AXUIElementRef window=(__bridge AXUIElementRef)item;
                        AXUIElementSetMessagingTimeout(window,0.4);
                        CFTypeRef fullscreen=NULL;
                        AXUIElementCopyAttributeValue(window,CFSTR("AXFullScreen"),&fullscreen);
                        if (fullscreen && CFEqual(fullscreen,kCFBooleanTrue)) {
                            AXError exitResult=AXUIElementSetAttributeValue(window,CFSTR("AXFullScreen"),kCFBooleanFalse);
                            diagnosticEvent(@"minimize_exit_fullscreen",@{@"app":app.bundleIdentifier ?: @"",@"error":@(exitResult)});
                            if (exitResult==kAXErrorSuccess) usleep(250000);
                        }
                        if (fullscreen) CFRelease(fullscreen);
                        AXError result=minimizeWindow(window,AXUIElementCopyAttributeValue,AXUIElementSetAttributeValue,AXUIElementPerformAction);
                        for (int retry=0;result==kAXErrorCannotComplete && retry<2;retry++) {
                            usleep(150000);
                            result=minimizeWindow(window,AXUIElementCopyAttributeValue,AXUIElementSetAttributeValue,AXUIElementPerformAction);
                        }
                        if (result==kAXErrorSuccess) atomic_fetch_add(&minimized,1);
                        else atomic_fetch_add(&failed,1);
                        diagnosticEvent(@"minimize_window",@{@"app":app.bundleIdentifier ?: @"",@"success":@(result==kAXErrorSuccess),@"error":@(result)});
                    }
                } else if (enumeration!=kAXErrorSuccess) {
                    atomic_fetch_add(&failed,1);
                }
                if (windows) CFRelease(windows);
                CFRelease(element);
            }
        });
    }
    [NSApp hide:nil]; // Sakrij i sopstveni panel podešavanja.
    dispatch_group_notify(group,dispatch_get_main_queue(), ^{
        atomic_store(&g_minimizingAllWindows,false);
        diagnosticEvent(@"minimize_all_done",@{@"minimized":@(atomic_load(&minimized)),@"failed":@(atomic_load(&failed))});
    });
}

static NSArray<RingEntry *> *shortcutEntriesForMask(unsigned mask) {
    NSMutableArray *entries=[NSMutableArray array];
    NSArray *names=@[@"Downloads",@"Desktop",@"Documents",@"Novi Chrome tab",@"Novi YouTube tab",@"Spusti sve prozore"];
    NSArray *folders=@[@"Downloads",@"Desktop",@"Documents"];
    for (NSUInteger i=0;i<names.count;i++) {
        if (!(mask&(1u<<i))) continue;
        RingEntry *entry=[RingEntry new];
        entry.isShortcut=YES;
        entry.windowTitle=names[i];
        if (i<3) {
            entry.folderPath=[NSHomeDirectory() stringByAppendingPathComponent:folders[i]];
            entry.icon=[NSWorkspace.sharedWorkspace iconForFile:entry.folderPath];
        } else if (i==5) {
            entry.minimizesAllWindows=YES;
            NSImage *symbol=[NSImage imageWithSystemSymbolName:@"arrow.down.right.and.arrow.up.left" accessibilityDescription:@"Spusti sve prozore"];
            entry.icon=[symbol imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.systemBlueColor]]];
        } else {
            entry.opensNewChromeTab=YES;
            if (i==4) entry.tabURL=@"https://www.youtube.com/";
            NSURL *chrome=[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.google.Chrome"];
            if (!chrome) continue;
            entry.icon=[NSWorkspace.sharedWorkspace iconForFile:chrome.path];
            if (i==4) entry.icon=[NSImage imageWithSize:NSMakeSize(128,128) flipped:NO drawingHandler:^BOOL(NSRect rect) {
                [[NSColor colorWithSRGBRed:1 green:0 blue:0.15 alpha:1] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(4,22,120,84) xRadius:22 yRadius:22] fill];
                [NSColor.whiteColor setFill];
                NSBezierPath *play=[NSBezierPath bezierPath];
                [play moveToPoint:NSMakePoint(51,43)]; [play lineToPoint:NSMakePoint(86,64)];
                [play lineToPoint:NSMakePoint(51,85)]; [play closePath]; [play fill];
                return YES;
            }];
        }
        [entries addObject:entry];
    }
    return entries;
}

static NSArray<RingEntry *> *commandShortcutEntries(void) {
    return shortcutEntriesForMask(atomic_load(&g_shortcutMask));
}

static NSArray<RingEntry *> *entriesWithPersistentShortcuts(NSArray<RingEntry *> *entries) {
    NSMutableArray *result=[NSMutableArray array];
    for (RingEntry *entry in entries) if (!entry.isShortcut) [result addObject:entry];
    [result addObjectsFromArray:shortcutEntriesForMask(atomic_load(&g_persistentShortcutMask))];
    return result;
}

static NSString *newChromeTabScript(RingEntry *entry) {
    NSString *url=[entry.tabURL isEqualToString:@"https://www.youtube.com/"] ? entry.tabURL : @"chrome://newtab/";
    return [NSString stringWithFormat:@"tell application \"Google Chrome\"\nif (count of windows) is 0 then\nmake new window\nset URL of active tab of front window to \"%@\"\nelse\nmake new tab at end of tabs of front window with properties {URL:\"%@\"}\nend if\nset active tab index of front window to count of tabs of front window\nactivate\nreturn \"ok\"\nend tell",url,url];
}

static void setCommandShortcutMode(BOOL enabled) {
    if (atomic_load(&g_gestureEnding) || g_commandShortcutMode==enabled || !g_standardRingEntries) return;
    NSArray *entries=enabled ? commandShortcutEntries() : g_standardRingEntries;
    if (enabled && !entries.count) return;
    g_commandShortcutMode=enabled;
    if (enabled) atomic_store(&g_quickTapEligible,false);
    diagnosticEvent(@"cmd_mode",@{@"enabled":@(enabled),@"entries":@(entries.count)});
    configureRingPage(entries,0);
    entries=g_windowEntries;
    g_pointerX=g_pointerY=0;
    g_selectedIndex=-1;
    os_unfair_lock_lock(&g_selectionLock);
    g_pendingSelection=-1;
    g_pendingPointer=NSZeroPoint;
    os_unfair_lock_unlock(&g_selectionLock);
    g_ringView.entries=entries;
    g_ringView.layoutEntries=nil;
    g_ringView.selectedIndex=-1;
    [g_ringView updateCardLayersAnimated:NO refreshContents:YES];
    [g_ringView updateHubAnimated:NO];
    [g_ringView movePointerTo:NSZeroPoint];
    [g_ringView setNeedsDisplay:YES];
}

// Rezervna provera Cmd-a radi i kada sistemski event tap nije dostupan.
static BOOL shortcutSectionWanted(int trigger, BOOL commandHeld, BOOL fourFingersHeld) {
    if (trigger==ShortcutTriggerCommand) return commandHeld;
    if (trigger==ShortcutTriggerFourFingers) return fourFingersHeld;
    if (trigger==ShortcutTriggerBoth) return commandHeld || fourFingersHeld;
    return NO;
}

// Četiri prsta gase otvoren meni samo kada ne otvaraju poseban meni prečica.
static BOOL fourFingersCancelOpenMenu(int trigger) {
    return trigger!=ShortcutTriggerFourFingers && trigger!=ShortcutTriggerBoth;
}

static void releaseFourFingerShortcutHold(void) {
    atomic_store(&g_fourFingerReleaseCandidateNanos, 0);
    if (!atomic_exchange(&g_fourFingerShortcutHeld, false)) return;
    uint64_t generation=atomic_load(&g_gestureGeneration);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation==atomic_load(&g_gestureGeneration) && atomic_load(&g_gestureActive))
            applyShortcutSection();
    });
}

static void applyShortcutSection(void) {
    if (!atomic_load(&g_gestureActive) || atomic_load(&g_gestureEnding) || !g_standardRingEntries) return;
    BOOL command=(CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState)&kCGEventFlagMaskCommand)!=0;
    setCommandShortcutMode(shortcutSectionWanted(atomic_load(&g_settingShortcutTrigger), command,
                                                 atomic_load(&g_fourFingerShortcutHeld)));
}

static void pollCommandShortcuts(uint64_t generation) {
    if (generation!=atomic_load(&g_gestureGeneration) ||
        !atomic_load(&g_gestureActive) || atomic_load(&g_gestureEnding)) return;
    applyShortcutSection();
    static uint64_t pageGeneration=0;
    static BOOL wasLeft=NO,wasRight=NO;
    BOOL left=CGEventSourceKeyState(kCGEventSourceStateHIDSystemState,123);
    BOOL right=CGEventSourceKeyState(kCGEventSourceStateHIDSystemState,124);
    if (pageGeneration!=generation) { pageGeneration=generation; wasLeft=wasRight=NO; }
    int step=atomic_exchange(&g_pendingPageStep,0);
    if (step) changeRingPage(step);
    else if (!atomic_load(&g_scrollTapActive)) {
        if (left && !wasLeft) changeRingPage(-1);
        if (right && !wasRight) changeRingPage(1);
    }
    wasLeft=left; wasRight=right;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        pollCommandShortcuts(generation);
    });
}

static void selectWindowImmediately(uint64_t generation, NSInteger selection, NSPoint pointer) {
    if (generation != atomic_load(&g_gestureGeneration) || !atomic_load(&g_gestureActive) || !g_panel) return;
    g_ringView.selectedIndex = selection;
    [g_ringView movePointerTo:pointer];
    moveMagnifiedBackdrop(pointer);
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
    if (generation != atomic_load(&g_gestureGeneration)) {
        diagnosticEvent(@"finish_skipped",@{@"requestedGeneration":@(generation),@"reason":@"new_gesture"});
        return;
    }
    diagnosticEvent(@"finish_requested",@{@"selection":@(selection)});
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
    BOOL quickPrevious=selection==kQuickPreviousSelection;
    if (quickPrevious) {
        selection=previousWindowIndex(g_standardRingEntries ?: g_windowEntries,g_quickTapWindowKey);
        diagnosticEvent(@"quick_previous_window",@{@"selection":@(selection),@"target":g_quickTapWindowKey ?: @""});
    }
    NSArray *pickEntries=quickPrevious ? (g_standardRingEntries ?: g_windowEntries) : g_windowEntries;
    RingEntry *picked = selection >= 0 && selection < (NSInteger)pickEntries.count
        ? pickEntries[(NSUInteger)selection] : nil;
    if (quickPrevious) picked=windowEntryForQuickSwitch(picked);
    if (g_standardRingEntries) {
        NSMutableArray<RingEntry *> *restored = [g_standardRingEntries mutableCopy];
        if (g_currentRingEntry && [restored indexOfObjectIdenticalTo:g_currentRingEntry] == NSNotFound)
            [restored insertObject:g_currentRingEntry atIndex:0];
        g_windowEntries=restored;
        atomic_store(&g_windowEntryCount,(int)g_windowEntries.count);
        g_standardRingEntries=nil;
        g_commandShortcutMode=NO;
        atomic_store(&g_fourFingerShortcutHeld, false);
        atomic_store(&g_fourFingerReleaseCandidateNanos, 0);
    }
    diagnosticEvent(@"menu_close",@{@"selection":@(selection),@"picked":diagnosticEntry(picked)});
    setRingPick(picked != nil, picked.isTab ? picked.chromeWindowID : nil);
    atomic_store(&g_gestureActive, false);
    atomic_store(&g_gestureEnding, false);
    if (g_panel) [g_panel orderOut:nil];
    if (g_snapshotPanel) [g_snapshotPanel orderOut:nil];
    // Release the captured screen image as soon as the menu closes.
    [g_magnifiedBackdrop removeAnimationForKey:@"backdropFadeIn"];
    [g_magnifiedBackdrop removeAnimationForKey:@"backdropZoomIn"];
    g_magnifiedBackdrop.contents = nil;
    g_magnifiedBackdrop.hidden = YES;
    g_magnifiedBackdrop.opacity = 0;
    atomic_store(&g_ringOverlayVisible, false);
    showSystemCursorAfterGesture();
    restoreCursorAfterGesture();
    releaseDecodedThumbnails();
    g_ringView.currentEntry = nil;
    g_currentRingEntry = nil;
    // Changes that happened while the ring was open were not applied.
    scanWindowsNow();
    if (!picked) return;
    RingEntry *entry=picked;
    if (entry.isSettings) { raiseSettingsWindow(); return; }
    if (entry.isShortcut) {
        if (entry.minimizesAllWindows) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
                if (generation==atomic_load(&g_gestureGeneration) && !atomic_load(&g_gestureActive)) minimizeAllWindows();
            });
        } else if (entry.opensNewChromeTab) {
            dispatch_async(g_windowActivationQueue, ^{
                runChromeScript(newChromeTabScript(entry));
            });
        } else [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:entry.folderPath]];
        return;
    }
    if (!entry.application || entry.application.isTerminated) {
        return;
    }
    recordRecentWindow(recentWindowKey(entry));
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
    if (entry.isShortcut) return entry.windowTitle;
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

// Ikonica bez podloge, centrirana preko donje ivice snimka.
static CGFloat drawCardBadgeIcon(RingEntry *entry, NSRect cardRect) {
    NSImage *icon = nil;
    if ([entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"] && atomic_load(&g_settingShowSiteIcons)) {
        icon = RingFaviconForURL(entry.tabURL) ?: entry.icon;
    } else if (atomic_load(&g_settingShowAppIcons)) {
        icon = entry.icon;
    }
    if (!icon) return 0;
    // No backing plate; a soft shadow keeps it readable on light pictures.
    CGFloat iconSize = MIN(56.0, MAX(24.0, NSWidth(cardRect) * 0.15));
    NSRect iconRect = NSMakeRect(NSMidX(cardRect) - iconSize / 2, NSMinY(cardRect) - iconSize * 0.40, iconSize, iconSize);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowBlurRadius = 6.0;
    shadow.shadowOffset = NSMakeSize(0, -1);
    shadow.shadowColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.55];
    [shadow set];
    [icon drawInRect:iconRect fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    return iconSize + 6.0;
}

static void drawCardLabel(NSString *text, NSRect cardRect, BOOL truncateMiddle, CGFloat leading) {
    if (!text.length) return;
    CGFloat iconSize = MIN(56.0, MAX(24.0, NSWidth(cardRect) * 0.15));
    CGFloat titleSpace = cardFooterHeight(NSWidth(cardRect)) - iconSize * 0.40 - 3;
    CGFloat fontSize = leading>0 ? leading : MIN(11.5, MAX(6.0, titleSpace / 1.4));
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = truncateMiddle ? NSLineBreakByTruncatingMiddle : NSLineBreakByTruncatingTail;
    NSShadow *shadow = [NSShadow new];
    shadow.shadowBlurRadius = 4;
    shadow.shadowOffset = NSMakeSize(0, -1);
    shadow.shadowColor = [NSColor blackColor];
    NSDictionary *drawAttr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:fontSize weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style,
        NSShadowAttributeName: shadow
    };
    [text drawInRect:NSMakeRect(NSMinX(cardRect), NSMinY(cardRect), NSWidth(cardRect), fontSize * 1.4)
       withAttributes:drawAttr];
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
static NSArray<NSDictionary *> *fetchChromeTabRows(pid_t pid);
static NSSet<NSString *> *liveChromeTabs(NSArray<RingEntry *> *entries) {
    NSMutableSet<NSNumber *> *pids=[NSMutableSet set];
    for (RingEntry *entry in entries) if (entry.chromeTabID.length)
        [pids addObject:@(entry.application.processIdentifier)];
    NSMutableSet<NSString *> *tabs=[NSMutableSet set];
    for (NSNumber *pid in pids) {
        NSArray *rows=fetchChromeTabRows(pid.intValue);
        if (!rows) return nil;
        for (NSDictionary *row in rows) [tabs addObject:[NSString stringWithFormat:@"%@:%@",row[@"windowID"],row[@"tabID"]]];
    }
    return tabs;
}

// -1 znači da pouzdan spisak nije dostupan; URL i naslov nisu identitet taba.
static NSInteger chromeTabMembership(RingEntry *entry, NSSet<NSString *> *openTabs) {
    if (!openTabs || !entry.chromeTabID.length || !entry.chromeWindowID.length) return -1;
    NSString *key=[NSString stringWithFormat:@"%@:%@",entry.chromeWindowID,entry.chromeTabID];
    return [openTabs containsObject:key] ? 1 : 0;
}

// Identitet je proces + prozor + tab. Dva taba istog linka ostaju odvojena.
static NSArray<RingEntry *> *reconcileChromeEntries(NSArray<RingEntry *> *entries, NSSet<NSString *> *openTabs) {
    NSMutableSet<NSString *> *seen=[NSMutableSet set];
    NSMutableArray<RingEntry *> *result=[NSMutableArray arrayWithCapacity:entries.count];
    for (RingEntry *entry in entries) {
        if (entry.chromeWindowID.length && entry.chromeTabID.length) {
            if (chromeTabMembership(entry,openTabs)==0) continue;
            NSString *identity=tabThumbnailKey(entry);
            if ([seen containsObject:identity]) continue;
            [seen addObject:identity];
        }
        [result addObject:entry];
    }
    return result.count==entries.count ? entries : result;
}

static void refreshChromeMembershipForRing(uint64_t generation) {
    if (!g_windowScanQueue) return;
    BOOL hasTabs=NO;
    for (RingEntry *entry in g_standardRingEntries) if (entry.chromeTabID.length) { hasTabs=YES; break; }
    if (!hasTabs) return;
    NSArray *snapshot=g_standardRingEntries;
    // Samo čitanje ID-eva; nijedan tab se ne aktivira radi provere.
    dispatch_async(g_windowScanQueue, ^{
        NSSet<NSString *> *live=liveChromeTabs(snapshot);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation!=atomic_load(&g_gestureGeneration) ||
                !atomic_load(&g_gestureActive) || atomic_load(&g_gestureEnding)) return;
            NSArray *before=g_standardRingEntries;
            NSArray *clean=reconcileChromeEntries(before,live);
            NSMutableArray *identities=[NSMutableArray array];
            for (RingEntry *entry in before) if (entry.chromeTabID.length)
                [identities addObject:diagnosticEntry(entry)];
            BOOL canRelayout=!g_commandShortcutMode && g_selectedIndex==-1 &&
                hypot(g_pointerX,g_pointerY)<0.12;
            diagnosticEvent(@"chrome_menu_inventory",@{@"known":@(live!=nil),
                @"liveCount":@(live.count),@"removed":@(before.count-clean.count),
                @"applied":@(canRelayout),@"cards":identities});
            g_standardRingEntries=clean;
            // Izabrana kartica ostaje na mestu do kraja gesta.
            if (clean==before || !canRelayout) return;
            configureRingPage(clean,g_ringPage);
            g_ringView.entries=g_windowEntries;
            g_ringView.layoutEntries=nil;
            [g_ringView updateCardLayersAnimated:NO refreshContents:YES];
            [g_ringView updateHubAnimated:NO];
            [g_ringView setNeedsDisplay:YES];
        });
    });
}

static void pruneDeadWindowEntriesLive(void) {
    if (atomic_load(&g_gestureActive)) return;
    if (!g_windowEntries || !g_windowEntries.count) return;
    // A tab closed in Chrome keeps its window, so the CG check below misses it.
    BOOL hasChromeTabs = NO;
    for (RingEntry *entry in g_windowEntries) {
        if (entry.chromeTabID.length) { hasChromeTabs = YES; break; }
    }
    NSSet<NSString *> *openChromeTabs = hasChromeTabs ? liveChromeTabs(g_windowEntries) : nil;

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

        NSInteger membership=chromeTabMembership(entry,openChromeTabs);
        if (membership==0) {
            changed=YES;
            [deadTabKeys addObject:tabThumbnailKey(entry)];
            continue;
        }
        // Chrome potvrđuje postojanje konkretnog taba. Njegova CG površina
        // može nestati ili se promeniti dok se drugi tab istog naslova zatvara.
        BOOL windowAliveInCG=membership==1 || (entry.windowID!=kCGNullWindowID &&
            (!canCheckWindowIDs || [liveWindowIDs containsObject:@(entry.windowID)]));
        if (membership!=1 && canCheckWindowIDs && entry.windowID!=kCGNullWindowID && !windowAliveInCG) {
            changed=YES;
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
        if (membership!=1 && entry.isTab && entry.accessibilityTabObject) {
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

// Upit je vezan za PID, jer Chrome za snimanje može imati isti bundle ID.
static NSArray<NSDictionary *> *fetchChromeTabRows(pid_t pid) {
    @synchronized ([SBApplication class]) {
    if (!ensureChromeAutomation(YES)) return nil;
    NSMutableArray<NSDictionary *> *rows=[NSMutableArray array];
    @try {
        SBApplication *chrome=[SBApplication applicationWithProcessIdentifier:pid];
        if (!chrome) return nil;
        chrome.sendMode=kAEWaitReply | kAENeverInteract;
        chrome.timeout=60;
        NSArray *windows=[chrome valueForKey:@"windows"];
        NSUInteger windowIndex=0;
        for (id window in windows) {
            windowIndex++;
            NSString *windowID=[[window valueForKey:@"id"] description];
            id boundsValue=[window valueForKey:@"bounds"];
            NSRect bounds=NSZeroRect;
            if ([boundsValue isKindOfClass:NSValue.class]) bounds=[boundsValue rectValue];
            NSUInteger activeIndex=[[window valueForKey:@"activeTabIndex"] unsignedIntegerValue];
            NSString *windowTitle=[window valueForKey:@"name"] ?: @"";
            NSArray *records=[[window valueForKey:@"tabs"] valueForKey:@"properties"];
            NSUInteger index=0;
            for (NSDictionary *record in records) {
                index++;
                NSString *tabID=[record[@"id"] description];
                if (!windowID.length || !tabID.length) continue;
                [rows addObject:@{@"windowIndex":@(windowIndex),@"windowID":windowID,
                    @"tabIndex":@(index),@"tabID":tabID,@"activeIndex":@(activeIndex),
                    @"bounds":[NSValue valueWithRect:bounds],@"windowTitle":windowTitle,
                    @"title":record[@"title"] ?: @"Tab",@"URL":record[@"URL"] ?: @""}];
            }
        }
        if (chrome.lastError) return nil;
    } @catch (NSException *exception) {
        diagnosticEvent(@"chrome_inventory_error",@{@"targetPID":@(pid),@"reason":exception.name ?: @"unknown"});
        return nil;
    }
    static NSMutableDictionary<NSNumber *,NSString *> *lastInventories;
    if (!lastInventories) lastInventories=[NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *ids=[NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *row in rows) [ids addObject:[NSString stringWithFormat:@"%@:%@",row[@"windowID"],row[@"tabID"]]];
    NSString *inventory=[ids componentsJoinedByString:@","];
    if (![inventory isEqualToString:lastInventories[@(pid)]]) {
        diagnosticEvent(@"chrome_inventory",@{@"targetPID":@(pid),@"tabs":@(rows.count),@"ids":ids});
        lastInventories[@(pid)]=inventory;
    }
    return rows;
    }
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
    NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = nil;
    @synchronized ([NSAppleScript class]) {
        result = [script executeAndReturnError:&error];
    }
    diagnosticEvent(@"chrome_script_result",@{@"success":@(!error && [result.stringValue isEqualToString:@"ok"]),
        @"result":error ? @"apple_event_error" : (result.stringValue ?: @"empty"),
        @"errorCode":error[NSAppleScriptErrorNumber] ?: @0,
        @"milliseconds":@((NSProcessInfo.processInfo.systemUptime-started)*1000)});
    if (error) {
        NSLog(@"[Chrome tabs] switch script failed: %@", error[NSAppleScriptErrorMessage] ?: error);
        return NO;
    }
    return [result.stringValue isEqualToString:@"ok"];
}

// Video and audio in the tabs are handled by ring_media.m, which notices the
// switch on its own.
static BOOL setChromeActiveTabWithIndex(pid_t pid, NSString *windowID, NSString *tabID, NSUInteger tabIndex1Based) {
    @synchronized ([SBApplication class]) {
    diagnosticEvent(@"chrome_switch_requested",@{@"targetPID":@(pid),@"window":windowID ?: @"",@"tab":tabID ?: @""});
    if (!validChromeID(windowID) || !ensureChromeAutomation(NO)) return NO;
    @try {
        SBApplication *chrome=[SBApplication applicationWithProcessIdentifier:pid];
        chrome.sendMode=kAEWaitReply | kAENeverInteract;
        chrome.timeout=60;
        SBElementArray *windows=[chrome valueForKey:@"windows"];
        id window=[windows objectWithID:windowID];
        NSArray *records=[[window valueForKey:@"tabs"] valueForKey:@"properties"];
        NSUInteger selected=0;
        if (validChromeID(tabID)) {
            for (NSUInteger i=0;i<records.count;i++) if ([[records[i][@"id"] description] isEqualToString:tabID]) {
                selected=i+1; break;
            }
        } else if (tabIndex1Based>0 && tabIndex1Based<=records.count) selected=tabIndex1Based;
        if (!selected || chrome.lastError) return NO;
        [window setValue:@1 forKey:@"index"];
        [window setValue:@(selected) forKey:@"activeTabIndex"];
        return chrome.lastError==nil;
    } @catch (NSException *exception) {
        diagnosticEvent(@"chrome_switch_error",@{@"targetPID":@(pid),@"reason":exception.name ?: @"unknown"});
        return NO;
    }
    }
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
            app.processIdentifier != getpid() &&
            ![app.bundleIdentifier isEqualToString:@"com.milev.touchpad-layout-preview"]) {
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
            BOOL hasBrowserSurface=NO;
            for (NSDictionary *info in windowInfos) if ([info[(id)kCGWindowOwnerPID] intValue]==app.processIdentifier &&
                [info[(id)kCGWindowLayer] integerValue]==0) { hasBrowserSurface=YES; break; }
            if (!hasBrowserSurface) continue;
            NSArray<NSDictionary *> *chromeTabs = fetchChromeTabRows(app.processIdentifier);
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

    entries=[reconcileChromeEntries(entries,nil) mutableCopy];

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
                ? [NSString stringWithFormat:@"%d:chrome:%@", entry.application.processIdentifier,
                    entry.chromeWindowID.length ? entry.chromeWindowID : [NSString stringWithFormat:@"cg:%u",entry.windowID]]
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
    g_currentRingEntry.thumbnail = nil;
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
static NSString *chromeActiveTab(pid_t pid, NSString *windowID, NSString **urlOut) {
    @synchronized ([SBApplication class]) {
    if (!validChromeID(windowID) || !ensureChromeAutomation(NO)) return nil;
    @try {
        SBApplication *chrome=[SBApplication applicationWithProcessIdentifier:pid];
        chrome.sendMode=kAEWaitReply | kAENeverInteract;
        chrome.timeout=60;
        SBElementArray *windows=[chrome valueForKey:@"windows"];
        id window=[windows objectWithID:windowID];
        NSDictionary *record=[[window valueForKey:@"activeTab"] valueForKey:@"properties"];
        NSString *tabID=[record[@"id"] description];
        if (chrome.lastError || !validChromeID(tabID)) return nil;
        if (urlOut) *urlOut=record[@"URL"];
        return tabID;
    } @catch (NSException *exception) { return nil; }
    }
}

// Identitet mora ostati isti tokom čekanja na iscrtavanje i samog snimanja.
static BOOL sameChromeCapturePage(NSString *beforeID, NSString *beforeURL,
                                  NSString *afterID, NSString *afterURL) {
    return beforeID.length && beforeURL.length && [beforeID isEqualToString:afterID] &&
        [chromePageIdentity(beforeURL) isEqualToString:chromePageIdentity(afterURL)];
}

static CGImageRef captureVerifiedChromeWindow(SCWindow *window, NSString *chromeWindowID,
                                              NSString **tabOut, NSString **urlOut) {
    NSString *beforeURL = nil;
    NSString *beforeID = chromeActiveTab(window.owningApplication.processID,chromeWindowID, &beforeURL);
    if (!beforeID.length || !beforeURL.length) return NULL;
    // Chrome može promeniti aktivni ID pre nego što prikaže novu stranicu.
    usleep(180000);
    NSString *settledURL = nil;
    NSString *settledID = chromeActiveTab(window.owningApplication.processID,chromeWindowID, &settledURL);
    if (!sameChromeCapturePage(beforeID,beforeURL,settledID,settledURL)) return NULL;
    CGImageRef image = captureWindowImage(window);
    if (!image) return NULL;
    NSString *afterURL = nil;
    NSString *afterID = chromeActiveTab(window.owningApplication.processID,chromeWindowID, &afterURL);
    if (!sameChromeCapturePage(beforeID,beforeURL,afterID,afterURL)) {
        CGImageRelease(image);
        return NULL;
    }
    if (tabOut) *tabOut = afterID;
    if (urlOut) *urlOut = afterURL;
    return image;
}

static _Atomic(bool) g_liveCaptureBusy = false;

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
    NSArray<RingEntry *> *visibleEntries = g_currentRingEntry
        ? [g_windowEntries arrayByAddingObject:g_currentRingEntry] : g_windowEntries;

    pid_t frontPID = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSMutableDictionary<NSNumber *, RingEntry *> *entryByWindow = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *windowOrder = [NSMutableArray array];
    for (RingEntry *entry in visibleEntries) {
        NSNumber *windowKey = @(entry.windowID);
        if (entry.windowID == kCGNullWindowID || ![onScreenIDs containsObject:windowKey]) continue;
        if (onlyPID > 0 && entry.application.processIdentifier != onlyPID) continue;
        if (entry.isTab && [entry.application.bundleIdentifier isEqualToString:@"com.google.Chrome"] &&
            (!entry.chromeWindowID.length || !entry.chromeTabID.length)) continue;
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
    if (!targets.count || atomic_exchange(&g_liveCaptureBusy, true)) return;

    dispatch_async(g_liveCaptureQueue, ^{
        @try {
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
            CGImageRef image = NULL;
            if (chromeWindowID.length) {
                NSString *activeTabID = nil;
                image = captureVerifiedChromeWindow(window, chromeWindowID, &activeTabID, &pageURL);
                if (!image || !activeTabID.length) continue;
                tabKey = [NSString stringWithFormat:@"%d:chrome:%@:%@", [target[@"pid"] intValue],
                          chromeWindowID, activeTabID];
            } else {
                image = captureWindowImage(window);
            }
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
                    for (RingEntry *entry in visibleEntries) {
                        if (entry.windowID != windowKey.unsignedIntValue) continue;
                        BOOL matches = tabKey ? (entry.isTab && [tabThumbnailKey(entry) isEqualToString:tabKey])
                                              : !entry.isTab;
                        if (matches && result[@"pageURL"])
                            matches = [chromePageIdentity(entry.tabURL) isEqualToString:chromePageIdentity(result[@"pageURL"])];
                        if (matches) applyThumbnailDataToEntry(entry, data);
                    }
                }
            }
            if (g_ringView && atomic_load(&g_ringOverlayVisible)) [g_ringView setNeedsDisplay:YES];
        });
        } @finally { atomic_store(&g_liveCaptureBusy, false); }
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

static void loadHiddenChromeTabs(uint64_t generation) {
    // Skriveni tabovi čuvaju poslednji snimak; nikada ih ne aktiviraj radi slike.
    (void)generation;
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
                // Chrome koristi isključivo snimanje sa stvarnim ID-em pre i
                // posle slike; periodični spisak tabova može biti zastareo.
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
    refreshThumbnailsNow(0, 0.6);
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
    if (count<=0) return -1;
    CGFloat radiusX=1, radiusY=1;
    ringEllipseRadii((NSUInteger)count,1,&radiusX,&radiusY);
    // Ista elipsa kao pri ograničavanju kretanja: sve kartice su dostupne.
    double distance=hypot(g_pointerX/radiusX,g_pointerY/radiusY);
    if (distance<(currentIndex>=0 ? kPointerDeadZone : kPointerSelectZone)) return -1;
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

// Četiri prsta poništavaju izbor, a vraćanje na tri odmah oslobađa novu gestu.
static BOOL suppressTouchFrameAfterFourFingers(int activeCount, BOOL *waitingForLift) {
    if (activeCount >= 4) *waitingForLift = YES;
    if (!*waitingForLift) return NO;
    // Tri prsta su nova gesta i posle slučajnog četvrtog kontakta.
    if (activeCount<=3) {
        *waitingForLift=NO;
        return NO;
    }
    return YES;
}

static _Atomic(bool) g_touchReopenBlocked=false;

static BOOL isQuickThreeFingerTap(uint64_t started,uint64_t now,double travel,BOOL eligible) {
    return eligible && started>0 && now>=started && now-started<500000000ULL && travel<0.12;
}

// Nova tri prsta počinju nov izbor i kada preostali prsti nisu podignuti.
static void beginTouchGesture(MTDeviceRef device, double x, double y) {
    atomic_store(&g_gestureActive, true);
    atomic_store(&g_gestureEnding, false);
    atomic_store(&g_fourFingerShortcutHeld, false);
    atomic_store(&g_fourFingerReleaseCandidateNanos, 0);
    atomic_store(&g_touchStartedNanos,(uint64_t)(NSProcessInfo.processInfo.systemUptime*1000000000.0));
    atomic_store(&g_quickTapEligible,true);
    g_touchMaxTravel=0;
    hideSystemCursorForGesture();
    g_previousX = x;
    g_previousY = y;
    g_pointerX = 0.0;
    g_pointerY = 0.0;
    g_selectedIndex = -1;
    int surfaceWidth = 0, surfaceHeight = 0;
    if (device && MTDeviceGetSensorSurfaceDimensions(device, &surfaceWidth, &surfaceHeight) == 0 &&
        surfaceWidth > 0 && surfaceHeight > 0) {
        g_trackpadAspect = (double)surfaceHeight / (double)surfaceWidth;
    }
    CGEventRef cursorEvent = CGEventCreate(NULL);
    if (cursorEvent) {
        g_cursorAtGestureStart = CGEventGetLocation(cursorEvent);
        CFRelease(cursorEvent);
    }
    uint64_t generation = atomic_fetch_add(&g_gestureGeneration, 1) + 1;
    diagnosticEvent(@"gesture_start",@{@"source":@"trackpad"});
    NSLog(@"[touch] three-finger gesture started");
    dispatch_async(dispatch_get_main_queue(), ^{ showRing(generation); });
}

// Ako se prsti vrate brzo, prvo dovrši prethodni izbor na glavnom redu.
static void reopenTouchGestureWhenReady(MTDeviceRef device, uint64_t generation) {
    if (generation!=atomic_load(&g_gestureGeneration) || atomic_load(&g_activeTouchCount)!=3 ||
        atomic_load(&g_mouseGestureActive) || atomic_load(&g_keyboardGestureActive) ||
        atomic_load(&g_touchReopenBlocked)) return;
    if (atomic_load(&g_gestureEnding)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            reopenTouchGestureWhenReady(device,generation);
        });
        return;
    }
    if (!atomic_load(&g_gestureActive)) beginTouchGesture(device,g_previousX,g_previousY);
}

static int ringTouchCallback(MTDeviceRef device, MTTouch *touches, int numTouches, double timestamp, int frame) {
    (void)frame;
    (void)timestamp;
    @autoreleasepool {
        static BOOL suppressUntilFourFingerLift = NO;
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
        int previousCount=atomic_exchange(&g_activeTouchCount,activeCount);
        if (previousCount!=activeCount) diagnosticEvent(@"touch_count",@{@"previous":@(previousCount),@"current":@(activeCount)});
        BOOL hadThreeFingers = threeFingersLastFrame;
        threeFingersLastFrame = activeCount == 3;
        BOOL touchCountChanged = previousCount != activeCount;

        if (activeCount >= 3) {
            uint64_t nowNanos = (uint64_t)(NSProcessInfo.processInfo.systemUptime * 1000000000.0);
            atomic_store(&g_scrollSuppressionUntilNanos, nowNanos + 350000000ULL);
            atomic_store(&g_scrollSuppressionActive, true);
            // Zaustavi i preostale momentum frejmove prethodnog skrola.
            atomic_store(&g_suppressGestureMomentum,true);
        }

        BOOL gestureActive = atomic_load(&g_gestureActive);
        int shortcutTrigger=atomic_load(&g_settingShortcutTrigger);
        BOOL fourOpensSection=!fourFingersCancelOpenMenu(shortcutTrigger) && gestureActive;
        if (!fourOpensSection) {
            BOOL suppressed = suppressTouchFrameAfterFourFingers(activeCount, &suppressUntilFourFingerLift);
            atomic_store(&g_touchReopenBlocked,suppressUntilFourFingerLift);
            if (activeCount >= 4) {
                atomic_store(&g_quickTapEligible,false);
                if (previousCount<4) diagnosticEvent(@"four_finger_cancel",nil);
                if (gestureActive) {
                    // Invalidate any pending normal lift completion so it cannot
                    // activate the previously selected entry after a four-touch.
                    uint64_t generation = atomic_fetch_add(&g_gestureGeneration, 1) + 1;
                    atomic_store(&g_gestureEnding, true);
                    atomic_store(&g_gestureActive, false);
                    atomic_store(&g_fourFingerShortcutHeld, false);
                    atomic_store(&g_fourFingerReleaseCandidateNanos, 0);
                    dispatch_async(dispatch_get_main_queue(), ^{ finishGesture(generation, -1); });
                }
                return 0;
            }
            if (suppressed) return 0;
        } else if (activeCount >= 4) {
            atomic_store(&g_quickTapEligible,false);
            atomic_store(&g_fourFingerReleaseCandidateNanos, 0);
            if (!atomic_exchange(&g_fourFingerShortcutHeld, true)) {
                diagnosticEvent(@"four_finger_shortcuts",nil);
                uint64_t generation=atomic_load(&g_gestureGeneration);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation==atomic_load(&g_gestureGeneration) && atomic_load(&g_gestureActive))
                        applyShortcutSection();
                });
            }
        } else if (atomic_load(&g_fourFingerShortcutHeld) && activeCount==3) {
            // Kratka pauza: podizanje svih prstiju prolazi kroz tri, pa meni prečica ostaje.
            uint64_t nowNanos=(uint64_t)(NSProcessInfo.processInfo.systemUptime*1000000000.0);
            uint64_t candidate=atomic_load(&g_fourFingerReleaseCandidateNanos);
            if (candidate==0) atomic_store(&g_fourFingerReleaseCandidateNanos, nowNanos);
            else if (nowNanos-candidate>=70000000ULL) releaseFourFingerShortcutHold();
        } else if (activeCount<3 && atomic_load(&g_fourFingerShortcutHeld) &&
                   (atomic_load(&g_mouseGestureActive) || atomic_load(&g_keyboardGestureActive))) {
            // Miš i tastatura ne puštaju izbor skidanjem prstiju, ali četvrti prst više nije pritisnut.
            releaseFourFingerShortcutHold();
        } else {
            atomic_store(&g_fourFingerReleaseCandidateNanos, 0);
        }

        // Dodir trackpada ne završava meni otvoren mišem ili tastaturom.
        if (atomic_load(&g_mouseGestureActive) || atomic_load(&g_keyboardGestureActive)) return 0;

        if (activeCount==3 && atomic_load(&g_gestureEnding)) {
            g_previousX=sumX/3.0;
            g_previousY=sumY/3.0;
            if (!hadThreeFingers) {
                uint64_t generation=atomic_load(&g_gestureGeneration);
                dispatch_async(dispatch_get_main_queue(), ^{
                    reopenTouchGestureWhenReady(device,generation);
                });
            }
        } else if (!gestureActive && activeCount==3) {
            beginTouchGesture(device,sumX/3.0,sumY/3.0);
        } else if (gestureActive && !atomic_load(&g_gestureEnding)) {
            if (activeCount<3 && !atomic_load(&g_mouseGestureActive) &&
                !atomic_load(&g_keyboardGestureActive)) {
                uint64_t generation=atomic_load(&g_gestureGeneration);
                NSInteger selection=selectionForLift();
                uint64_t now=(uint64_t)(NSProcessInfo.processInfo.systemUptime*1000000000.0);
                BOOL quick=!atomic_load(&g_settingCurrentWindowInCenter) &&
                    isQuickThreeFingerTap(atomic_load(&g_touchStartedNanos),now,g_touchMaxTravel,
                    atomic_exchange(&g_quickTapEligible,false) && selection==-1 &&
                    !atomic_load(&g_fourFingerShortcutHeld) &&
                    !(CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState)&kCGEventFlagMaskCommand));
                if (quick) selection=kQuickPreviousSelection;
                diagnosticEvent(@"touch_release",@{@"selection":@(selection),@"quickTap":@(quick)});
                atomic_store(&g_gestureEnding,true);
                dispatch_async(dispatch_get_main_queue(), ^{ finishGesture(generation,selection); });
                return 0;
            }

            if (activeCount >= 3) {
                double x = sumX / activeCount, y = sumY / activeCount;
                // Novi ili podignuti prst pomera centar dodira, a to nije pokret ka kartici.
                if (previousCount>=3 && !touchCountChanged) {
                    moveRingPointer(x - g_previousX, (y - g_previousY) * g_trackpadAspect,
                                    atomic_load(&g_windowEntryCount));
                }
                g_touchMaxTravel=MAX(g_touchMaxTravel,hypot(g_pointerX,g_pointerY));
                // After a finger is lifted and put back, its new spot is not motion.
                g_previousX = x;
                g_previousY = y;
                NSInteger selection = pointerSelection(atomic_load(&g_windowEntryCount), g_selectedIndex);
                if (selection != g_selectedIndex) {
                    g_selectedIndex = selection;
                    diagnosticEvent(@"selection",@{@"index":@(selection),@"x":@(g_pointerX),@"y":@(g_pointerY)});
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
    diagnosticEvent(@"trackpad_listeners",@{@"devices":@(CFArrayGetCount(g_devices))});
    NSLog(@"[touch] listening on %ld trackpad device(s)", (long)CFArrayGetCount(g_devices));
}

// Tema menja rok osvežavanja, a postojeće slike ostaju dok nove ne stignu.
static void invalidateThumbnailCaptureTimes(void) {
    @synchronized ([NSMutableDictionary class]) {
        [g_windowLastCaptured removeAllObjects];
        [g_tabLastCaptured removeAllObjects];
        [g_chromeWindowLastCapture removeAllObjects];
    }
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
        invalidateThumbnailCaptureTimes();
        if (g_thumbnailPreviewsEnabled) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                refreshThumbnailsNow(0, 0);
                schedulePendingThumbnailCapture(g_windowEntries);
            });
        }
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
            __block NSArray<RingEntry *> *entries = collectOpenWindows();
            pruneThumbnailCaches(entries);
            populateThumbnailsFromCache(entries);
            entries = entriesWorthShowing(entries);
            noteChromeSelectionChanges(entries);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!atomic_load(&g_gestureActive)) {
                    RingEntry *settings=settingsEntryIfVisible();
                    if (settings) entries=[entries arrayByAddingObject:settings];
                    entries=entriesWithPersistentShortcuts(entries);
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
    Boolean shortcutValid=false;
    CFIndex shortcutMask=CFPreferencesGetAppIntegerValue(CFSTR("CommandShortcuts"),kSettingsID,&shortcutValid);
    unsigned shortcuts=shortcutValid ? (unsigned)shortcutMask&63 : 47;
    Boolean migrationValid=false;
    CFIndex optionsVersion=CFPreferencesGetAppIntegerValue(CFSTR("ShortcutOptionsVersion"),kSettingsID,&migrationValid);
    if (!migrationValid || optionsVersion<2) {
        shortcuts|=32; // Nova Cmd akcija je dostupna i postojećim korisnicima.
        int value=(int)shortcuts,version=2;
        CFNumberRef saved=CFNumberCreate(NULL,kCFNumberIntType,&value);
        CFNumberRef marker=CFNumberCreate(NULL,kCFNumberIntType,&version);
        CFPreferencesSetAppValue(CFSTR("CommandShortcuts"),saved,kSettingsID);
        CFPreferencesSetAppValue(CFSTR("ShortcutOptionsVersion"),marker,kSettingsID);
        CFRelease(saved); CFRelease(marker);
        CFPreferencesAppSynchronize(kSettingsID);
    }
    atomic_store(&g_shortcutMask,shortcuts);
    Boolean persistentValid=false;
    CFIndex persistentMask=CFPreferencesGetAppIntegerValue(CFSTR("PersistentShortcuts"),kSettingsID,&persistentValid);
    atomic_store(&g_persistentShortcutMask,persistentValid ? (unsigned)persistentMask&63 : 0);
    Boolean triggerValid=false;
    CFIndex shortcutTrigger=CFPreferencesGetAppIntegerValue(CFSTR("ShortcutTrigger"),kSettingsID,&triggerValid);
    atomic_store(&g_settingShortcutTrigger,
                 triggerValid && shortcutTrigger>=ShortcutTriggerNone && shortcutTrigger<=ShortcutTriggerBoth
                     ? (int)shortcutTrigger : ShortcutTriggerCommand);
    Boolean valid = false;
    CFIndex titles = CFPreferencesGetAppIntegerValue(CFSTR("CardTitles"), kSettingsID, &valid);
    atomic_store(&g_settingCardTitles, valid && titles >= CardTitlesAll && titles <= CardTitlesNone
                                           ? (int)titles : CardTitlesNone);
    // AutoPauseMedia replaces PauseVideoOnTabSwitch and keeps its old value.
    g_mediaOptions.pauseWhenLeaving = settingBool(CFSTR("AutoPauseMedia"),
                                                  settingBool(CFSTR("PauseVideoOnTabSwitch"), NO));
    g_mediaOptions.resumeWhenReturning = settingBool(CFSTR("AutoResumeMedia"), NO);
    g_mediaOptions.resumeManuallyPaused = settingBool(CFSTR("MediaResumeManuallyPaused"), NO);
    g_mediaOptions.followAllTabChanges = settingBool(CFSTR("MediaFollowAllTabChanges"), YES);
    g_mediaOptions.onlyWhenNextTabHasVideo = settingBool(CFSTR("MediaOnlyWhenNextTabHasVideo"), NO);
    g_mediaOptions.rewindAfterLongPause = settingBool(CFSTR("MediaRewindAfterLongPause"), YES);
    atomic_store(&g_settingFinderTabsOneCard, settingBool(CFSTR("FinderTabsAsOneCard"), NO));
    Boolean groupingValid = false;
    CFIndex grouping = CFPreferencesGetAppIntegerValue(CFSTR("CardGrouping"), kSettingsID, &groupingValid);
    atomic_store(&g_settingCardGrouping, groupingValid && grouping == CardGroupingApps ? CardGroupingApps : CardGroupingWindows);
    atomic_store(&g_settingCurrentWindowInCenter, settingBool(CFSTR("CurrentWindowInCenter"), NO));
    atomic_store(&g_settingSoundEffects, settingBool(CFSTR("SoundEffects"), NO));
    atomic_store(&g_settingMouseHoldToSelect, settingBool(CFSTR("MouseHoldToSelect"), YES));
    atomic_store(&g_settingShowSiteIcons, settingBool(CFSTR("ShowSiteIcons"), YES));
    atomic_store(&g_settingShowAppIcons, settingBool(CFSTR("ShowAppIcons"), YES));
    Boolean pointerValid = false;
    CFIndex pointerStyle = CFPreferencesGetAppIntegerValue(CFSTR("PointerStyle"), kSettingsID, &pointerValid);
    atomic_store(&g_settingPointerStyle, pointerValid && pointerStyle >= PointerStyleArrow && pointerStyle <= PointerStyleHidden
                                             ? (int)pointerStyle : PointerStyleHidden);
    Boolean highlightValid = false;
    CFIndex highlight = CFPreferencesGetAppIntegerValue(CFSTR("HighlightColor"), kSettingsID, &highlightValid);
    atomic_store(&g_settingHighlightColor, highlightValid && highlight >= HighlightSystem && highlight <= HighlightWhite
                                             ? (int)highlight : HighlightSystem);
    atomic_store(&g_settingShowLight, settingBool(CFSTR("ShowLight"), YES));
    Boolean dimmingValid = false;
    CFIndex dimming = CFPreferencesGetAppIntegerValue(CFSTR("BackdropDimming"), kSettingsID, &dimmingValid);
    atomic_store(&g_settingBackdropDimming, dimmingValid ? (int)MIN(MAX(dimming, 0), 90) : 50);
    NSArray *backdrop = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("BackdropColor"), kSettingsID));
    if ([backdrop isKindOfClass:[NSArray class]] && backdrop.count == 3) {
        g_backdropColor = [NSColor colorWithSRGBRed:[backdrop[0] doubleValue] green:[backdrop[1] doubleValue]
                                               blue:[backdrop[2] doubleValue] alpha:1];
    }
    Boolean blurValid = false;
    CFIndex blurRadius = CFPreferencesGetAppIntegerValue(CFSTR("BlurRadius"), kSettingsID, &blurValid);
    atomic_store(&g_settingBlurRadius, blurValid ? (int)MIN(MAX(blurRadius, 0), 40) : 20);
    Boolean zoomValid = false;
    CFIndex zoom = CFPreferencesGetAppIntegerValue(CFSTR("BackdropZoom"), kSettingsID, &zoomValid);
    atomic_store(&g_settingBackdropZoom, zoomValid ? (int)MIN(MAX(zoom, 0), 25) : 5);
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

// Podešavanja se zatvaraju preko X, Esc ili Cmd+W, a ostaju otvorena
// kada druga aplikacija dobije fokus.
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

@interface SettingsMenu : NSObject <NSWindowDelegate, NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSButton *hideIconCheckbox;
@property(nonatomic, strong) SettingsWindow *window;
@property(nonatomic, strong) NSTextField *javaScriptHint;
@property(nonatomic, strong) NSTextField *blurLabel;
@property(nonatomic, strong) NSTextField *zoomLabel;
@property(nonatomic, strong) NSTextField *dimmingLabel;
@property(nonatomic, strong) NSTextField *gestureWarning;
@property(nonatomic, strong) NSTextField *mouseActivationLabel;
@property(nonatomic, strong) NSTextField *mouseLearnStatus;
@property(nonatomic, strong) NSButton *updateButton;
@property(nonatomic, strong) NSTextField *updateStatus;
@property(nonatomic, strong) RingRelease *latestRelease;
@property(nonatomic) NSTimeInterval lastUpdateCheck;
@end

@implementation SettingsMenu
- (void)handleReopenEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply {
    (void)event; (void)reply;
    [self applicationShouldHandleReopen:NSApp hasVisibleWindows:self.window.isVisible];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {
    (void)application; (void)visible;
    atomic_store(&g_settingHideMenuIcon, false);
    storeSetting(CFSTR("HideMenuBarIcon"), kCFBooleanFalse);
    [self showIcon];
    self.hideIconCheckbox.state = NSControlStateValueOff;
    if (!self.window.isVisible) [self togglePanel:nil];
    else { [self.window makeKeyAndOrderFront:nil]; activateSelf(); }
    return NO;
}
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
    note.font = [NSFont systemFontOfSize:12];
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
    column.spacing = 10;
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
    NSButton *currentCenter = [NSButton checkboxWithTitle:@"Trenutni prozor ili tab u centru"
                                                   target:self action:@selector(currentWindowInCenterChanged:)];
    currentCenter.state = atomic_load(&g_settingCurrentWindowInCenter)
        ? NSControlStateValueOn : NSControlStateValueOff;

    NSTextField *pointerLabel = [self noteWithText:@"Pokazivač"];
    NSSegmentedControl *pointer = [NSSegmentedControl segmentedControlWithLabels:@[@"Strelica", @"Krug", @"Nevidljiv"]
                                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                          target:self
                                                                          action:@selector(pointerStyleChanged:)];
    pointer.controlSize = NSControlSizeSmall;
    pointer.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    pointer.selectedSegment = atomic_load(&g_settingPointerStyle);

    NSTextField *highlightLabel = [self noteWithText:@"Boja pokazivača i svetla"];
    NSSegmentedControl *highlight = [NSSegmentedControl segmentedControlWithLabels:@[@"Boja sistema", @"Belo"]
                                                                      trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                            target:self
                                                                            action:@selector(highlightColorChanged:)];
    highlight.controlSize = NSControlSizeSmall;
    highlight.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    highlight.selectedSegment = atomic_load(&g_settingHighlightColor);
    NSButton *light = [NSButton checkboxWithTitle:@"Svetlo u smeru prstiju"
                                           target:self action:@selector(showLightChanged:)];
    light.state = atomic_load(&g_settingShowLight) ? NSControlStateValueOn : NSControlStateValueOff;

    self.dimmingLabel = [self noteWithText:@""];
    [self updateDimmingLabel];
    NSSlider *dimmingSlider = [NSSlider sliderWithValue:atomic_load(&g_settingBackdropDimming) minValue:0 maxValue:90
                                                 target:self action:@selector(backdropDimmingChanged:)];
    dimmingSlider.controlSize = NSControlSizeSmall;
    NSColorWell *backdropWell = [NSColorWell colorWellWithStyle:NSColorWellStyleMinimal];
    backdropWell.color = g_backdropColor ?: [NSColor colorWithSRGBRed:0.02 green:0.02 blue:0.02 alpha:1];
    backdropWell.supportsAlpha = NO;
    backdropWell.target = self;
    backdropWell.action = @selector(backdropColorChanged:);
    [backdropWell.widthAnchor constraintEqualToConstant:44].active = YES;
    [backdropWell.heightAnchor constraintEqualToConstant:24].active = YES;
    [dimmingSlider.heightAnchor constraintEqualToConstant:24].active = YES;
    NSStackView *backdropRow = [NSStackView stackViewWithViews:@[backdropWell, dimmingSlider]];
    backdropRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    backdropRow.spacing = 12;
    backdropRow.alignment = NSLayoutAttributeCenterY;
    [backdropRow.heightAnchor constraintEqualToConstant:28].active = YES;
    [backdropRow.widthAnchor constraintEqualToConstant:kSettingsColumnWidth].active = YES;

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
    [blur.heightAnchor constraintEqualToConstant:24].active = YES;
    self.zoomLabel = [self noteWithText:@""];
    [self updateZoomLabel];
    NSSlider *zoom = [NSSlider sliderWithValue:atomic_load(&g_settingBackdropZoom) minValue:0 maxValue:25
                                        target:self action:@selector(backdropZoomChanged:)];
    zoom.controlSize = NSControlSizeSmall;
    [zoom.widthAnchor constraintEqualToConstant:kSettingsColumnWidth].active = YES;
    [zoom.heightAnchor constraintEqualToConstant:24].active = YES;

    NSButton *hideIcon = [NSButton checkboxWithTitle:@"Sakrij ikonicu iz gornje trake"
                                              target:self action:@selector(hideIconChanged:)];
    self.hideIconCheckbox = hideIcon;
    hideIcon.state = atomic_load(&g_settingHideMenuIcon) ? NSControlStateValueOn : NSControlStateValueOff;
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
    NSButton *logs=[NSButton buttonWithTitle:@"Otvori logove" target:self action:@selector(openDiagnosticLogs:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.updateButton, logs, quit]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 8;

    NSTextField *lookTitle = [self sectionTitle:@"Izgled menija"];
    NSTextField *menuBarTitle = [self sectionTitle:@"Gornja traka"];

    NSStackView *cardsColumn = [self settingsColumn:@[cardsTitle, grouping, currentCenter, titlesLabel, titles, siteIcons, appIcons,
                                                      finderTabs, lookTitle, pointerLabel, pointer, highlightLabel, highlight,
                                                      light, self.dimmingLabel, backdropRow,
                                                      self.blurLabel, blur, self.zoomLabel, zoom, sounds]];
    [cardsColumn setCustomSpacing:kSettingsTitleGap afterView:cardsTitle];
    [cardsColumn setCustomSpacing:14 afterView:grouping];
    [cardsColumn setCustomSpacing:14 afterView:currentCenter];
    [cardsColumn setCustomSpacing:6 afterView:titlesLabel];
    [cardsColumn setCustomSpacing:14 afterView:titles];
    [cardsColumn setCustomSpacing:kSettingsSectionGap afterView:finderTabs];
    [cardsColumn setCustomSpacing:kSettingsTitleGap afterView:lookTitle];
    [cardsColumn setCustomSpacing:6 afterView:pointerLabel];
    [cardsColumn setCustomSpacing:14 afterView:pointer];
    [cardsColumn setCustomSpacing:6 afterView:highlightLabel];
    [cardsColumn setCustomSpacing:8 afterView:highlight];
    [cardsColumn setCustomSpacing:14 afterView:light];
    [cardsColumn setCustomSpacing:6 afterView:self.dimmingLabel];
    [cardsColumn setCustomSpacing:14 afterView:backdropRow];
    [cardsColumn setCustomSpacing:6 afterView:self.blurLabel];
    [cardsColumn setCustomSpacing:14 afterView:blur];
    [cardsColumn setCustomSpacing:6 afterView:self.zoomLabel];
    [cardsColumn setCustomSpacing:14 afterView:blur];

    NSTextField *shortcutsTitle=[self sectionTitle:@"Prečice"];
    NSTextField *triggerLabel=[self noteWithText:@"Poseban meni"];
    NSSegmentedControl *trigger=[NSSegmentedControl segmentedControlWithLabels:@[@"Nema", @"Cmd", @"4 prsta", @"Oba"]
                                                                   trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                         target:self
                                                                         action:@selector(shortcutTriggerChanged:)];
    trigger.controlSize=NSControlSizeSmall;
    trigger.font=[NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    int triggerMode=atomic_load(&g_settingShortcutTrigger);
    if (triggerMode<ShortcutTriggerNone || triggerMode>ShortcutTriggerBoth) triggerMode=ShortcutTriggerCommand;
    trigger.selectedSegment=triggerMode;
    [trigger.widthAnchor constraintEqualToConstant:kSettingsColumnWidth].active=YES;
    NSMutableArray *shortcutRows=[NSMutableArray array];
    NSArray *shortcutNames=@[@"Downloads",@"Desktop",@"Documents",@"Novi Chrome tab",@"Novi YouTube tab",@"Spusti sve prozore"];
    for (NSUInteger i=0;i<shortcutNames.count;i++) {
        NSTextField *name=[NSTextField labelWithString:shortcutNames[i]];
        [name.widthAnchor constraintEqualToConstant:145].active=YES;
        NSButton *cmd=[NSButton checkboxWithTitle:@"Meni" target:self action:@selector(shortcutOptionChanged:)];
        cmd.tag=i;
        cmd.state=(atomic_load(&g_shortcutMask)&(1u<<i)) ? NSControlStateValueOn : NSControlStateValueOff;
        NSButton *always=[NSButton checkboxWithTitle:@"Stalno" target:self action:@selector(shortcutOptionChanged:)];
        always.tag=32+i;
        always.state=(atomic_load(&g_persistentShortcutMask)&(1u<<i)) ? NSControlStateValueOn : NSControlStateValueOff;
        NSStackView *row=[NSStackView stackViewWithViews:@[name,cmd,always]];
        row.orientation=NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing=10;
        [shortcutRows addObject:row];
    }
    NSTextField *shortcutNote=[self noteWithText:@"Nema: poseban meni se ne otvara, a četiri prsta i dalje poništavaju izbor. Cmd: drži taster dok je meni otvoren. 4 prsta: dodaj četvrti prst; podizanje tog prsta vraća prozore. Oba: rade i Cmd i četvrti prst. Meni bira šta ulazi u poseban meni. Stalno prikazuje prečicu među aplikacijama i bez njega. Spusti sve prozore spušta prozore u Dock; ostale prečice otvaraju tab ili folder."];
    NSStackView *mouseColumn = [self settingsColumn:@[mouseTitle, self.mouseActivationLabel, mouseButtons, holdToSelect,
                                                      self.mouseLearnStatus, mouseNote, menuBarTitle, hideIcon, hideNote,
                                                      startAtLogin, shortcutsTitle, triggerLabel, trigger,
                                                      shortcutRows[0], shortcutRows[1], shortcutRows[2], shortcutRows[3],
                                                      shortcutRows[4], shortcutRows[5], shortcutNote]];
    [mouseColumn setCustomSpacing:kSettingsTitleGap afterView:mouseTitle];
    [mouseColumn setCustomSpacing:kSettingsSectionGap afterView:mouseNote];
    [mouseColumn setCustomSpacing:kSettingsTitleGap afterView:menuBarTitle];
    [mouseColumn setCustomSpacing:6 afterView:hideIcon];
    [mouseColumn setCustomSpacing:kSettingsSectionGap afterView:startAtLogin];
    [mouseColumn setCustomSpacing:kSettingsTitleGap afterView:shortcutsTitle];
    [mouseColumn setCustomSpacing:6 afterView:triggerLabel];
    [mouseColumn setCustomSpacing:8 afterView:trigger];

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
    [stack setCustomSpacing:20 afterView:self.gestureWarning];
    [stack setCustomSpacing:20 afterView:self.updateStatus];
    [stack setCustomSpacing:20 afterView:buttons];
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
        self.window.title = @"Touchpad Switcher - Podešavanja";
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
    scanWindowsNow();
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

// Podešavanja ostaju otvorena i kada druga aplikacija dobije fokus.
- (void)applicationResignedActive:(NSNotification *)notification {
    (void)notification;
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
                    self.updateStatus.stringValue = @"";
                }
            }
            self.updateStatus.hidden = self.updateStatus.stringValue.length == 0;
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

- (void)currentWindowInCenterChanged:(NSButton *)button {
    BOOL enabled = button.state == NSControlStateValueOn;
    atomic_store(&g_settingCurrentWindowInCenter, enabled);
    storeSetting(CFSTR("CurrentWindowInCenter"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
}

- (void)pointerStyleChanged:(NSSegmentedControl *)control {
    int style = (int)MIN(MAX(control.selectedSegment, PointerStyleArrow), PointerStyleHidden);
    atomic_store(&g_settingPointerStyle, style);
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &style);
    storeSetting(CFSTR("PointerStyle"), value);
    CFRelease(value);
    [g_ringView resetPointer];   // rebuilt with the new shape on the next open
}

- (void)highlightColorChanged:(NSSegmentedControl *)control {
    int color = (int)MIN(MAX(control.selectedSegment, HighlightSystem), HighlightWhite);
    atomic_store(&g_settingHighlightColor, color);
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &color);
    storeSetting(CFSTR("HighlightColor"), value);
    CFRelease(value);
    [g_ringView resetPointer];   // the arrow takes the new color on the next open
}

- (void)showLightChanged:(NSButton *)button {
    BOOL on = button.state == NSControlStateValueOn;
    atomic_store(&g_settingShowLight, on);
    storeSetting(CFSTR("ShowLight"), on ? kCFBooleanTrue : kCFBooleanFalse);
}

- (void)updateDimmingLabel {
    self.dimmingLabel.stringValue = [NSString stringWithFormat:@"Pozadina iza kartica: boja i jačina %d%%",
                                     atomic_load(&g_settingBackdropDimming)];
}

- (void)backdropDimmingChanged:(NSSlider *)slider {
    int dimming = (int)lround(slider.doubleValue);
    atomic_store(&g_settingBackdropDimming, dimming);
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &dimming);
    storeSetting(CFSTR("BackdropDimming"), value);
    CFRelease(value);
    [self updateDimmingLabel];
}

- (void)backdropColorChanged:(NSColorWell *)well {
    NSColor *color = [well.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!color) return;
    g_backdropColor = color;
    NSArray *components = @[@(color.redComponent), @(color.greenComponent), @(color.blueComponent)];
    storeSetting(CFSTR("BackdropColor"), (__bridge CFPropertyListRef)components);
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

- (void)updateZoomLabel {
    int zoom = atomic_load(&g_settingBackdropZoom);
    self.zoomLabel.stringValue = zoom > 0
        ? [NSString stringWithFormat:@"Uvećanje pozadine: %d%%", zoom]
        : @"Uvećanje pozadine: isključeno";
}

- (void)backdropZoomChanged:(NSSlider *)slider {
    int zoom = (int)lround(slider.doubleValue);
    atomic_store(&g_settingBackdropZoom, zoom);
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &zoom);
    storeSetting(CFSTR("BackdropZoom"), value);
    CFRelease(value);
    [self updateZoomLabel];
}

- (void)openDiagnosticLogs:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:diagnosticDirectory()]];
}

- (void)shortcutTriggerChanged:(NSSegmentedControl *)control {
    int mode=(int)MIN(MAX(control.selectedSegment, ShortcutTriggerNone), ShortcutTriggerBoth);
    atomic_store(&g_settingShortcutTrigger, mode);
    CFNumberRef value=CFNumberCreate(NULL, kCFNumberIntType, &mode);
    storeSetting(CFSTR("ShortcutTrigger"), value);
    CFRelease(value);
    if (atomic_load(&g_gestureActive)) applyShortcutSection();
}

- (void)shortcutOptionChanged:(NSButton *)button {
    BOOL persistent=button.tag>=32;
    unsigned bit=1u<<(persistent ? button.tag-32 : button.tag);
    unsigned mask=persistent ? atomic_load(&g_persistentShortcutMask) : atomic_load(&g_shortcutMask);
    mask=button.state==NSControlStateValueOn ? mask|bit : mask&~bit;
    if (persistent) atomic_store(&g_persistentShortcutMask,mask);
    else atomic_store(&g_shortcutMask,mask);
    int value=(int)mask;
    CFNumberRef number=CFNumberCreate(NULL,kCFNumberIntType,&value);
    storeSetting(persistent ? CFSTR("PersistentShortcuts") : CFSTR("CommandShortcuts"),number);
    CFRelease(number);
    scanWindowsNow();
}

- (void)hideIconChanged:(NSButton *)button {
    if (button.state != NSControlStateValueOn) {
        atomic_store(&g_settingHideMenuIcon, false);
        storeSetting(CFSTR("HideMenuBarIcon"), kCFBooleanFalse);
        [self showIcon];
        return;
    }
    atomic_store(&g_settingHideMenuIcon, true);
    storeSetting(CFSTR("HideMenuBarIcon"), kCFBooleanTrue);
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

static RingEntry *settingsEntryIfVisible(void) {
    NSWindow *window=g_settingsMenu.window;
    if (!window.isVisible || window.isMiniaturized) return nil;
    RingEntry *entry=[RingEntry new];
    entry.isSettings=YES;
    entry.application=NSRunningApplication.currentApplication;
    entry.windowTitle=@"Touchpad Switcher - Podešavanja";
    entry.windowID=(CGWindowID)window.windowNumber;
    entry.windowBounds=NSRectToCGRect(window.frame);
    entry.icon=NSApp.applicationIconImage;
    NSView *content=window.contentView;
    NSBitmapImageRep *bitmap=[content bitmapImageRepForCachingDisplayInRect:content.bounds];
    [content cacheDisplayInRect:content.bounds toBitmapImageRep:bitmap];
    entry.thumbnailData=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return entry;
}

static void raiseSettingsWindow(void) {
    if (g_settingsMenu.window.isVisible) {
        activateSelf();
        [g_settingsMenu.window makeKeyAndOrderFront:nil];
    }
}


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
        startDiagnosticLoggingAt(diagnosticDirectory(),4*1024*1024);
        diagnosticEvent(@"app_start",@{@"version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev",
            @"build":@(__DATE__ " " __TIME__), @"executable":NSBundle.mainBundle.executablePath ?: @"",
            @"replacedInstance":@(g_replacedRunningInstance)});
        for (int i = 1; i < argc; i++) {
            (void)argv[i];
        }
        [NSApplication sharedApplication];
        NSString *iconPath=[NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"];
        if (iconPath) NSApp.applicationIconImage=[[NSImage alloc] initWithContentsOfFile:iconPath];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        loadSettings();
        g_settingsMenu = [SettingsMenu new];
        NSApp.delegate = g_settingsMenu;
        [NSAppleEventManager.sharedAppleEventManager setEventHandler:g_settingsMenu
            andSelector:@selector(handleReopenEvent:withReplyEvent:)
            forEventClass:kCoreEventClass andEventID:kAEReopenApplication];
        [NSAppleEventManager.sharedAppleEventManager setEventHandler:g_settingsMenu
            andSelector:@selector(handleReopenEvent:withReplyEvent:)
            forEventClass:kCoreEventClass andEventID:kAEOpenApplication];
        if (!atomic_load(&g_settingHideMenuIcon)) [g_settingsMenu showIcon];
        RingMediaStart(g_mediaOptions);
        RingFaviconsSetLoadedHandler(^{
            if (g_ringView && atomic_load(&g_ringOverlayVisible)) [g_ringView setNeedsDisplay:YES];
        });
        signal(SIGINT, handleSignal);
        signal(SIGTERM, handleSignal);
        BOOL accessibilityTrusted = AXIsProcessTrusted();
        BOOL listenAccess = CGPreflightListenEventAccess();
        diagnosticEvent(@"permissions",@{@"accessibility":@(accessibilityTrusted),@"inputMonitoring":@(listenAccess),
            @"screenRecording":@(CGPreflightScreenCaptureAccess())});
        // Run the input filter on its own loop so a slow AppKit/AX scan cannot
        // let a scroll event slip through before the selector is drawn.
        if (startScrollEventTap()) {
            diagnosticEvent(@"input_filter",@{@"enabled":@YES});
            NSLog(@"[input] Dedicated session scroll filter active; Accessibility=%d; Input Monitoring=%d",
                  accessibilityTrusted, listenAccess);
            printf("Scroll and mouse input are suppressed while the selector is open.\n");
        } else {
            diagnosticEvent(@"input_filter",@{@"enabled":@NO});
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
        g_windowEntries = entriesWithPersistentShortcuts(entriesWorthShowing(g_windowEntries));
        atomic_store(&g_windowEntryCount, (int)g_windowEntries.count);
        if (g_thumbnailPreviewsEnabled) schedulePendingThumbnailCapture(g_windowEntries);
        if (g_thumbnailPreviewsEnabled) scheduleChromeBackgroundPrefetch(g_windowEntries);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ensureChromeAutomation(YES) && !atomic_load(&g_gestureActive)) {
                NSArray<RingEntry *> *entries = collectOpenWindows();
                populateThumbnailsFromCache(entries);
                entries = entriesWithPersistentShortcuts(entriesWorthShowing(entries));
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
        updateRecentWindowHistory();
        g_recentWindowTimer=[NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            if (!atomic_load(&g_gestureActive) && !atomic_load(&g_gestureEnding)) updateRecentWindowHistory();
        }];
        // Build the hidden panel at startup so the first three-finger gesture
        // does not pay for creating its window and layer tree.
        ensurePanel(NSScreen.mainScreen);
        // Prime ScreenCaptureKit before the first gesture; the first content
        // inventory is much slower than later requests on this Mac.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (!CGPreflightScreenCaptureAccess()) return;
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                completionHandler:^(SCShareableContent *content, NSError *error) {
                    (void)content;
                    (void)error;
                }];
        });
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
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                  (uint64_t)(0.5 * NSEC_PER_SEC),
                                  (uint64_t)(100 * NSEC_PER_MSEC));
        dispatch_source_set_event_handler(g_scanTimer, ^{ scanWindowsNow(); });
        startWindowChangeWatch();
        dispatch_resume(g_scanTimer);
        [NSApp run];
    }
    return 0;
}
