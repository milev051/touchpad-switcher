//
//  touchpad_switcher.m
//  Touchpad Switcher - Adaptivni prototip sa kompaktnim tasterima (slotWidth),
//  pozicioniranjem klastera (--align center|right|left|full), Dock redosledom
//  i blokiranjem kursora miša u gornjoj zoni (Y >= 0.90)
//
//  Autor: Gemini (AI Pair Programmer)
//  Datum: 2026-09-25
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#include <signal.h>
#include <os/lock.h>

// MARK: - MultitouchSupport Private Framework Definitions

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

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

typedef void* MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef device, MTTouch *touches, int numTouches, double timestamp, int frame);

MTDeviceRef MTDeviceCreateDefault(void);
CFMutableArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);
void MTDeviceStop(MTDeviceRef);
void MTUnregisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);

// MARK: - Global Configuration & State

typedef enum {
    AlignCenter,
    AlignRight,
    AlignLeft,
    AlignFull
} ClusterAlignment;

typedef struct {
    float topZoneThreshold; // Default 0.90 (gornjih 10%)
    double cooldownSeconds;  // Opcioni cooldown (podrazumevano bez vremenskog kašnjenja)
    float slotWidth;         // Sirina tastera (default 0.12 = 12% trackpada)
    ClusterAlignment alignment; // default: AlignCenter
    BOOL debugMode;
    BOOL invertY;
    BOOL staticMode;         // Ako korisnik eksplicitno zeli fiksne 3 zone
    NSString *staticLeft;
    NSString *staticMiddle;
    NSString *staticRight;
} SwitcherConfig;

static SwitcherConfig g_config;
static double g_lastActivationTime = 0.0;
static int g_lastActiveZone = -1;
static int32_t g_activeFingerID = -1;
static CFMutableArrayRef g_devices = NULL;
static const float kZoneHysteresis = 0.015f; // Prostorna tolerancija, bez vremenskog čekanja.

// Blokiranje kursora misa dok je prst u gornjoj zoni
static volatile BOOL g_isMouseLocked = NO;
static CGPoint g_savedCursorPos = {0, 0};
static CGPoint g_cursorReturnPos = {0, 0};
static CFMachPortRef g_eventTap = NULL;

// Dinamicka lista aplikacija i niti-bezbedno zakljucavanje
static NSMutableArray<NSRunningApplication *> *g_runningApps = nil;
static NSMutableArray *g_runningAppDockCenters = nil;
static NSDictionary<NSString *, NSValue *> *g_dockIconCentersByName = nil;
static os_unfair_lock g_appsLock = OS_UNFAIR_LOCK_INIT;

// Dock se otkriva kao kod ručnog prelaska mišem: pravim događajem pomeranja do
// donje ivice ekrana. Podešavanje automatskog skrivanja se ne menja, pa se Dock
// sam sakrije čim se kursor vrati.
static volatile BOOL g_dockRevealed = NO;
static volatile BOOL g_dockRevealWatching = NO;
static int g_dockTargetZone = -1;
static const CGFloat kDockEdgeInset = 1.0;

// MARK: - Cluster Layout Calculation

typedef struct {
    float xStart;
    float xEnd;
    float slotWidth;
    float totalWidth;
    NSUInteger count;
} ClusterLayout;

static ClusterLayout calculateClusterLayout(NSUInteger count) {
    ClusterLayout layout;
    layout.count = count;
    if (count == 0) {
        layout.xStart = 0.0f;
        layout.xEnd = 0.0f;
        layout.slotWidth = 0.0f;
        layout.totalWidth = 0.0f;
        return layout;
    }

    if (g_config.alignment == AlignFull) {
        layout.slotWidth = 1.0f / (float)count;
        layout.totalWidth = 1.0f;
        layout.xStart = 0.0f;
        layout.xEnd = 1.0f;
        return layout;
    }

    float totalW = (float)count * g_config.slotWidth;
    if (totalW >= 1.0f) {
        layout.slotWidth = 1.0f / (float)count;
        layout.totalWidth = 1.0f;
        layout.xStart = 0.0f;
        layout.xEnd = 1.0f;
        return layout;
    }

    layout.slotWidth = g_config.slotWidth;
    layout.totalWidth = totalW;

    switch (g_config.alignment) {
        case AlignLeft:
            layout.xStart = 0.0f;
            break;
        case AlignRight:
            layout.xStart = 1.0f - totalW;
            break;
        case AlignCenter:
        default:
            layout.xStart = (1.0f - totalW) / 2.0f;
            break;
    }
    layout.xEnd = layout.xStart + totalW;
    return layout;
}

