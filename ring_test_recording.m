// Screen recording for tests. See ring_test_recording.h.

#import "ring_test_recording.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface RingTestRecordingDelegate : NSObject <SCRecordingOutputDelegate, SCStreamDelegate>
@property(nonatomic, copy) void (^report)(NSString *status);
@end
@implementation RingTestRecordingDelegate
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)recordingOutput API_AVAILABLE(macos(15.0)) {
    if (self.report) self.report(@"done");
}
- (void)recordingOutput:(SCRecordingOutput *)recordingOutput didFailWithError:(NSError *)error API_AVAILABLE(macos(15.0)) {
    if (self.report) self.report([@"failed: " stringByAppendingString:error.localizedDescription ?: @""]);
}
@end

static SCStream *g_stream;
static RingTestRecordingDelegate *g_delegate;

void RingTestRecordScreen(NSString *path, double seconds, void (^report)(NSString *status)) {
    if (@available(macOS 15.0, *)) {
        if (g_stream) return;
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                                                    completionHandler:^(SCShareableContent *content, NSError *error) {
            SCDisplay *display = nil;
            for (SCDisplay *candidate in content.displays) {
                if (candidate.displayID == CGMainDisplayID()) { display = candidate; break; }
            }
            if (!display) {
                report([@"failed: " stringByAppendingString:error.localizedDescription ?: @"no display"]);
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
                SCStreamConfiguration *configuration = [SCStreamConfiguration new];
                configuration.width = display.width;
                configuration.height = display.height;
                configuration.minimumFrameInterval = (CMTime){.value = 1, .timescale = 60, .flags = kCMTimeFlags_Valid};
                configuration.showsCursor = NO;
                g_delegate = [RingTestRecordingDelegate new];
                g_delegate.report = report;
                g_stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:g_delegate];
                SCRecordingOutputConfiguration *output = [SCRecordingOutputConfiguration new];
                output.outputURL = [NSURL fileURLWithPath:path];
                SCRecordingOutput *recording = [[SCRecordingOutput alloc] initWithConfiguration:output delegate:g_delegate];
                NSError *addError = nil;
                if (![g_stream addRecordingOutput:recording error:&addError]) {
                    report([@"failed: " stringByAppendingString:addError.localizedDescription ?: @""]);
                    g_stream = nil;
                    return;
                }
                [g_stream startCaptureWithCompletionHandler:^(NSError *startError) {
                    report(startError ? [@"failed: " stringByAppendingString:startError.localizedDescription] : @"started");
                }];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [g_stream stopCaptureWithCompletionHandler:^(NSError *stopError) {
                        dispatch_async(dispatch_get_main_queue(), ^{ g_stream = nil; });
                    }];
                });
            });
        }];
    } else {
        report(@"failed: needs macOS 15");
    }
}
