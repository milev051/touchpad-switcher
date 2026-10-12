#import <Foundation/Foundation.h>

// What changed, so the app can do only the work that change needs.
typedef NS_OPTIONS(NSUInteger, RingWindowChange) {
    RingWindowChangeFocus = 1 << 0,     // another app or window came forward
    RingWindowChangeStructure = 1 << 1, // a window opened, closed, hid or got a new title
    RingWindowChangeFrame = 1 << 2,     // a window was resized or moved
};

// Watches running apps through Accessibility and NSWorkspace and calls the
// handler on the main queue, at most once per short interval, with every kind
// of change seen in it. Needs Accessibility access; without it nothing is
// reported and the app's slow fallback timers do the work.
void RingWindowEventsStart(void (^handler)(RingWindowChange changes));