static const char* alignmentString(ClusterAlignment a) {
    switch (a) {
        case AlignLeft:   return "LEFT (Gornji levi ugao)";
        case AlignRight:  return "RIGHT (Gornji desni ugao)";
        case AlignFull:   return "FULL (Preko cele širine)";
        case AlignCenter:
        default:          return "CENTER (Centrirano)";
    }
}

// MARK: - CGEventTap za blokiranje pomeranja kursora

static CGEventRef mouseTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_eventTap) CGEventTapEnable(g_eventTap, true);
        return event;
    }
    if (g_isMouseLocked) {
        if (type == kCGEventMouseMoved) {
            CGPoint eventPosition = CGEventGetLocation(event);
            BOOL isSwitcherWarp = fabs(eventPosition.x - g_savedCursorPos.x) < 1.0 &&
                                  fabs(eventPosition.y - g_savedCursorPos.y) < 1.0;
            return isSwitcherWarp ? event : NULL;
        }
        if (type == kCGEventLeftMouseDragged ||
            type == kCGEventRightMouseDragged ||
            type == kCGEventOtherMouseDragged) {
            return NULL; // Blokiramo dogadjaj pomeranja misa
        }
    }
    return event;
}

static void setupEventTap(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventRightMouseDragged) |
                       CGEventMaskBit(kCGEventOtherMouseDragged);

    g_eventTap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        mouseTapCallback,
        NULL
    );

    if (g_eventTap) {
        CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
        CGEventTapEnable(g_eventTap, true);
        CFRelease(runLoopSource);
    } else {
        printf("[UPOZORENJE] CGEventTap nije mogao da se inicijalizuje.\n");
        printf("             Kursor ce biti fiksiran iskljucivo preko CGWarpMouseCursorPosition.\n");
    }
}

// MARK: - Dock Redosled Aplikacija (AppleScript / AX)

static BOOL copyAXFrame(AXUIElementRef element, CGRect *frame) {
    AXValueRef positionValue = NULL;
    AXValueRef sizeValue = NULL;
    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL ok = AXUIElementCopyAttributeValue(element, kAXPositionAttribute, (CFTypeRef *)&positionValue) == kAXErrorSuccess &&
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute, (CFTypeRef *)&sizeValue) == kAXErrorSuccess &&
              AXValueGetValue(positionValue, kAXValueCGPointType, &position) &&
              AXValueGetValue(sizeValue, kAXValueCGSizeType, &size);
    if (positionValue) CFRelease(positionValue);
    if (sizeValue) CFRelease(sizeValue);
    if (ok && frame) *frame = CGRectMake(position.x, position.y, size.width, size.height);
    return ok;
}

