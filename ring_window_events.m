#import "ring_window_events.h"
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

static void (^g_handler)(RingWindowChange);
static NSMutableDictionary<NSNumber *, id> *g_observers;
static RingWindowChange g_pending;
static BOOL g_flushScheduled;
static id g_workspaceTokens[6];

// Resizing sends many notifications a second; they are merged into one call.
static const NSTimeInterval kCoalesceDelay = 0.12;

static void reportChange(RingWindowChange change) {
    g_pending |= change;
    if (g_flushScheduled) return;
    g_flushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCoalesceDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        RingWindowChange changes = g_pending;
        g_pending = 0;
        g_flushScheduled = NO;
        if (changes && g_handler) g_handler(changes);
    });
}

static RingWindowChange changeForNotification(CFStringRef name) {
    if (CFEqual(name, kAXWindowResizedNotification) || CFEqual(name, kAXWindowMovedNotification))
        return RingWindowChangeFrame;
    if (CFEqual(name, kAXFocusedWindowChangedNotification) || CFEqual(name, kAXMainWindowChangedNotification))
        return RingWindowChangeFocus | RingWindowChangeStructure;
    return RingWindowChangeStructure;
}

static void observerCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef name, void *context) {
    (void)observer; (void)context;
    // A new window gets its own resize, move and close notifications.
    if (CFEqual(name, kAXWindowCreatedNotification)) {
        CFStringRef perWindow[] = {kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                                   kAXWindowResizedNotification, kAXWindowMovedNotification,
                                   kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification};
        for (size_t i = 0; i < sizeof(perWindow) / sizeof(perWindow[0]); i++)
            AXObserverAddNotification(observer, element, perWindow[i], NULL);
    }
    reportChange(changeForNotification(name));
}

static void watchApplication(NSRunningApplication *app) {
    if (app.activationPolicy != NSApplicationActivationPolicyRegular || app.processIdentifier == getpid()) return;
    pid_t pid = app.processIdentifier;
    if (pid <= 0 || g_observers[@(pid)]) return;
    AXObserverRef observer = NULL;
    if (AXObserverCreate(pid, observerCallback, &observer) != kAXErrorSuccess || !observer) return;
    AXUIElementRef appElement = AXUIElementCreateApplication(pid);
    // Notifications sent to the application element cover all its windows.
    CFStringRef appWide[] = {kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
                             kAXTitleChangedNotification, kAXFocusedWindowChangedNotification,
                             kAXMainWindowChangedNotification, kAXWindowResizedNotification,
                             kAXWindowMovedNotification, kAXWindowMiniaturizedNotification,
                             kAXWindowDeminiaturizedNotification, kAXApplicationHiddenNotification,
                             kAXApplicationShownNotification};
    for (size_t i = 0; i < sizeof(appWide) / sizeof(appWide[0]); i++)
        AXObserverAddNotification(observer, appElement, appWide[i], NULL);
    // Some apps only report resizes on the window itself.
    CFArrayRef windows = NULL;
    if (AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, (CFTypeRef *)&windows) == kAXErrorSuccess && windows) {
        for (CFIndex i = 0; i < CFArrayGetCount(windows); i++)
            observerCallback(observer, (AXUIElementRef)CFArrayGetValueAtIndex(windows, i),
                             kAXWindowCreatedNotification, NULL);
        CFRelease(windows);
    }
    CFRelease(appElement);
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopDefaultMode);
    g_observers[@(pid)] = CFBridgingRelease(observer);
}

static void forgetApplication(NSRunningApplication *app) {
    id observer = g_observers[@(app.processIdentifier)];
    if (!observer) return;
    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource((__bridge AXObserverRef)observer),
                          kCFRunLoopDefaultMode);
    [g_observers removeObjectForKey:@(app.processIdentifier)];
}

void RingWindowEventsStart(void (^handler)(RingWindowChange changes)) {
    g_handler = [handler copy];
    if (g_observers) return;
    g_observers = [NSMutableDictionary dictionary];
    if (AXIsProcessTrusted()) {
        for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) watchApplication(app);
    }
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    NSOperationQueue *main = NSOperationQueue.mainQueue;
    g_workspaceTokens[0] = [center addObserverForName:NSWorkspaceDidLaunchApplicationNotification object:nil
                                                queue:main usingBlock:^(NSNotification *note) {
        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
        // A just launched app may not answer Accessibility for a moment.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (AXIsProcessTrusted() && !app.isTerminated) watchApplication(app);
            reportChange(RingWindowChangeStructure);
        });
    }];
    g_workspaceTokens[1] = [center addObserverForName:NSWorkspaceDidTerminateApplicationNotification object:nil
                                                queue:main usingBlock:^(NSNotification *note) {
        forgetApplication(note.userInfo[NSWorkspaceApplicationKey]);
        reportChange(RingWindowChangeStructure);
    }];
    g_workspaceTokens[2] = [center addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil
                                                queue:main usingBlock:^(NSNotification *note) {
        // An app started before Accessibility was granted is picked up here.
        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
        if (AXIsProcessTrusted()) watchApplication(app);
        reportChange(RingWindowChangeFocus);
    }];
    NSString *structureNames[] = {NSWorkspaceActiveSpaceDidChangeNotification,
                                  NSWorkspaceDidHideApplicationNotification,
                                  NSWorkspaceDidUnhideApplicationNotification};
    for (int i = 0; i < 3; i++) {
        g_workspaceTokens[3 + i] = [center addObserverForName:structureNames[i] object:nil queue:main
                                                   usingBlock:^(NSNotification *note) {
            (void)note;
            reportChange(RingWindowChangeStructure | RingWindowChangeFocus);
        }];
    }
}
