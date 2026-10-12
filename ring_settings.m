// Settings: stored values and the settings window. See ring_settings.h.

#import "ring_settings.h"

#pragma mark - Settings storage

BOOL settingBool(CFStringRef key, BOOL fallback) {
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

void storeSetting(CFStringRef key, CFPropertyListRef value) {
    CFPreferencesSetAppValue(key, value, kSettingsID);
    CFPreferencesAppSynchronize(kSettingsID);
}

void loadSettings(void) {
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
    atomic_store(&g_settingPickZoom, settingBool(CFSTR("PickZoom"), YES));
    atomic_store(&g_settingMouseHoldToSelect, settingBool(CFSTR("MouseHoldToSelect"), YES));
    atomic_store(&g_settingShowSiteIcons, settingBool(CFSTR("ShowSiteIcons"), YES));
    atomic_store(&g_settingShowAppIcons, settingBool(CFSTR("ShowAppIcons"), YES));
    atomic_store(&g_settingThumbnails, settingBool(CFSTR("ShowThumbnails"), YES));
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
// Pure classifier shared by live preferences and regression checks. Missing
// Dock switches keep the macOS default enabled; an explicit Off is respected.
NSUInteger conflictsForTrackpadPreferences(NSDictionary *trackpad, NSDictionary *dock,
                                          NSDictionary *global) {
    NSUInteger conflicts = 0;
    if ([trackpad[@"TrackpadThreeFingerDrag"] boolValue]) conflicts |= SystemGestureDrag;
    NSNumber *horizontal = trackpad[@"TrackpadThreeFingerHorizSwipeGesture"] ?:
        global[@"com.apple.trackpad.threeFingerHorizSwipeGesture"];
    NSNumber *vertical = trackpad[@"TrackpadThreeFingerVertSwipeGesture"] ?:
        global[@"com.apple.trackpad.threeFingerVertSwipeGesture"];
    if (horizontal.integerValue == 2) conflicts |= SystemGestureSpaces;
    if (horizontal.integerValue == 1) conflicts |= SystemGesturePages;
    BOOL missionControl = !dock[@"showMissionControlGestureEnabled"] ||
        [dock[@"showMissionControlGestureEnabled"] boolValue];
    BOOL appExpose = !dock[@"showAppExposeGestureEnabled"] ||
        [dock[@"showAppExposeGestureEnabled"] boolValue];
    if (vertical.integerValue == 2 && (missionControl || appExpose)) conflicts |= SystemGestureExpose;
    return conflicts;
}

static NSDictionary *systemGesturePreferences(CFStringRef domain, NSArray<NSString *> *keys) {
    CFPreferencesAppSynchronize(domain);
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, domain));
        if ([value isKindOfClass:NSNumber.class]) values[key] = value;
    }
    return values;
}

NSUInteger currentSystemGestureConflicts(void) {
    NSArray *keys = @[@"TrackpadThreeFingerDrag", @"TrackpadThreeFingerHorizSwipeGesture",
                      @"TrackpadThreeFingerVertSwipeGesture"];
    NSDictionary *dock = systemGesturePreferences(CFSTR("com.apple.dock"),
        @[@"showMissionControlGestureEnabled", @"showAppExposeGestureEnabled"]);
    NSDictionary *global = systemGesturePreferences(kCFPreferencesAnyApplication,
        @[@"com.apple.trackpad.threeFingerHorizSwipeGesture", @"com.apple.trackpad.threeFingerVertSwipeGesture"]);
    NSDictionary *builtIn = systemGesturePreferences(CFSTR("com.apple.AppleMultitouchTrackpad"), keys);
    NSDictionary *external = systemGesturePreferences(CFSTR("com.apple.driver.AppleBluetoothMultitouch.trackpad"), keys);
    return conflictsForTrackpadPreferences(builtIn, dock, global) |
        conflictsForTrackpadPreferences(external, dock, global);
}

// Tests substitute inventories without changing the user's macOS preferences.
NSUInteger (*g_systemGestureConflictReader)(void) = currentSystemGestureConflicts;