// Vraća listu ikonica u Dock-u preko AX API-ja, bez AppleScript-a, jer se poziva
// i dok je prst na trackpadu.
static AXUIElementRef copyDockList(void) {
    NSRunningApplication *dock = [[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"] firstObject];
    if (!dock) return NULL;
    AXUIElementRef dockApp = AXUIElementCreateApplication(dock.processIdentifier);
    CFArrayRef children = NULL;
    AXUIElementRef list = NULL;
    if (AXUIElementCopyAttributeValue(dockApp, kAXChildrenAttribute, (CFTypeRef *)&children) == kAXErrorSuccess &&
        CFArrayGetCount(children) > 0) {
        list = (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(children, 0));
    }
    if (children) CFRelease(children);
    CFRelease(dockApp);
    return list;
}

static NSArray<NSString *> *getDockApplicationOrder(void) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSValue *> *centers = [NSMutableDictionary dictionary];
    AXUIElementRef list = copyDockList();
    CFArrayRef children = NULL;
    if (list && AXUIElementCopyAttributeValue(list, kAXChildrenAttribute, (CFTypeRef *)&children) == kAXErrorSuccess) {
        for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
            AXUIElementRef item = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
            CFTypeRef subrole = NULL;
            CFTypeRef title = NULL;
            CGRect frame;
            if (AXUIElementCopyAttributeValue(item, kAXSubroleAttribute, &subrole) == kAXErrorSuccess &&
                [(__bridge NSString *)subrole isEqualToString:@"AXApplicationDockItem"] &&
                AXUIElementCopyAttributeValue(item, kAXTitleAttribute, &title) == kAXErrorSuccess &&
                [(__bridge id)title isKindOfClass:[NSString class]] &&
                copyAXFrame(item, &frame)) {
                NSString *name = [(__bridge NSString *)title copy];
                [items addObject:name];
                CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
                centers[name] = [NSValue valueWithBytes:&center objCType:@encode(CGPoint)];
            }
            if (subrole) CFRelease(subrole);
            if (title) CFRelease(title);
        }
    }
    if (children) CFRelease(children);
    if (list) CFRelease(list);
    g_dockIconCentersByName = [centers copy];
    return items;
}

static CGFloat mainDisplayBottom(void) {
    return CGRectGetMaxY(CGDisplayBounds(CGMainDisplayID()));
}

// Za razliku od CGWarpMouseCursorPosition, pravi događaj pomeranja vidi i Dock,
// pa se otkriva, pokazuje hover nad ikonicom i ponovo sakriva.
static void postCursorMove(CGPoint point) {
    g_savedCursorPos = point;
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, kCGMouseButtonLeft);
    if (event) {
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
}

static void moveCursorToDockZone(int zone);
static void refreshDockCenters(void);

// Dock je otkriven kada lista stoji iznad donje ivice ekrana i više se ne pomera.
static void watchDockReveal(CFAbsoluteTime startTime, CGFloat previousY) {
    if (!g_isMouseLocked) {
        g_dockRevealWatching = NO;
        return;
    }

    CGFloat listY = CGFLOAT_MAX;
    CGRect listFrame;
    AXUIElementRef list = copyDockList();
    if (list && copyAXFrame(list, &listFrame)) listY = listFrame.origin.y;
    if (list) CFRelease(list);

    BOOL isOnScreen = listY < mainDisplayBottom() - 10.0;
    if (isOnScreen && fabs(listY - previousY) < 0.5) {
        getDockApplicationOrder();
        refreshDockCenters();
        g_dockRevealWatching = NO;
        g_dockRevealed = YES;
        moveCursorToDockZone(g_dockTargetZone);
        return;
    }

    if (CFAbsoluteTimeGetCurrent() - startTime > 2.0) {
        g_dockRevealWatching = NO;
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        watchDockReveal(startTime, listY);
    });
}

// Dok Dock nije otkriven, kursor stoji na donjoj ivici ispod ikonice, da bi ga
// Dock otkrio. Posle toga ide na sredinu ikonice.
static void moveCursorToDockZone(int zone) {
    if (!g_isMouseLocked || zone < 0) return;

    NSValue *centerValue = nil;
    os_unfair_lock_lock(&g_appsLock);
    if (zone < (int)g_runningAppDockCenters.count &&
        [g_runningAppDockCenters[zone] isKindOfClass:[NSValue class]]) {
        centerValue = g_runningAppDockCenters[zone];
    }
    os_unfair_lock_unlock(&g_appsLock);
    if (!centerValue) return;

    CGPoint center;
    [centerValue getValue:&center];
    if (g_dockRevealed) {
        postCursorMove(center);
        return;
    }

    postCursorMove(CGPointMake(center.x, mainDisplayBottom() - kDockEdgeInset));
    if (!g_dockRevealWatching) {
        g_dockRevealWatching = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            watchDockReveal(CFAbsoluteTimeGetCurrent(), CGFLOAT_MAX);
        });
    }
}

