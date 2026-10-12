// Types, settings and helpers shared by touchpad_ring_test.m and the modules
// split out of it. Everything else stays private to its file.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <stdatomic.h>
#import "ring_media.h"
#import "ring_update.h"

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
// Mission Control desktop that owns this window. 0 means unknown.
@property(nonatomic) uint64_t spaceID;
@end

// Settings from the menu bar panel. Stored under one ID so the bare binary
// and the .app bundle share them; read from the scan, touch and main threads.
#define kSettingsID CFSTR("com.milev.touchpad-switcher")
typedef enum { CardTitlesAll = 0, CardTitlesFinderAndChrome = 1, CardTitlesNone = 2 } CardTitlesMode;
extern _Atomic(int) g_settingCardTitles;
extern RingMediaOptions g_mediaOptions;
extern _Atomic(bool) g_settingFinderTabsOneCard;
typedef enum { CardGroupingWindows = 0, CardGroupingApps = 1 } CardGrouping;
extern _Atomic(int) g_settingCardGrouping;
// Poseban meni prečica: nema ga, drži se Cmd, dodaje se četvrti prst, ili oba.
typedef enum {
    ShortcutTriggerNone = 0,
    ShortcutTriggerCommand = 1,
    ShortcutTriggerFourFingers = 2,
    ShortcutTriggerBoth = 3,
} ShortcutTrigger;
extern _Atomic(int) g_settingShortcutTrigger;
extern _Atomic(bool) g_settingHideMenuIcon;
extern _Atomic(bool) g_settingSoundEffects;
extern _Atomic(bool) g_settingPickZoom;
// Mouse activation by holding the button and releasing it on a card. Off: one
// click opens the ring and a second click (or a left click) picks the card.
extern _Atomic(bool) g_settingMouseHoldToSelect;
extern _Atomic(bool) g_settingShowSiteIcons;
extern _Atomic(bool) g_settingShowAppIcons;
// Window pictures on the cards. Off: cards show app icons and nothing is captured.
extern _Atomic(bool) g_settingThumbnails;
extern _Atomic(int) g_settingBlurRadius;
extern _Atomic(int) g_settingBackdropZoom;
extern _Atomic(bool) g_settingCurrentWindowInCenter;
// -1 disables mouse activation. Values 2...31 are Quartz mouse button numbers
// (middle is 2, the usual side buttons 3 and 4); kMouseActivationKeyBase plus a
// key code is a recorded key, such as F18 sent by Logi Options+.
// kMouseActivationSwipeBack/Forward are the side buttons with Logi Options+'s
// default Back/Forward assignment, which arrive as a synthetic swipe.
extern _Atomic(int) g_settingMouseButton;
typedef enum { PointerStyleArrow = 0, PointerStyleDot = 1, PointerStyleHidden = 2 } PointerStyle;
extern _Atomic(int) g_settingPointerStyle;
// Boja pokazivača i svetla iza kartica: akcentna boja
// color from System Settings > Appearance, like the rest of macOS, or white.
typedef enum { HighlightSystem = 0, HighlightWhite = 1 } HighlightColor;
extern _Atomic(int) g_settingHighlightColor;
extern _Atomic(bool) g_settingShowLight;
// The backdrop behind the cards: a color laid over the (blurred) screen.
extern _Atomic(int) g_settingBackdropDimming;
extern NSColor *g_backdropColor;

typedef NS_OPTIONS(NSUInteger, SystemGestureConflict) {
    SystemGestureDrag = 1 << 0,
    SystemGestureSpaces = 1 << 1,
    SystemGestureExpose = 1 << 2,
    SystemGesturePages = 1 << 3,
};

extern _Atomic(NSUInteger) g_systemGestureConflicts;

enum {
    kMouseActivationLegacyF18 = 100,
    kMouseActivationKeyBase = 1000,
    kMouseActivationSwipeBack = 2001,
    kMouseActivationSwipeForward = 2002,
};

static const CGKeyCode kEscapeKeyCode = 53;

static NSString *const kMouseButtonLearnedNotification = @"TouchpadSwitcherMouseButtonLearned";

// Defined in touchpad_ring_test.m.
extern _Atomic(bool) g_gestureActive;
extern _Atomic(bool) g_mouseButtonLearning;
extern _Atomic(unsigned) g_shortcutMask;
extern _Atomic(unsigned) g_persistentShortcutMask;
extern BOOL g_replacedRunningInstance;
extern NSSound *g_selectSound;
extern NSSound *g_activateSound;
void playRingSound(NSSound *sound);
void activateSelf(void);
void scanWindowsNow(void);
void refreshSystemGestureConflicts(void);
void persistMouseActivationSetting(int value);
NSString *diagnosticDirectory(void);
void applyShortcutSection(void);
// The ring view rebuilds its pointer with the current settings on next open.
void ringViewResetPointer(void);
