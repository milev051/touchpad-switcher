// Media control for Chrome tabs. See ring_media.h.
//
// How it works: while Chrome is in front, one short Apple Event a few times
// per second reports the tab on screen and whether something plays in it. The
// module remembers the tab that last played, because that is the one to pause,
// not simply the tab that was on screen before (you may have passed through a
// tab without video). When the tab on screen changes (ring, click on a tab,
// keyboard shortcut) or Chrome is left or entered, the rules below run
// JavaScript in the affected tabs. Media paused here is marked in the page
// with the time of the pause, so only that media is resumed later.
//
// Chrome runs the JavaScript only with View > Developer > Allow JavaScript
// from Apple Events turned on.

#import "ring_media.h"
#import <Cocoa/Cocoa.h>
#include <stdatomic.h>

static NSString *const kChromeBundleID = @"com.google.Chrome";
// The tab on screen is checked every 0.2 s (about 50 ms per check). Whether
// it plays is a slower JavaScript check, done every fifth time.
static const NSTimeInterval kPollInterval = 0.2;
static const int kPlayingCheckEvery = 5;
// A tab change seen this soon after the ring switched counts as the ring's.
static const NSTimeInterval kRingSwitchWindow = 1.5;

static dispatch_queue_t g_queue;            // all state below lives on this queue
static dispatch_source_t g_pollTimer;
static RingMediaOptions g_options;
static NSString *g_lastTab;                 // "windowID:tabID" of Chrome's front tab
static NSString *g_playingTab;              // last tab seen playing while on screen
static BOOL g_chromeInFront;
static NSTimeInterval g_ringSwitchUntil;
static _Atomic(double) g_ignoreTabChangesUntil;   // set from the switcher's queues
static _Atomic(bool) g_javaScriptBlocked = false;
static id g_activationObserver;

#pragma mark - JavaScript

static NSString *pauseJavaScript(void) {
    return @"document.querySelectorAll('video,audio').forEach(function(m){"
            "if(!m.paused&&!m.ended){m.pause();m.dataset.touchpadSwitcherPausedAt=String(Date.now());}})";
}

// Resume media marked by pauseJavaScript. With rewind, step back 2 s after
// half a minute away and 5 s after five minutes, so the thread is not lost.
// With playStarted, a tab with nothing marked plays its already started video.
static NSString *resumeJavaScript(BOOL rewind, BOOL playStarted) {
    return [NSString stringWithFormat:
        @"(function(rewind,playStarted){var resumed=false;"
         "document.querySelectorAll('video,audio').forEach(function(m){"
         "var at=Number(m.dataset.touchpadSwitcherPausedAt||0);if(!at)return;"
         "delete m.dataset.touchpadSwitcherPausedAt;resumed=true;"
         "if(rewind){var away=Date.now()-at;var back=away>300000?5:(away>30000?2:0);"
         "if(back)m.currentTime=Math.max(0,m.currentTime-back);}"
         "m.play();});"
         "if(!resumed&&playStarted){var v=Array.prototype.find.call(document.querySelectorAll('video'),"
         "function(v){return v.paused&&!v.ended&&v.currentTime>0;});if(v)v.play();}"
         "})(%@,%@)", rewind ? @"true" : @"false", playStarted ? @"true" : @"false"];
}

// For a tab opened only for its picture. Media that has played for less than
// five seconds started because the tab was opened, and is paused (marked like
// any pause here). For the next 15 s, media that starts while the tab is in
// the background is paused too; once the user comes to the tab, it plays.
static NSString *quietLoadedTabJavaScript(void) {
    return @"(function(){function mark(m){m.pause();m.dataset.touchpadSwitcherPausedAt=String(Date.now());}"
            "function played(m){var t=0;for(var i=0;i<m.played.length;i++)t+=m.played.end(i)-m.played.start(i);return t;}"
            "document.querySelectorAll('video,audio').forEach(function(m){if(!m.paused&&!m.ended&&played(m)<5)mark(m);});"
            "var until=Date.now()+15000;"
            "function stop(e){if(document.visibilityState!=='visible'&&Date.now()<until&&e.target.pause)mark(e.target);}"
            "document.addEventListener('play',stop,true);"
            "setTimeout(function(){document.removeEventListener('play',stop,true);},15000);})()";
}