static NSInteger findDockIndex(NSRunningApplication *app, NSArray<NSString *> *dockItems) {
    NSString *name = app.localizedName;
    if (!name) return NSNotFound;

    for (NSInteger i = 0; i < dockItems.count; i++) {
        if ([dockItems[i] caseInsensitiveCompare:name] == NSOrderedSame) {
            return i;
        }
    }
    for (NSInteger i = 0; i < dockItems.count; i++) {
        if ([dockItems[i] localizedCaseInsensitiveContainsString:name] ||
            [name localizedCaseInsensitiveContainsString:dockItems[i]]) {
            return i;
        }
    }
    return NSNotFound;
}

// MARK: - Zone Layout Visualizer

static void printZoneLayout(void) {
    os_unfair_lock_lock(&g_appsLock);
    NSUInteger count = g_runningApps.count;
    NSArray<NSRunningApplication *> *currentList = [g_runningApps copy];
    os_unfair_lock_unlock(&g_appsLock);

    ClusterLayout layout = calculateClusterLayout(count);

    printf("\n╔════════════════════════════════════════════════════════════════════════════════════╗\n");
    printf("║ ADAPTIVNI KLASTER TASTERA (N = %-2lu, Širina tastera = %2.0f%%, Pozicija: %-15s) ║\n",
           (unsigned long)count, layout.slotWidth * 100.0f,
           (g_config.alignment == AlignCenter) ? "CENTER" :
           (g_config.alignment == AlignRight)  ? "RIGHT"  :
           (g_config.alignment == AlignLeft)   ? "LEFT"   : "FULL");
    printf("╠════════════════════════════════════════════════════════════════════════════════════╣\n");

    // ASCII traka trackpada
    char bar[81];
    memset(bar, ' ', 80);
    bar[80] = '\0';

    int bStart = (int)(layout.xStart * 80.0f);
    int bEnd = (int)(layout.xEnd * 80.0f);
    if (bStart < 0) bStart = 0;
    if (bEnd > 80) bEnd = 80;

    for (int i = 0; i < 80; i++) {
        if (i >= bStart && i < bEnd) {
            bar[i] = '#';
        } else {
            bar[i] = '.';
        }
    }
    printf("║ Trackpad: [%s] ║\n", bar);
    printf("║ Klaster:  Od X=%.2f do X=%.2f (Ukupna širina: %.0f%% trackpada)                       ║\n",
           layout.xStart, layout.xEnd, layout.totalWidth * 100.0f);
    printf("╠════════════════════════════════════════════════════════════════════════════════════╣\n");

    if (count == 0) {
        printf("║ (Trenutno nema pokrenutih regularnih aplikacija)                                   ║\n");
    } else {
        for (NSUInteger i = 0; i < count; i++) {
            NSRunningApplication *app = currentList[i];
            float xZStart = layout.xStart + (float)i * layout.slotWidth;
            float xZEnd = xZStart + layout.slotWidth;
            NSString *name = app.localizedName ?: @"Nepoznata";
            printf("║ Taster %2lu [%.2f - %.2f]  ->  %-50s ║\n",
                   (unsigned long)i, xZStart, xZEnd, [name UTF8String]);
        }
    }
    printf("╚════════════════════════════════════════════════════════════════════════════════════╝\n");
    printf("Prag gornje zone : Y >= %.2f (gornjih %.0f%% trackpada)\n",
           g_config.topZoneThreshold, (1.0f - g_config.topZoneThreshold) * 100.0f);
    printf("Pozicioniranje   : %s\n", alignmentString(g_config.alignment));
    printf("Kursor miša je zaključan dok je prst u gornjoj zoni.\n");
    printf("Spustite ili prevucite prst preko označenog klastera za prebacivanje.\n\n");
    fflush(stdout);
}

// MARK: - Dynamic Application Discovery (Dock Order)

