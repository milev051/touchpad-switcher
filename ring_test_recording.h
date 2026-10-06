// Test helper: records the main display to a movie, to look at an animation
// frame by frame. Uses this app's Screen Recording permission. Main thread.

#import <Cocoa/Cocoa.h>

// Records for `seconds` to `path` (a .mov). `report` gets "started", "done"
// or "failed: ..." on any thread. Does nothing while a recording runs.
void RingTestRecordScreen(NSString *path, double seconds, void (^report)(NSString *status));
