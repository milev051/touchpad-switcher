// Video and audio in Chrome: pause the tab that leaves the screen, resume it
// on return. Kept apart from the switcher so media rules can grow without
// touching window selection. The switcher only reports that it switched a
// tab; everything else is watched here.

#import <Foundation/Foundation.h>

typedef struct {
    BOOL pauseWhenLeaving;         // pause the tab that is no longer on screen
    BOOL resumeWhenReturning;      // resume media this module paused
    BOOL resumeManuallyPaused;     // on return, also play a video the user paused
    BOOL followAllTabChanges;      // also tab clicks and shortcuts, not only the ring
    BOOL onlyWhenNextTabHasVideo;  // keep the old video unless the new tab has one
    BOOL rewindAfterLongPause;     // 2 s back after 30 s away, 5 s after 5 min
} RingMediaOptions;

// Call once from the main thread after the app has launched.
void RingMediaStart(RingMediaOptions options);
void RingMediaSetOptions(RingMediaOptions options);
// The ring just put this Chrome tab on screen (ids as Chrome reports them).
void RingMediaTabSwitchedByRing(NSString *windowID, NSString *tabID);
// The switcher briefly shows hidden tabs behind the open ring to take their
// pictures. Tab changes seen before `seconds` from now are not the user's and
// are ignored; 0 ends the pause.
void RingMediaIgnoreTabChanges(NSTimeInterval seconds);
// A tab the switcher just opened behind the ring to take its picture: media
// that started only now (autoplay) is paused, also if it starts in the next
// seconds while the tab is in the background. Media that was already playing
// is left alone. Needs JavaScript from Apple Events.
void RingMediaQuietLoadedTab(NSString *windowID, NSString *tabID);
// Chrome refused JavaScript from Apple Events (menu shows how to allow it).
BOOL RingMediaJavaScriptBlocked(void);