static void refreshRunningApplications(void) {
    if (g_config.staticMode) {
        return;
    }

    NSArray<NSString *> *dockItems = getDockApplicationOrder();

    NSMutableArray<NSRunningApplication *> *regularApps = [NSMutableArray array];
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.activationPolicy == NSApplicationActivationPolicyRegular && !app.isTerminated) {
            [regularApps addObject:app];
        }
    }

    [regularApps sortUsingComparator:^NSComparisonResult(NSRunningApplication *a, NSRunningApplication *b) {
        NSInteger indexA = findDockIndex(a, dockItems);
        NSInteger indexB = findDockIndex(b, dockItems);

        if (indexA != NSNotFound && indexB != NSNotFound) {
            if (indexA < indexB) return NSOrderedAscending;
            if (indexA > indexB) return NSOrderedDescending;
            return NSOrderedSame;
        }
        if (indexA != NSNotFound) return NSOrderedAscending;
        if (indexB != NSNotFound) return NSOrderedDescending;
        return [a.localizedName caseInsensitiveCompare:b.localizedName];
    }];

    os_unfair_lock_lock(&g_appsLock);
    g_runningApps = regularApps;
    os_unfair_lock_unlock(&g_appsLock);

    refreshDockCenters();
    printZoneLayout();
}

// Dock pomera ikonice kad se otkrije, pa se sredine ponovo mapuju na aplikacije.
static void refreshDockCenters(void) {
    NSArray<NSString *> *dockItems = g_dockIconCentersByName.allKeys;
    os_unfair_lock_lock(&g_appsLock);
    NSArray<NSRunningApplication *> *apps = [g_runningApps copy];
    os_unfair_lock_unlock(&g_appsLock);

    NSMutableArray *appDockCenters = [NSMutableArray arrayWithCapacity:apps.count];
    for (NSRunningApplication *app in apps) {
        NSInteger index = findDockIndex(app, dockItems);
        NSValue *center = index != NSNotFound ? g_dockIconCentersByName[dockItems[index]] : nil;
        [appDockCenters addObject:center ?: [NSNull null]];
    }

    os_unfair_lock_lock(&g_appsLock);
    if (g_runningApps.count == appDockCenters.count) {
        g_runningAppDockCenters = appDockCenters;
    }
    os_unfair_lock_unlock(&g_appsLock);
}

static void setupWorkspaceNotifications(void) {
    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];

    [center addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
        if (app.activationPolicy == NSApplicationActivationPolicyRegular) {
            printf("\n🔔 [APLIKACIJA OTVORENA] %s -> Ažuriram tastere prema Dock-u...\n",
                   [app.localizedName UTF8String] ?: "Aplikacija");
            refreshRunningApplications();
        }
    }];

    [center addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
        if (app.activationPolicy == NSApplicationActivationPolicyRegular) {
            printf("\n🔔 [APLIKACIJA ZATVORENA] %s -> Ažuriram tastere prema Dock-u...\n",
                   [app.localizedName UTF8String] ?: "Aplikacija");
            refreshRunningApplications();
        }
    }];
}

// MARK: - Application Activation

static BOOL focusApplication(NSRunningApplication *app) {
    if (!app || app.isTerminated) {
        return NO;
    }
    return [app activateWithOptions:NSApplicationActivateAllWindows];
}

static BOOL focusApplicationByName(NSString *appName) {
    if (!appName || [appName length] == 0) return NO;

    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    for (NSRunningApplication *app in [workspace runningApplications]) {
        if ([app.localizedName caseInsensitiveCompare:appName] == NSOrderedSame ||
            [app.bundleIdentifier caseInsensitiveCompare:appName] == NSOrderedSame) {
            return [app activateWithOptions:NSApplicationActivateAllWindows];
        }
    }

    NSString *scriptSource = [NSString stringWithFormat:@"tell application \"%@\" to activate", appName];
    NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorDict = nil;
    [appleScript executeAndReturnError:&errorDict];
    return (errorDict == nil);
}

// MARK: - Multitouch Frame Processing & Mouse Locking

