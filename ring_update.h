#import <Foundation/Foundation.h>

@interface RingRelease : NSObject
@property(nonatomic, copy) NSString *version;
@property(nonatomic, strong) NSURL *assetURL;
@end

RingRelease *RingLatestRelease(NSError **error);
BOOL RingVersionNewer(NSString *current, NSString *candidate);
BOOL RingInstallRelease(RingRelease *release, NSError **error);
