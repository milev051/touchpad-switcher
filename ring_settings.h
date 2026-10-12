#import "ring_shared.h"

// The settings window and menu bar icon (ring_settings.m).
@interface SettingsMenu : NSObject <NSWindowDelegate, NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *gestureConflictWindow;
- (void)presentGestureConflict:(id)sender;
- (void)updateGestureConflictNotice;
- (void)dismissGestureConflict:(id)sender;
- (void)showIcon;
- (void)handleReopenEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply;
@end
extern SettingsMenu *g_settingsMenu;

BOOL settingBool(CFStringRef key, BOOL fallback);
void storeSetting(CFStringRef key, CFPropertyListRef value);
void loadSettings(void);
BOOL threeFingerSystemGesturesOn(void);
extern NSUInteger (*g_systemGestureConflictReader)(void);
NSUInteger currentSystemGestureConflicts(void);
// Exposed for the layout preview's checks.
NSUInteger conflictsForTrackpadPreferences(NSDictionary *trackpad, NSDictionary *dock, NSDictionary *global);
RingEntry *settingsEntryIfVisible(void);
void raiseSettingsWindow(void);