static int multitouchCallback(MTDeviceRef device, MTTouch *touches, int numTouches, double timestamp, int frame) {
    double currentTime = CFAbsoluteTimeGetCurrent();

    BOOL anyFingerInTopZone = NO;
    MTTouch *topTouch = NULL;

    for (int i = 0; i < numTouches; i++) {
        MTTouch *t = &touches[i];

        if (t->state != MTTouchStateTouching && t->state != MTTouchStateMakeTouch) {
            if (t->fingerID == g_activeFingerID) {
                g_activeFingerID = -1;
                g_lastActiveZone = -1;
            }
            continue;
        }

        float y = t->normalizedVector.position.y;
        if (g_config.invertY) {
            y = 1.0f - y;
        }

        if (y >= g_config.topZoneThreshold) {
            anyFingerInTopZone = YES;
            if (!topTouch) {
                topTouch = t;
            }
        }
    }

    // 2. Blokiranje kursora miša u gornjoj zoni
    if (anyFingerInTopZone) {
        if (!g_isMouseLocked) {
            CGEventRef ev = CGEventCreate(NULL);
            if (ev) {
                g_cursorReturnPos = CGEventGetLocation(ev);
                g_savedCursorPos = g_cursorReturnPos;
                CFRelease(ev);
            }
            g_dockRevealed = NO;
            g_dockTargetZone = -1;
            g_isMouseLocked = YES;
        }
        CGWarpMouseCursorPosition(g_savedCursorPos);
    } else {
        if (g_isMouseLocked) {
            g_isMouseLocked = NO;
            g_dockRevealed = NO;
            g_dockTargetZone = -1;
            // Pravi događaj, da Dock vidi da je kursor otišao i sam se sakrije.
            postCursorMove(g_cursorReturnPos);
        }
    }

    // 3. Obrada dodira unutar klastera tastera
    if (topTouch) {
        float x = topTouch->normalizedVector.position.x;
        float y = topTouch->normalizedVector.position.y;
        if (g_config.invertY) {
            y = 1.0f - y;
        }

        if (g_config.debugMode) {
            printf("[DEBUG] Prst #%d | X=%.3f | Y=%.3f | MouseLocked=%d\n",
                   topTouch->fingerID, x, y, g_isMouseLocked);
            fflush(stdout);
        }

        int currentZone = -1;
        NSString *targetAppName = nil;
        NSRunningApplication *targetApp = nil;
        NSValue *targetDockCenter = nil;

        os_unfair_lock_lock(&g_appsLock);
        NSUInteger appCount = g_runningApps.count;
        ClusterLayout layout = calculateClusterLayout(appCount);

        if (appCount > 0 && x >= layout.xStart && x < layout.xEnd && layout.slotWidth > 0.0f) {
            int zoneIndex = (int)((x - layout.xStart) / layout.slotWidth);
            if (zoneIndex >= (int)appCount) zoneIndex = (int)appCount - 1;
            if (zoneIndex < 0) zoneIndex = 0;

            currentZone = zoneIndex;
            targetApp = g_runningApps[zoneIndex];
            targetAppName = targetApp.localizedName;
            if (zoneIndex < (int)g_runningAppDockCenters.count) {
                id centerValue = g_runningAppDockCenters[zoneIndex];
                if ([centerValue isKindOfClass:[NSValue class]]) {
                    targetDockCenter = centerValue;
                }
            }
        }
        os_unfair_lock_unlock(&g_appsLock);

        if (currentZone != -1) {
            BOOL zoneChanged = (currentZone != g_lastActiveZone);
            BOOL cooldownPassed = (currentTime - g_lastActivationTime >= g_config.cooldownSeconds);
            BOOL crossedBoundary = YES;
            if (zoneChanged && g_lastActiveZone >= 0) {
                float boundary = layout.xStart + (float)(currentZone > g_lastActiveZone
                    ? g_lastActiveZone + 1 : g_lastActiveZone) * layout.slotWidth;
                crossedBoundary = currentZone > g_lastActiveZone
                    ? x >= boundary + kZoneHysteresis
                    : x < boundary - kZoneHysteresis;
            }

            if (zoneChanged && cooldownPassed && crossedBoundary) {
                g_lastActiveZone = currentZone;
                g_activeFingerID = topTouch->fingerID;
                g_lastActivationTime = currentTime;

                if (targetDockCenter) {
                    g_dockTargetZone = currentZone;
                    moveCursorToDockZone(currentZone);
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    if (targetApp) {
                        focusApplication(targetApp);
                    } else if (targetAppName) {
                        focusApplicationByName(targetAppName);
                    }
                });

                printf("\n⚡ [DETEKTOVAN TASTER U KLASTERU]\n");
                printf("   Taster     : Taster %d (X=%.3f, Y=%.3f)\n", currentZone, x, y);
                printf("   Aplikacija : Fokusiram -> [%s] (Kursor zaključan)\n",
                       [targetAppName UTF8String] ?: "(Nepoznato)");
                fflush(stdout);
            }
        } else {
            g_lastActiveZone = -1;
        }
    } else {
        if (g_activeFingerID != -1) {
            g_activeFingerID = -1;
            g_lastActiveZone = -1;
        }
    }

    return 0;
}

