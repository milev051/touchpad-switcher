// Site icons for Chrome tab cards. They are fetched from the site itself
// (/favicon.ico, or the icon its start page declares), never from a third
// party, and kept in memory per site. Main thread only.

#import <Cocoa/Cocoa.h>

// The icon of the site a tab shows, or nil while it loads or when the site
// has none. The first call for a site starts loading it.
NSImage *RingFaviconForURL(NSString *tabURL);
// Runs on the main thread whenever a newly loaded icon can be drawn.
void RingFaviconsSetLoadedHandler(void (^handler)(void));
