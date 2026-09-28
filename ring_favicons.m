// Site icons for Chrome tab cards. See ring_favicons.h.
//
// Bigger is better: the icon also fills the ring's center circle, where a
// 16 px favicon looks blurry. Order of attempts for a site: the largest icon
// declared on https://site/ (apple-touch-icon is usually 180 px), then
// /apple-touch-icon.png, then /favicon.ico. A site without an icon is asked
// again after ten minutes, not on every scan.

#import "ring_favicons.h"

static NSMutableDictionary<NSString *, NSImage *> *g_icons;        // origin -> icon
static NSMutableDictionary<NSString *, NSDate *> *g_missingUntil;  // origin -> retry time
static NSMutableSet<NSString *> *g_loading;
static void (^g_loadedHandler)(void);
static const NSTimeInterval kRetryMissingAfter = 600;

static NSURLSession *faviconSession(void) {
    static NSURLSession *session;
    if (!session) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 5;
        // Some sites refuse requests that do not look like a browser.
        configuration.HTTPAdditionalHeaders = @{
            @"User-Agent": @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
        };
        session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return session;
}

static NSImage *iconFromResponse(NSData *data, NSURLResponse *response, NSError *error) {
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    if (error || !data.length || http.statusCode != 200) return nil;
    NSImage *image = [[NSImage alloc] initWithData:data];
    return image.size.width >= 8 && image.size.height >= 8 ? image : nil;
}

// The largest icon a page declares, resolved against the page address.
static NSURL *declaredIconURL(NSData *html, NSURL *pageURL) {
    NSString *page = [[NSString alloc] initWithData:html encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:html encoding:NSISOLatin1StringEncoding];
    if (!page.length) return nil;
    NSRegularExpression *linkTag = [NSRegularExpression regularExpressionWithPattern:@"<link\\b[^>]*>"
                                                                            options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *relValue = [NSRegularExpression regularExpressionWithPattern:@"rel\\s*=\\s*[\"']([^\"']*)[\"']"
                                                                             options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *href = [NSRegularExpression regularExpressionWithPattern:@"href\\s*=\\s*[\"']([^\"']+)[\"']"
                                                                         options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *sizes = [NSRegularExpression regularExpressionWithPattern:@"sizes\\s*=\\s*[\"'](\\d+)x\\d+"
                                                                          options:NSRegularExpressionCaseInsensitive error:nil];
    NSURL *best = nil;
    NSInteger bestScore = 0;
    for (NSTextCheckingResult *tag in [linkTag matchesInString:page options:0 range:NSMakeRange(0, page.length)]) {
        NSString *link = [page substringWithRange:tag.range];
        NSRange whole = NSMakeRange(0, link.length);
        NSTextCheckingResult *rel = [relValue firstMatchInString:link options:0 range:whole];
        NSTextCheckingResult *target = [href firstMatchInString:link options:0 range:whole];
        if (!rel || !target) continue;
        NSString *kind = [link substringWithRange:[rel rangeAtIndex:1]].lowercaseString;
        if (![kind containsString:@"icon"] || [kind containsString:@"mask"]) continue;   // mask-icon is a one-color outline
        NSString *address = [[link substringWithRange:[target rangeAtIndex:1]]
                             stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        NSInteger score = [kind containsString:@"apple-touch-icon"] ? 180 : 32;
        NSTextCheckingResult *size = [sizes firstMatchInString:link options:0 range:whole];
        if (size) score = [link substringWithRange:[size rangeAtIndex:1]].integerValue;
        if ([address.lowercaseString hasSuffix:@".svg"]) score = 256;   // scales to any size
        NSURL *url = [NSURL URLWithString:address relativeToURL:pageURL].absoluteURL;
        if (url && score > bestScore) { best = url; bestScore = score; }
    }
    return best;
}

static void finishLoading(NSString *origin, NSImage *icon) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_loading removeObject:origin];
        if (icon) {
            g_icons[origin] = icon;
            if (g_loadedHandler) g_loadedHandler();
        } else {
            g_missingUntil[origin] = [NSDate dateWithTimeIntervalSinceNow:kRetryMissingAfter];
        }
    });
}

// Tries the addresses in order and keeps the first real image.
static void loadFirstIcon(NSString *origin, NSArray<NSURL *> *candidates) {
    if (!candidates.count) { finishLoading(origin, nil); return; }
    NSArray<NSURL *> *rest = [candidates subarrayWithRange:NSMakeRange(1, candidates.count - 1)];
    [[faviconSession() dataTaskWithURL:candidates.firstObject
                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSImage *icon = iconFromResponse(data, response, error);
        if (icon) finishLoading(origin, icon);
        else loadFirstIcon(origin, rest);
    }] resume];
}

static void loadIcon(NSString *origin) {
    NSURL *rootURL = [NSURL URLWithString:[origin stringByAppendingString:@"/"]];
    [[faviconSession() dataTaskWithURL:rootURL completionHandler:^(NSData *page, NSURLResponse *response, NSError *error) {
        NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
        NSURL *declared = error ? nil : declaredIconURL(page, response.URL ?: rootURL);
        if (declared) [candidates addObject:declared];
        [candidates addObject:[NSURL URLWithString:[origin stringByAppendingString:@"/apple-touch-icon.png"]]];
        [candidates addObject:[NSURL URLWithString:[origin stringByAppendingString:@"/favicon.ico"]]];
        loadFirstIcon(origin, candidates);
    }] resume];
}

NSImage *RingFaviconForURL(NSString *tabURL) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:tabURL ?: @""];
    NSString *scheme = parts.scheme.lowercaseString;
    if (!parts.host.length || !([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) return nil;
    NSString *origin = [NSString stringWithFormat:@"%@://%@", scheme, parts.host.lowercaseString];
    if (!g_icons) {
        g_icons = [NSMutableDictionary dictionary];
        g_missingUntil = [NSMutableDictionary dictionary];
        g_loading = [NSMutableSet set];
    }
    NSImage *icon = g_icons[origin];
    if (icon) return icon;
    NSDate *retry = g_missingUntil[origin];
    if ((retry && retry.timeIntervalSinceNow > 0) || [g_loading containsObject:origin]) return nil;
    [g_loading addObject:origin];
    loadIcon(origin);
    return nil;
}

void RingFaviconsSetLoadedHandler(void (^handler)(void)) {
    g_loadedHandler = [handler copy];
}