// MARK: - Utility: List Apps in Dock Order

static void listRunningApplications(void) {
    NSArray<NSString *> *dockItems = getDockApplicationOrder();

    NSMutableArray<NSRunningApplication *> *regularApps = [NSMutableArray array];
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.activationPolicy == NSApplicationActivationPolicyRegular) {
            [regularApps addObject:app];
        }
    }

    [regularApps sortUsingComparator:^NSComparisonResult(NSRunningApplication *a, NSRunningApplication *b) {
        NSInteger indexA = findDockIndex(a, dockItems);
        NSInteger indexB = findDockIndex(b, dockItems);

        if (indexA != NSNotFound && indexB != NSNotFound) {
            if (indexA < indexB) return NSOrderedAscending;
            if (indexA > indexB) return NSOrderedDescending;
            return NSOrderedSame;
        }
        if (indexA != NSNotFound) return NSOrderedAscending;
        if (indexB != NSNotFound) return NSOrderedDescending;
        return [a.localizedName caseInsensitiveCompare:b.localizedName];
    }];

    ClusterLayout layout = calculateClusterLayout(regularApps.count);

    printf("\n=== TRENUTNO POKRENUTE REGULARNE GUI APLIKACIJE (DOCK REDOSLED) ===\n");
    printf("Konfiguracija klastera: Pozicija=%s, Širina pojedinačnog tastera=%.0f%%\n",
           alignmentString(g_config.alignment), layout.slotWidth * 100.0f);
    printf("%-9s %-15s %-30s %-40s\n", "TASTER", "RASPON X", "NAZIV APLIKACIJE", "BUNDLE IDENTIFIER");
    printf("--------------------------------------------------------------------------------------------\n");

    for (NSUInteger i = 0; i < regularApps.count; i++) {
        NSRunningApplication *app = regularApps[i];
        float xZStart = layout.xStart + (float)i * layout.slotWidth;
        float xZEnd = xZStart + layout.slotWidth;
        printf("Taster %-2lu [%.2f - %.2f]   %-30s %-40s\n",
               (unsigned long)i, xZStart, xZEnd,
               [app.localizedName UTF8String] ?: "(Nepoznato)",
               [app.bundleIdentifier UTF8String] ?: "-");
    }
    printf("--------------------------------------------------------------------------------------------\n\n");
}

// MARK: - Signal Handling

static void handleSignal(int sig) {
    printf("\nZaustavljam Touchpad Switcher...\n");
    g_isMouseLocked = NO;
    if (g_eventTap) {
        CGEventTapEnable(g_eventTap, false);
    }
    if (g_devices) {
        CFIndex count = CFArrayGetCount(g_devices);
        for (CFIndex i = 0; i < count; i++) {
            MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(g_devices, i);
            MTDeviceStop(dev);
            MTUnregisterContactFrameCallback(dev, multitouchCallback);
        }
    }
    exit(0);
}

// MARK: - Print Help

