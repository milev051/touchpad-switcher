#import "ring_update.h"

@implementation RingRelease
@end

static NSError *updateError(NSString *message) {
    return [NSError errorWithDomain:@"TouchpadSwitcherUpdate" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSData *download(NSURL *url, NSTimeInterval timeout, NSError **error) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = timeout;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Touchpad-Switcher-Mac" forHTTPHeaderField:@"User-Agent"];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSError *failure = nil;
    __block NSInteger status = 0;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *taskError) {
            body = data;
            failure = taskError;
            status = [(NSHTTPURLResponse *)response statusCode];
            dispatch_semaphore_signal(finished);
        }];
    [task resume];
    if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 5) * NSEC_PER_SEC))) != 0) {
        [task cancel];
        if (error) *error = updateError(@"GitHub nije odgovorio na vreme.");
        [session invalidateAndCancel];
        return nil;
    }
    [session finishTasksAndInvalidate];
    if (failure || status != 200 || !body.length) {
        if (error) *error = failure ?: updateError([NSString stringWithFormat:@"GitHub je vratio HTTP %ld.", (long)status]);
        return nil;
    }
    return body;
}

RingRelease *RingLatestRelease(NSError **error) {
    NSURL *url = [NSURL URLWithString:@"https://api.github.com/repos/milev051/touchpad-switcher/releases/latest"];
    NSData *data = download(url, 15, error);
    if (!data) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) *error = updateError(@"GitHub nije vratio podatke o izdanju.");
        return nil;
    }
    NSString *tag = json[@"tag_name"];
    if (![tag isKindOfClass:[NSString class]] || !tag.length) {
        if (error) *error = updateError(@"Izdanje nema broj verzije.");
        return nil;
    }
    for (NSDictionary *asset in json[@"assets"] ?: @[]) {
        NSString *name = asset[@"name"];
        NSString *address = asset[@"browser_download_url"];
        if ([name isKindOfClass:[NSString class]] && [name.pathExtension.lowercaseString isEqualToString:@"zip"] &&
            [address isKindOfClass:[NSString class]] && [address hasPrefix:@"https://github.com/milev051/touchpad-switcher/releases/download/"]) {
            RingRelease *release = [RingRelease new];
            release.version = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
            release.assetURL = [NSURL URLWithString:address];
            return release;
        }
    }
    if (error) *error = updateError(@"Izdanje nema ZIP aplikacije.");
    return nil;
}

BOOL RingVersionNewer(NSString *current, NSString *candidate) {
    if (!candidate.length) return NO;
    if (!current.length) return YES;
    return [candidate compare:current options:NSNumericSearch] == NSOrderedDescending;
}

static BOOL command(NSString *executable, NSArray<NSString *> *arguments, NSError **error) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = output;
    if (![task launchAndReturnError:error]) return NO;
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus == 0) return YES;
    NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (error) *error = updateError(message.length ? message : @"Instalacija nije uspela.");
    return NO;
}

BOOL RingInstallRelease(RingRelease *release, NSError **error) {
    NSData *zip = download(release.assetURL, 60, error);
    if (!zip) return NO;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![files createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSString *zipPath = [temporary stringByAppendingPathComponent:@"Touchpad Switcher.zip"];
    NSString *extracted = [temporary stringByAppendingPathComponent:@"Touchpad Switcher.app"];
    NSString *installed = @"/Applications/Touchpad Switcher.app";
    NSString *staged = [@"/Applications" stringByAppendingPathComponent:
                        [NSString stringWithFormat:@".Touchpad Switcher-update-%@.app", NSUUID.UUID.UUIDString]];
    NSString *backup = [@"/Applications" stringByAppendingPathComponent:
                        [NSString stringWithFormat:@".Touchpad Switcher-backup-%@.app", NSUUID.UUID.UUIDString]];
    BOOL success = NO;
    NSBundle *bundle = nil;
    if (![zip writeToFile:zipPath options:NSDataWritingAtomic error:error]) goto cleanup;
    if (!command(@"/usr/bin/ditto", @[@"-x", @"-k", zipPath, temporary], error)) goto cleanup;
    if (!command(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", extracted], error)) goto cleanup;
    bundle = [NSBundle bundleWithPath:extracted];
    if (![bundle.bundleIdentifier isEqualToString:@"com.milev.touchpad-switcher"] ||
        ![bundle.infoDictionary[@"CFBundleShortVersionString"] isEqualToString:release.version]) {
        if (error) *error = updateError(@"Preuzeta aplikacija ne odgovara izdanju.");
        goto cleanup;
    }
    if (!command(@"/usr/bin/ditto", @[extracted, staged], error)) goto cleanup;
    if ([files fileExistsAtPath:installed] && ![files moveItemAtPath:installed toPath:backup error:error]) goto cleanup;
    if (![files moveItemAtPath:staged toPath:installed error:error]) {
        if ([files fileExistsAtPath:backup]) [files moveItemAtPath:backup toPath:installed error:nil];
        goto cleanup;
    }
    success = YES;
cleanup:
    [files removeItemAtPath:temporary error:nil];
    [files removeItemAtPath:staged error:nil];
    if (success) [files removeItemAtPath:backup error:nil];
    return success;
}