// A tab "has a video" when a video there has already been started.
static NSString *hasStartedVideoJavaScript(void) {
    return @"Array.prototype.some.call(document.querySelectorAll('video'),"
            "function(v){return v.currentTime>0&&v.duration>0;})";
}

#pragma mark - Apple Events

static BOOL chromeAutomationAllowed(void) {
    static _Atomic(bool) granted = false;
    if (atomic_load(&granted)) return YES;
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithBundleIdentifier:kChromeBundleID];
    OSStatus status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false);
    if (status == noErr) atomic_store(&granted, true);
    return status == noErr;
}

static NSString *runCompiledScript(NSAppleScript *script) {
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = nil;
    // Same lock as the switcher's scripts, so Apple Events to Chrome never overlap.
    @synchronized ([NSAppleScript class]) {
        result = [script executeAndReturnError:&error];
    }
    return error ? nil : (result.stringValue ?: @"");
}

static NSString *runAppleScript(NSString *source) {
    return runCompiledScript([[NSAppleScript alloc] initWithSource:source]);
}

// "windowID:tabID" of the tab on screen in Chrome's front window. Only ids,
// no JavaScript, so it is quick enough to run several times a second.
static NSString *chromeFrontTabQuick(void) {
    if (!chromeAutomationAllowed()) return nil;
    static NSAppleScript *s_script;
    if (!s_script) {
        s_script = [[NSAppleScript alloc] initWithSource:
            @"tell application \"Google Chrome\"\n"
             "if (count of windows) is 0 then return \"\"\n"
             "return ((id of window 1) as text) & \":\" & ((id of active tab of window 1) as text)\n"
             "end tell"];
        [s_script compileAndReturnError:nil];
    }
    NSString *result = runCompiledScript(s_script);
    return result.length ? result : nil;
}

static NSString *isPlayingJavaScript(void) {
    return @"Array.prototype.some.call(document.querySelectorAll('video,audio'),"
            "function(m){return !m.paused&&!m.ended&&m.currentTime>0;})";
}

// "windowID:tabID" of the tab on screen in Chrome's front window, and whether
// media plays in it. Pages that refuse JavaScript report "not playing".
static NSString *chromeFrontTab(BOOL *playingOut) {
    if (playingOut) *playingOut = NO;
    if (!chromeAutomationAllowed()) return nil;
    // Runs several times a second, so it is compiled once.
    static NSAppleScript *s_frontTabScript;
    if (!s_frontTabScript) {
        s_frontTabScript = [[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:
        @"tell application \"Google Chrome\"\n"
         "if (count of windows) is 0 then return \"\"\n"
         "set frontTab to active tab of window 1\n"
         "set playing to \"false\"\n"
         "try\n"
         "set playing to (execute frontTab javascript \"%@\") as text\n"
         "end try\n"
         "return ((id of window 1) as text) & \":\" & ((id of frontTab) as text) & \"|\" & playing\n"
         "end tell", isPlayingJavaScript()]];
        [s_frontTabScript compileAndReturnError:nil];
    }
    NSString *result = runCompiledScript(s_frontTabScript);
    NSArray<NSString *> *parts = [result componentsSeparatedByString:@"|"];
    if (parts.count != 2 || !parts[0].length) return nil;
    if (playingOut) *playingOut = [parts[1] isEqualToString:@"true"];
    return parts[0];
}