static void printHelp(const char *progName) {
    printf("Korišćenje: %s [opcije]\n\n", progName);
    printf("Opcije za kompaktne tastere i pozicioniranje:\n");
    printf("  --slot-width <0.05-0.30> Širina pojedinačnog tastera (podrazumevano: 0.12 = 12%% trackpada)\n");
    printf("  --align <pozicija>       Pozicija klastera tastera (podrazumevano: center)\n");
    printf("                           Dozvoljene vrednosti: center, right, left, full\n");
    printf("                             center: Centriran na sredini gornje ivice: xStart = (1 - W)/2\n");
    printf("                             right : U gornjem desnom uglu: xStart = 1 - W\n");
    printf("                             left  : U gornjem levom uglu: xStart = 0.0\n");
    printf("                             full  : Preko cele širine (slotWidth = 1.0 / N)\n\n");
    printf("Ostale opcije:\n");
    printf("  --threshold <0.0-1.0>    Prag gornje zone (podrazumevano: 0.90 za gornjih 10%%)\n");
    printf("  --cooldown <sekunde>     Opcioni minimalni razmak izmedju aktivacija (podrazumevano: 0s)\n");
    printf("  --invert-y               Invertuj Y osu ako trackpad koristi obrnuti sistem\n");
    printf("  --debug                  Prikaz svih sirovih koordinata u realnom vremenu\n");
    printf("  --list-apps              Izlistaj trenutno pokrenute GUI aplikacije i raspone tastera\n");
    printf("  --help, -h               Prikaz ovog uputstva\n\n");
}

// MARK: - Main Entry Point

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        g_config.topZoneThreshold = 0.90f; // Gornjih 10%
        g_config.cooldownSeconds = 0.0;
        g_config.slotWidth = 0.12f;        // 12% sirine trackpada po tasteru
        g_config.alignment = AlignCenter;  // Centrirano podrazumevano
        g_config.debugMode = NO;
        g_config.invertY = NO;
        g_config.staticMode = NO;
        g_config.staticLeft = @"Finder";
        g_config.staticMiddle = @"Terminal";
        g_config.staticRight = @"Google Chrome";

        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--slot-width"] && i + 1 < argc) {
                float sw = atof(argv[++i]);
                if (sw < 0.03f) sw = 0.03f;
                if (sw > 0.50f) sw = 0.50f;
                g_config.slotWidth = sw;
            } else if ([arg isEqualToString:@"--align"] && i + 1 < argc) {
                NSString *al = [[NSString stringWithUTF8String:argv[++i]] lowercaseString];
                if ([al isEqualToString:@"center"]) {
                    g_config.alignment = AlignCenter;
                } else if ([al isEqualToString:@"right"]) {
                    g_config.alignment = AlignRight;
                } else if ([al isEqualToString:@"left"]) {
                    g_config.alignment = AlignLeft;
                } else if ([al isEqualToString:@"full"]) {
                    g_config.alignment = AlignFull;
                } else {
                    fprintf(stderr, "[UPOZORENJE] Nepoznato poravnanje '%s', koristim 'center'.\n", [al UTF8String]);
                    g_config.alignment = AlignCenter;
                }
            } else if ([arg isEqualToString:@"--threshold"] && i + 1 < argc) {
                g_config.topZoneThreshold = atof(argv[++i]);
            } else if ([arg isEqualToString:@"--cooldown"] && i + 1 < argc) {
                g_config.cooldownSeconds = atof(argv[++i]);
            } else if ([arg isEqualToString:@"--debug"]) {
                g_config.debugMode = YES;
            } else if ([arg isEqualToString:@"--invert-y"]) {
                g_config.invertY = YES;
            } else if ([arg isEqualToString:@"--list-apps"]) {
                listRunningApplications();
                return 0;
            } else if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-h"]) {
                printHelp(argv[0]);
                return 0;
            }
        }

        signal(SIGINT, handleSignal);
        signal(SIGTERM, handleSignal);

        printf("======================================================================\n");
        printf("    TOUCHPAD SWITCHER - KOMPAKTNI TASTERI & POZICIONIRANJE (GEMINI)   \n");
        printf("======================================================================\n");

        refreshRunningApplications();
        setupWorkspaceNotifications();
        setupEventTap();

        g_devices = MTDeviceCreateList();
        if (!g_devices) {
            fprintf(stderr, "[GREŠKA] Nije moguće učitati Multitouch uređaje.\n");
            return 1;
        }

        CFIndex deviceCount = CFArrayGetCount(g_devices);
        if (deviceCount == 0) {
            fprintf(stderr, "[GREŠKA] Nijedan trackpad uređaj nije pronađen!\n");
            return 1;
        }

        for (CFIndex i = 0; i < deviceCount; i++) {
            MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(g_devices, i);
            MTRegisterContactFrameCallback(dev, multitouchCallback);
            MTDeviceStart(dev, 0);
        }

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
