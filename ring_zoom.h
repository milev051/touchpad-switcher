// Pick transition: the picked card's picture grows from its place in the menu
// to the window's real frame, then fades out once the window is in front.
// Also keeps the sharp picture used for it. Main thread only, unless noted.

#import <Cocoa/Cocoa.h>

// Current frame of a window on this desktop, in Cocoa screen coordinates.
// Zero for a minimized, hidden or unknown window.
NSRect RingZoomVisibleWindowFrame(CGWindowID windowID);

// YES when the window is already the foremost ordinary window on its display.
BOOL RingZoomWindowIsFrontmostOnDisplay(CGWindowID windowID);

// After activation, move the cursor to the picked window only when it is on a
// different physical display. The cursor stays put if the user moved it.
void RingZoomFollowWindowOnOtherDisplay(CGWindowID windowID, CGPoint gestureStart);

// Starts the zoom from `from` to `to` (screen coordinates) with the image,
// which the zoom retains. The picture fades once the window is the frontmost
// one and, when given, `contentShown` returns YES; it is asked on a
// background queue, about every 20 ms. Returns NO when there is nothing to
// zoom.
BOOL RingZoomStart(CGImageRef image, NSRect from, NSRect to, CGWindowID windowID,
                   BOOL (^contentShown)(void));

// Whether the zoom should play: on in the settings and macOS Reduce Motion off.
BOOL RingZoomAllowed(BOOL settingOn);

// Decoded copies, so the first frame of the zoom does not wait for a JPEG.
// The caller releases them. Safe on any thread.
CGImageRef RingZoomCopyDecodedImage(CGImageRef source);
CGImageRef RingZoomCopyDecodedImageFromData(NSData *data);

// A larger copy of a thumbnail, kept as long as the thumbnail data itself.
// Safe on any thread.
void RingZoomAttachLargeImage(NSData *thumbnail, NSData *largeJPEG);
NSData *RingZoomLargeImageForThumbnail(NSData *thumbnail);

// Sharp picture for the card the fingers rest on, prepared while the menu is
// open. `key` identifies the card. A request waits a moment, so sweeping
// across the cards does not prepare each of them; a newer request or
// RingZoomForgetPicture cancels it.
//
// `storedJPEG` is ready soon after, and a live capture of the window (when
// `windowID` is given) replaces it. `liveStillValid` runs on a background
// queue after the capture and can drop it, for example when Chrome shows
// another tab by then.
void RingZoomPreparePicture(id key, NSData *storedJPEG, CGWindowID windowID, CGFloat scale,
                            BOOL (^liveStillValid)(void));
void RingZoomCancelPicture(void);
// The prepared picture for this card, or NULL. The caller releases it.
CGImageRef RingZoomCopyPicture(id key);
void RingZoomForgetPicture(void);