BOOL threeFingerSystemGesturesOn(void) {
    return atomic_load(&g_systemGestureConflicts) != 0;
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

#pragma mark - Settings window

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

@interface SettingsMenu ()
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSButton *hideIconCheckbox;
@property(nonatomic, strong) SettingsWindow *window;
@property(nonatomic, strong) NSTextField *javaScriptHint;
@property(nonatomic, strong) NSTextField *blurLabel;
@property(nonatomic, strong) NSTextField *zoomLabel;
@property(nonatomic, strong) NSTextField *dimmingLabel;
@property(nonatomic, strong) NSTextField *gestureWarning;
@property(nonatomic, strong) NSButton *gestureSetupButton;
@property(nonatomic, strong) NSTextField *gestureConflictText;
@property(nonatomic, strong) NSButton *gestureTrackpadButton;
@property(nonatomic, strong) NSButton *gestureDragButton;
@property(nonatomic, strong) NSTextField *mouseActivationLabel;
@property(nonatomic, strong) NSTextField *mouseLearnStatus;
@property(nonatomic, strong) NSButton *updateButton;
@property(nonatomic, strong) NSTextField *updateStatus;
@property(nonatomic, strong) RingRelease *latestRelease;
@property(nonatomic) NSTimeInterval lastUpdateCheck;
@end

@implementation SettingsMenu
- (void)updateGestureConflictNotice {
    NSUInteger conflicts = atomic_load(&g_systemGestureConflicts);
    BOOL blocked = conflicts != 0;
    BOOL layoutChanged = self.gestureWarning && self.gestureWarning.hidden == blocked;
    self.gestureWarning.hidden = !blocked;
    self.gestureSetupButton.hidden = !blocked;
    if (layoutChanged && self.window.isVisible) [self fitWindow];
    if (!blocked) {
        [self.gestureConflictWindow orderOut:nil];
        return;
    }
    NSMutableArray *steps = [NSMutableArray array];
    if (conflicts & SystemGestureSpaces)
        [steps addObject:@"• Swipe between full-screen applications: isključi ili izaberi četiri prsta."];
    if (conflicts & SystemGestureExpose)
        [steps addObject:@"• Mission Control i App Exposé: isključi ili izaberi četiri prsta."];
    if (conflicts & SystemGesturePages)
        [steps addObject:@"• Swipe between pages: isključi ili izaberi dva prsta."];
    if (conflicts & SystemGestureDrag)
        [steps addObject:@"• Pointer Control > Trackpad Options: isključi Three Finger Drag ili izaberi drugi stil prevlačenja."];
    self.gestureConflictText.stringValue = [NSString stringWithFormat:
        @"macOS i Touchpad Switcher koriste iste pokrete, pa se pri izboru pomera ekran ili prozor.\n\n%@\n\n"
         "Meni ostaje zaključan dok se ovo ne sredi. Stanje se proverava automatski; restart nije potreban.",
        [steps componentsJoinedByString:@"\n\n"]];
    self.gestureTrackpadButton.hidden = !(conflicts & (SystemGestureSpaces | SystemGestureExpose | SystemGesturePages));
    self.gestureDragButton.hidden = !(conflicts & SystemGestureDrag);
    if (self.gestureConflictWindow) {
        NSSize size = self.gestureConflictWindow.contentView.fittingSize;
        [self.gestureConflictWindow setContentSize:size];
    }
}

- (void)presentGestureConflict:(id)sender {
    (void)sender;
    refreshSystemGestureConflicts();
    if (!threeFingerSystemGesturesOn()) return;
    if (!self.gestureConflictWindow) {
        self.gestureConflictWindow = [[SettingsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 320)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        self.gestureConflictWindow.title = @"Oslobodi gestove sa tri prsta";
        self.gestureConflictWindow.releasedWhenClosed = NO;
        self.gestureConflictWindow.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
        NSTextField *heading = [NSTextField labelWithString:@"Kružni meni je privremeno zaključan"];
        heading.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
        self.gestureConflictText = [NSTextField wrappingLabelWithString:@""];
        self.gestureConflictText.preferredMaxLayoutWidth = 480;
        self.gestureTrackpadButton = [NSButton buttonWithTitle:@"Otvori Trackpad podešavanja"
            target:self action:@selector(openSystemTrackpadSettings:)];
        self.gestureDragButton = [NSButton buttonWithTitle:@"Otvori podešavanja prevlačenja"
            target:self action:@selector(openSystemDragSettings:)];
        NSStackView *links = [NSStackView stackViewWithViews:@[self.gestureTrackpadButton, self.gestureDragButton]];
        links.orientation = NSUserInterfaceLayoutOrientationVertical;
        links.alignment = NSLayoutAttributeLeading;
        links.spacing = 8;
        NSButton *check = [NSButton buttonWithTitle:@"Proveri ponovo" target:self action:@selector(checkSystemGestures:)];
        NSButton *later = [NSButton buttonWithTitle:@"Kasnije" target:self action:@selector(dismissGestureConflict:)];
        NSStackView *controls = [NSStackView stackViewWithViews:@[check, later]];
        controls.spacing = 12;
        NSStackView *stack = [NSStackView stackViewWithViews:@[heading, self.gestureConflictText, links, controls]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 18;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *content = [NSView new];
        [content addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
            [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
            [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
            [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24],
            [self.gestureConflictText.widthAnchor constraintEqualToConstant:480],
        ]];
        self.gestureConflictWindow.contentView = content;
    }
    [self updateGestureConflictNotice];
    [self.gestureConflictWindow center];
    activateSelf();
    [self.gestureConflictWindow makeKeyAndOrderFront:nil];
}

- (void)openSystemTrackpadSettings:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.Trackpad-Settings.extension?MoreGestures"]];
}
- (void)openSystemDragSettings:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_TRACKPAD_OPTIONS"]];
}
- (void)checkSystemGestures:(id)sender {
    (void)sender;
    refreshSystemGestureConflicts();
    [self updateGestureConflictNotice];
}
- (void)dismissGestureConflict:(id)sender {
    (void)sender;
    [self.gestureConflictWindow orderOut:nil];
}

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
        @"Kružni meni je zaključan jer macOS koristi tri prsta. Isključi te gestove ili ih prebaci na četiri prsta."];
    self.gestureWarning.textColor = NSColor.systemOrangeColor;
    self.gestureSetupButton = [NSButton buttonWithTitle:@"Sredi gestove sa tri prsta" target:self
                                               action:@selector(presentGestureConflict:)];

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
    NSButton *thumbnails = [NSButton checkboxWithTitle:@"Snimci prozora na karticama"
                                                target:self action:@selector(thumbnailsChanged:)];
    thumbnails.state = atomic_load(&g_settingThumbnails) ? NSControlStateValueOn : NSControlStateValueOff;
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

    NSButton *pickZoom = [NSButton checkboxWithTitle:@"Izabrana kartica se uveća do prozora"
                                              target:self action:@selector(pickZoomChanged:)];
    pickZoom.state = atomic_load(&g_settingPickZoom) ? NSControlStateValueOn : NSControlStateValueOff;

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

    NSStackView *cardsColumn = [self settingsColumn:@[cardsTitle, grouping, currentCenter, titlesLabel, titles, thumbnails, siteIcons, appIcons,
                                                      finderTabs, lookTitle, pointerLabel, pointer, highlightLabel, highlight,
                                                      light, self.dimmingLabel, backdropRow,
                                                      self.blurLabel, blur, self.zoomLabel, zoom, pickZoom, sounds]];
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

    NSStackView *stack = [NSStackView stackViewWithViews:@[buttons, self.updateStatus, self.gestureWarning,
                                                        self.gestureSetupButton, columns]];
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
    refreshSystemGestureConflicts();
    self.gestureWarning.hidden = !threeFingerSystemGesturesOn();
    self.gestureSetupButton.hidden = self.gestureWarning.hidden;
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

// Off, the cards show app icons and no window is captured. On again, the
// next scan captures the open windows.
- (void)thumbnailsChanged:(NSButton *)button {
    BOOL on = button.state == NSControlStateValueOn;
    atomic_store(&g_settingThumbnails, on);
    storeSetting(CFSTR("ShowThumbnails"), on ? kCFBooleanTrue : kCFBooleanFalse);
    if (on) scanWindowsNow();
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
    ringViewResetPointer();   // rebuilt with the new shape on the next open
}

- (void)highlightColorChanged:(NSSegmentedControl *)control {
    int color = (int)MIN(MAX(control.selectedSegment, HighlightSystem), HighlightWhite);
    atomic_store(&g_settingHighlightColor, color);
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &color);
    storeSetting(CFSTR("HighlightColor"), value);
    CFRelease(value);
    ringViewResetPointer();   // the arrow takes the new color on the next open
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

- (void)pickZoomChanged:(NSButton *)button {
    BOOL on = button.state == NSControlStateValueOn;
    atomic_store(&g_settingPickZoom, on);
    storeSetting(CFSTR("PickZoom"), on ? kCFBooleanTrue : kCFBooleanFalse);
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

SettingsMenu *g_settingsMenu;

RingEntry *settingsEntryIfVisible(void) {
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

void raiseSettingsWindow(void) {
    if (g_settingsMenu.window.isVisible) {
        activateSelf();
        [g_settingsMenu.window makeKeyAndOrderFront:nil];
    }
}