// Runs JavaScript in one tab and returns its result as text, or nil.
static NSString *runInTab(NSString *tab, NSString *javaScript) {
    NSArray<NSString *> *ids = [tab componentsSeparatedByString:@":"];
    if (ids.count != 2 || !chromeAutomationAllowed()) return nil;
    NSString *result = runAppleScript([NSString stringWithFormat:
        @"tell application \"Google Chrome\"\n"
         "try\n"
         "set targetTab to (first tab of (first window whose id is \"%@\") whose id is \"%@\")\n"
         "with timeout of 2 seconds\n"
         "return \"ok:\" & ((execute targetTab javascript \"%@\") as text)\n"
         "end timeout\n"
         "on error errorMessage\n"
         "if errorMessage contains \"JavaScript\" then return \"blocked\"\n"
         "return \"failed\"\n"
         "end try\n"
         "end tell", ids[0], ids[1], javaScript]);
    if ([result isEqualToString:@"blocked"]) {
        if (!atomic_exchange(&g_javaScriptBlocked, true)) {
            NSLog(@"[media] Chrome needs View > Developer > Allow JavaScript from Apple Events");
        }
        return nil;
    }
    if (![result hasPrefix:@"ok:"]) return nil;
    atomic_store(&g_javaScriptBlocked, false);
    return [result substringFromIndex:3];
}

#pragma mark - Rules

static BOOL anyMediaRuleOn(void) {
    return g_options.pauseWhenLeaving || g_options.resumeWhenReturning;
}

static void resumeTab(NSString *tab, BOOL playStarted) {
    runInTab(tab, resumeJavaScript(g_options.rewindAfterLongPause, playStarted));
}

// Coming back to a tab: resume what was paused here and, if chosen, also the
// video the user stopped by hand.
static void returnToTab(NSString *tab) {
    resumeTab(tab, g_options.resumeManuallyPaused);
}

// Pause what is playing: the tab that last played and the tab just left
// (a video there may have started before this module saw it).
static void pausePlayingTabs(NSString *leftTab, NSString *exceptTab) {
    NSMutableOrderedSet<NSString *> *tabs = [NSMutableOrderedSet orderedSet];
    if (g_playingTab) [tabs addObject:g_playingTab];
    if (leftTab) [tabs addObject:leftTab];
    if (exceptTab) [tabs removeObject:exceptTab];
    for (NSString *tab in tabs) runInTab(tab, pauseJavaScript());
    if (!exceptTab || ![g_playingTab isEqualToString:exceptTab]) g_playingTab = nil;
}

// The tab on screen went from `fromTab` to `toTab` inside Chrome.
static void tabChanged(NSString *fromTab, NSString *toTab, BOOL byRing) {
    if (!byRing && !g_options.followAllTabChanges) return;
    if (g_options.onlyWhenNextTabHasVideo) {
        // Music or a talk keeps playing while you read another tab. Only a
        // tab with its own video takes over.
        if (![runInTab(toTab, hasStartedVideoJavaScript()) isEqualToString:@"true"]) return;
    }
    if (g_options.pauseWhenLeaving) pausePlayingTabs(fromTab, toTab);
    if (g_options.resumeWhenReturning) returnToTab(toTab);
}

static void chromeLeft(void) {
    // With "only when the next tab has a video", another app never counts as
    // a video, so the tab keeps playing.
    if (!g_options.pauseWhenLeaving || g_options.onlyWhenNextTabHasVideo) return;
    pausePlayingTabs(g_lastTab, nil);
}

static void chromeEntered(void) {
    // The ring already handled the tab it opened.
    if (NSProcessInfo.processInfo.systemUptime < g_ringSwitchUntil) return;
    NSString *tab = chromeFrontTabQuick();
    if (tab && g_options.resumeWhenReturning && !g_options.onlyWhenNextTabHasVideo) returnToTab(tab);
    if (tab) g_lastTab = tab;
}

static void pollFrontTab(void) {
    if (!g_chromeInFront || !anyMediaRuleOn()) return;
    // g_lastTab stays the tab from before, which the switcher puts back.
    if (NSProcessInfo.processInfo.systemUptime < atomic_load(&g_ignoreTabChangesUntil)) return;
    static int s_pollCount;
    BOOL checkPlaying = ++s_pollCount % kPlayingCheckEvery == 0;
    BOOL playing = NO;
    NSString *tab = checkPlaying ? chromeFrontTab(&playing) : chromeFrontTabQuick();
    if (!tab) return;
    if (g_lastTab && ![tab isEqualToString:g_lastTab]) {
        BOOL byRing = NSProcessInfo.processInfo.systemUptime < g_ringSwitchUntil;
        tabChanged(g_lastTab, tab, byRing);
    }
    g_lastTab = tab;
    if (playing) g_playingTab = tab;
}

#pragma mark - Public

void RingMediaStart(RingMediaOptions options) {
    g_queue = dispatch_queue_create("touchpad.ring.media", DISPATCH_QUEUE_SERIAL);
    g_options = options;
    g_chromeInFront = [NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier
                          isEqualToString:kChromeBundleID];

    g_activationObserver = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil
                usingBlock:^(NSNotification *notification) {
        NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
        // Our own menu bar panel does not count as leaving Chrome.
        if (!app || app.processIdentifier == getpid()) return;
        BOOL isChrome = [app.bundleIdentifier isEqualToString:kChromeBundleID];
        dispatch_async(g_queue, ^{
            BOOL wasChrome = g_chromeInFront;
            g_chromeInFront = isChrome;
            if (!anyMediaRuleOn()) return;
            if (wasChrome && !isChrome) chromeLeft();
        });
        if (isChrome) {
            // Cmd-Tab or a click: resume the tab on screen. A short wait lets a
            // ring selection report its tab first, so that one is not handled twice.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), g_queue, ^{
                if (g_chromeInFront && anyMediaRuleOn()) chromeEntered();
            });
        }
    }];

    g_pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_queue);
    dispatch_source_set_timer(g_pollTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollInterval * NSEC_PER_SEC)),
                              (uint64_t)(kPollInterval * NSEC_PER_SEC), (uint64_t)(50 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(g_pollTimer, ^{ @autoreleasepool { pollFrontTab(); } });
    dispatch_resume(g_pollTimer);
}

void RingMediaSetOptions(RingMediaOptions options) {
    if (!g_queue) return;
    dispatch_async(g_queue, ^{ g_options = options; });
}

void RingMediaTabSwitchedByRing(NSString *windowID, NSString *tabID) {
    if (!g_queue || !windowID.length || !tabID.length) return;
    NSString *tab = [NSString stringWithFormat:@"%@:%@", windowID, tabID];
    dispatch_async(g_queue, ^{
        g_ringSwitchUntil = NSProcessInfo.processInfo.systemUptime + kRingSwitchWindow;
        if (!anyMediaRuleOn()) return;
        // Act at once on the tab the ring opened instead of waiting for a poll.
        if (!g_lastTab || ![tab isEqualToString:g_lastTab]) {
            tabChanged(g_lastTab, tab, YES);
        } else if (g_options.resumeWhenReturning && !g_options.onlyWhenNextTabHasVideo) {
            returnToTab(tab);   // same tab, coming back from another app
        }
        g_lastTab = tab;
    });
}

void RingMediaIgnoreTabChanges(NSTimeInterval seconds) {
    atomic_store(&g_ignoreTabChangesUntil, seconds > 0 ? NSProcessInfo.processInfo.systemUptime + seconds : 0);
}

void RingMediaQuietLoadedTab(NSString *windowID, NSString *tabID) {
    if (!windowID.length || !tabID.length) return;
    runInTab([NSString stringWithFormat:@"%@:%@", windowID, tabID], quietLoadedTabJavaScript());
}

BOOL RingMediaJavaScriptBlocked(void) {
    return atomic_load(&g_javaScriptBlocked);
}
