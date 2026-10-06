// Pregled koristi stvarni RingView i isti proračun rasporeda kao aplikacija.
#define main ring_application_main
#include "../touchpad_ring_test.m"
#undef main
#include <assert.h>

// Provera AX protokola bez pomeranja stvarnih prozora.
typedef struct { BOOL minimized; BOOL ignoresWrite; AXError error; int writes; BOOL button; int presses; BOOL ignoresPress; } TestMinimizeWindow;
static AXError testReadWindow(AXUIElementRef reference,CFStringRef attribute,CFTypeRef *value) {
    TestMinimizeWindow *window=(void *)reference;
    if (CFEqual(attribute,kAXMinimizeButtonAttribute)) {
        *value=window->button ? CFRetain((__bridge CFTypeRef)[NSValue valueWithPointer:window]) : NULL;
        return window->button ? kAXErrorSuccess : kAXErrorAttributeUnsupported;
    }
    *value=CFRetain(window->minimized ? kCFBooleanTrue : kCFBooleanFalse);
    return kAXErrorSuccess;
}
static AXError testWriteWindow(AXUIElementRef reference,CFStringRef attribute,CFTypeRef value) {
    TestMinimizeWindow *window=(void *)reference;
    window->writes++;
    if (window->error) return window->error;
    if (!window->ignoresWrite) window->minimized=CFEqual(value,kCFBooleanTrue);
    return kAXErrorSuccess;
}

static AXError testPressWindow(AXUIElementRef reference,CFStringRef action) {
    assert(CFEqual(action,kAXPressAction));
    TestMinimizeWindow *window=[(__bridge NSValue *)reference pointerValue];
    window->presses++;
    if (!window->ignoresPress) window->minimized=YES;
    return kAXErrorSuccess;
}

@interface PreviewRingView : RingView
@property BOOL showGuides;
@property(copy) void (^selectionChanged)(NSInteger);
- (void)testDesktop:(id)sender;
@end
@implementation PreviewRingView
- (void)testDesktop:(id)sender { minimizeAllWindows(); }
- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger hit = -1;
    for (NSUInteger i = 0; i < self.cardLayers.count; i++) {
        NSRect rect = [self cardRectForIndex:i];
        CALayer *layer = self.cardLayers[i];
        CGFloat scale = layer.transform.m11;
        NSRect area = NSMakeRect(layer.position.x - NSWidth(rect) * scale / 2,
                                 layer.position.y - NSHeight(rect) * scale / 2,
                                 NSWidth(rect) * scale, NSHeight(rect) * scale);
        if (NSPointInRect(point, area)) hit = i;
    }
    self.selectedIndex = hit;
    if (self.selectionChanged) self.selectionChanged(hit);
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (!self.showGuides || self.selectedIndex >= 0) return;
    [[NSColor colorWithCalibratedRed:0.5 green:0.85 blue:1 alpha:0.4] setStroke];
    NSBezierPath *circle=[NSBezierPath bezierPath];
    for (NSUInteger i=0;i<self.entries.count;i++) {
        NSRect rect=[self cardRectForIndex:i];
        NSPoint center=NSMakePoint(NSMidX(rect),NSMidY(rect));
        if (!i) [circle moveToPoint:center]; else [circle lineToPoint:center];
    }
    [circle closePath];
    CGFloat dash[]={3,5};
    [circle setLineDash:dash count:2 phase:0];
    [circle stroke];
    for (NSUInteger i = 0; i < self.entries.count; i++) {
        CGFloat angle=rawItemAngle(i,self.entries.count)-M_PI/self.entries.count;
        CGFloat step = fabs(remainder(cardScreenAngle(i,self.entries.count) -
            cardScreenAngle((i+1)%self.entries.count,self.entries.count),2*M_PI));
        NSString *label=[NSString stringWithFormat:@"%.1f°",step*180/M_PI];
        NSDictionary *style=@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
                              NSForegroundColorAttributeName:NSColor.whiteColor};
        NSSize labelSize=[label sizeWithAttributes:style];
        CGFloat radius=self.ringRadius*0.76;
        [label drawAtPoint:NSMakePoint(self.anchorPoint.x+cos(angle)*radius-labelSize.width/2,
                                      self.anchorPoint.y+sin(angle)*self.ringRadiusY*0.76-labelSize.height/2) withAttributes:style];
    }
}
@end

@interface LayoutPreview : NSObject <NSWindowDelegate>
@property NSWindow *window;
@property PreviewRingView *ring;
@property NSSegmentedControl *countControl;
@property NSSegmentedControl *shapeControl;
@property NSSlider *selection;
@property NSTextField *selectionLabel;
@property NSButton *guides;
@property NSImage *reference;
- (void)rebuild:(NSUInteger)count;
@end
@implementation LayoutPreview
- (void)rebuild:(NSUInteger)count {
    NSMutableArray *entries = [NSMutableArray array];
    // Isečci iz korisnikovog prikaza služe samo kao uzorci u lokalnom pregledu.
    const NSRect crops[5] = {{747,8,504,304},{1262,371,419,251},{1065,880,420,251},
                             {510,880,420,251},{315,371,419,251}};
    const NSString *bundles[] = {@"com.aionui.app",@"com.apple.finder",@"com.google.Chrome",@"com.google.Chrome",@"net.whatsapp.WhatsApp"};
    const NSString *titles[] = {@"AionUi", @"Finder", @"Budžet", @"Statistika", @"WhatsApp"};
    NSImage *reference = self.reference;
    for (NSUInteger i = 0; i < count; i++) {
        RingEntry *entry = [RingEntry new];
        entry.application = NSRunningApplication.currentApplication;
        entry.windowTitle = (NSString *)titles[i % 5];
        NSURL *appURL=[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:(NSString *)bundles[i%5]];
        entry.icon = appURL ? [NSWorkspace.sharedWorkspace iconForFile:appURL.path] : [NSImage imageNamed:NSImageNameFolder];
        NSRect crop = crops[i % 5];
        CGFloat sourceScale = reference ? reference.size.width / 1996.0 : 1;
        crop = NSMakeRect(crop.origin.x * sourceScale, crop.origin.y * sourceScale,
                          crop.size.width * sourceScale, crop.size.height * sourceScale);
        crop.origin.y = reference.size.height - NSMaxY(crop);
        NSString *title = entry.windowTitle;
        NSInteger mode = self.shapeControl.selectedSegment;
        const NSSize mixedSizes[] = {{640,384},{384,640},{800,240},{480,480},{320,800}};
        NSSize imageSize = mode == 1 ? NSMakeSize(384,640) : (mode == 2 ? mixedSizes[i % 5] : NSMakeSize(640,384));
        entry.thumbnail = [NSImage imageWithSize:imageSize flipped:NO drawingHandler:^BOOL(NSRect rect) {
            if (reference && mode == 0) {
                [reference drawInRect:rect fromRect:crop operation:NSCompositingOperationSourceOver fraction:1];
            } else {
                [[NSColor colorWithCalibratedHue:(CGFloat)(i % 12)/12 saturation:0.35 brightness:0.35 alpha:1] setFill];
                NSRectFill(rect);
                [[NSColor colorWithCalibratedWhite:1 alpha:0.12] setFill];
                for (int row=0; row<5; row++) NSRectFill(NSMakeRect(28,NSHeight(rect)-105-row*42,MAX(20,NSWidth(rect)-56),20));
                [title drawAtPoint:NSMakePoint(28,NSHeight(rect)-60) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:32],NSForegroundColorAttributeName:NSColor.whiteColor}];
            }
            return YES;
        }];
        [entries addObject:entry];
    }
    self.ring.selectedIndex = -1;
    [self.ring resetSelectionVisuals];
    self.ring.entries = entries;
    self.selection.maxValue = count;
    self.selection.doubleValue = 0;
    [self resizeStage];
    [self choose:self.selection];
}
- (void)resizeStage {
    NSSize size = self.window.contentView.bounds.size;
    self.ring.frame = NSMakeRect(0,0,size.width,MAX(200,size.height-88));
    [self.ring prepareCardLayout];
    [self.ring updateCardLayersAnimated:NO refreshContents:YES];
    [self.ring updateHubAnimated:NO];
    [self.ring setNeedsDisplay:YES];
}
- (void)windowDidResize:(NSNotification *)notification { [self resizeStage]; }
- (void)countChanged:(NSSegmentedControl *)control {
    const NSUInteger counts[] = {3,4,5,6,7,8,12};
    [self rebuild:counts[control.selectedSegment]];
}
- (void)shapeChanged:(NSSegmentedControl *)control {
    [self rebuild:self.ring.entries.count];
}
- (void)choose:(NSSlider *)slider {
    NSInteger selected = lround(slider.doubleValue)-1;
    self.ring.selectedIndex = selected;
    self.selectionLabel.stringValue = selected < 0 ? @"Bez izbora" : [NSString stringWithFormat:@"Izbor: %ld",selected+1];
    [self.ring setNeedsDisplay:YES];
}
- (void)toggleGuides:(NSButton *)button {
    self.ring.showGuides = button.state == NSControlStateValueOn;
    [self.ring setNeedsDisplay:YES];
}
- (void)ratioChanged:(NSSegmentedControl *)control {
    const CGFloat ratios[] = {1.6,16.0/9.0,4.0/3.0};
    CGFloat width = NSWidth(self.window.contentView.bounds);
    [self.window setContentSize:NSMakeSize(width,width/ratios[control.selectedSegment]+88)];
}
- (void)windowWillClose:(NSNotification *)notification { [NSApp terminate:nil]; }
@end

static void renderPreview(PreviewRingView *view, NSString *path) {
    [view display];
    [view updateCardLayersAnimated:NO refreshContents:YES];
    [view updateHubAnimated:NO];
    NSUInteger width = NSWidth(view.bounds), height = NSHeight(view.bounds);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    CGContextRef context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap].CGContext;
    CGContextSetRGBFillColor(context,0.055,0.06,0.07,1);
    CGContextFillRect(context,CGRectMake(0,0,width,height));
    [view.layer renderInContext:context];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    printf("%lu proporcionalnih kartica, elipsa %.0f × %.0f. Slika: %s\n",
           (unsigned long)view.entries.count,view.ringRadius*2,view.ringRadiusY*2,path.UTF8String);
}

// Provera stvarnih slojeva, razmaka i izbora na više formata ekrana.
static void verifyPreview(LayoutPreview *preview) {
    assert(sameChromeCapturePage(@"101",@"https://youtube.com/watch?v=abcdefghijk",@"101",@"https://youtube.com/watch?v=abcdefghijk&t=20"));
    assert(!sameChromeCapturePage(@"101",@"https://google.com",@"102",@"https://youtube.com/watch?v=abcdefghijk"));
    assert(!sameChromeCapturePage(@"101",@"https://google.com",@"101",@"https://youtube.com/watch?v=abcdefghijk"));
    assert(!sameChromeCapturePage(@"101",@"https://youtube.com/watch?v=abcdefghijk",@"101",@"https://youtube.com/watch?v=lmnopqrstuv"));
    assert(!sameChromeCapturePage(nil,nil,@"101",@"https://google.com"));
    NSData *savedPicture=[@"sačuvan snimak" dataUsingEncoding:NSUTF8StringEncoding];
    g_thumbnailCache=[NSMutableDictionary dictionaryWithObject:savedPicture forKey:@1];
    g_tabThumbnailCache=[NSMutableDictionary dictionaryWithObject:savedPicture forKey:@"tab"];
    g_windowLastCaptured=[NSMutableDictionary dictionaryWithObject:@1 forKey:@1];
    g_tabLastCaptured=[NSMutableDictionary dictionaryWithObject:@1 forKey:@"tab"];
    g_chromeWindowLastCapture=[NSMutableDictionary dictionaryWithObject:@1 forKey:@1];
    invalidateThumbnailCaptureTimes();
    assert([g_thumbnailCache[@1] isEqualToData:savedPicture]);
    assert([g_tabThumbnailCache[@"tab"] isEqualToData:savedPicture]);
    assert(!g_windowLastCaptured.count && !g_tabLastCaptured.count && !g_chromeWindowLastCapture.count);
    printf("Chrome: promene taba i stranice odbacuju snimak; promena teme čuva postojeće slike.\n");
    RingEntry *duplicateA=[RingEntry new],*duplicateB=[RingEntry new];
    duplicateA.chromeWindowID=duplicateB.chromeWindowID=@"100";
    duplicateA.chromeTabID=@"200"; duplicateB.chromeTabID=@"201";
    duplicateA.tabURL=duplicateB.tabURL=@"https://example.com/ista-stranica";
    duplicateA.tabTitle=duplicateB.tabTitle=@"Isti naslov";
    duplicateA.isTab=duplicateB.isTab=YES;
    assert(![tabThumbnailKey(duplicateA) isEqualToString:tabThumbnailKey(duplicateB)]);
    NSSet *survivors=[NSSet setWithObject:@"100:201"];
    assert(chromeTabMembership(duplicateA,survivors)==0);
    assert(chromeTabMembership(duplicateB,survivors)==1);
    assert(chromeTabMembership(duplicateB,nil)==-1);
    RingEntry *repeated=[RingEntry new];
    repeated.chromeWindowID=duplicateB.chromeWindowID;
    repeated.chromeTabID=duplicateB.chromeTabID;
    repeated.tabIndex=99;
    RingEntry *shortcut=[RingEntry new]; shortcut.isShortcut=YES;
    NSArray *inventory=@[duplicateA,duplicateB,repeated,shortcut];
    NSArray *unknown=reconcileChromeEntries(inventory,nil);
    assert(unknown.count==3 && unknown[0]==duplicateA && unknown[1]==duplicateB);
    NSArray *fresh=reconcileChromeEntries(inventory,survivors);
    assert(fresh.count==2 && fresh[0]==duplicateB && fresh[1]==shortcut);
    assert(reconcileChromeEntries(inventory,[NSSet set]).count==1);
    assert(reconcileChromeEntries(fresh,survivors)==fresh);

    printf("Isti link i naslov: zatvoreni tab se uklanja, drugi ostaje prema svom ID-u.\n");
    g_pointerX=0.20; g_pointerY=0;
    assert(pointerSelection(5,0)==-1);
    g_pointerX=0.24;
    assert(pointerSelection(5,-1)==-1);
    g_pointerX=0.31;
    assert(pointerSelection(5,-1)>=0);
    unsigned savedMask=atomic_load(&g_shortcutMask);
    atomic_store(&g_shortcutMask,7);
    NSArray *shortcuts=commandShortcutEntries();
    assert(shortcuts.count==3);
    for (RingEntry *entry in shortcuts) assert(entry.isShortcut && entry.folderPath.length && entry.icon);
    RingView *savedRing=g_ringView;
    NSArray *savedEntries=g_windowEntries;
    NSArray *savedStandard=g_standardRingEntries;
    int savedCount=atomic_load(&g_windowEntryCount);
    BOOL savedMode=g_commandShortcutMode;
    g_ringView=preview.ring;
    g_standardRingEntries=preview.ring.entries;
    NSArray *normal=g_standardRingEntries;
    g_commandShortcutMode=NO;
    setCommandShortcutMode(YES);
    assert(g_commandShortcutMode && g_windowEntries.count==3 && atomic_load(&g_windowEntryCount)==3);
    setCommandShortcutMode(NO);
    assert(!g_commandShortcutMode && g_windowEntries==normal && preview.ring.entries==normal);
    g_ringView=savedRing; g_windowEntries=savedEntries;
    g_standardRingEntries=savedStandard; g_commandShortcutMode=savedMode;
    atomic_store(&g_windowEntryCount,savedCount);
    atomic_store(&g_shortcutMask,0);
    assert(commandShortcutEntries().count==0);
    unsigned savedPersistent=atomic_load(&g_persistentShortcutMask);
    atomic_store(&g_persistentShortcutMask,7);
    NSArray *withFolders=entriesWithPersistentShortcuts(normal);
    assert(withFolders.count==normal.count+3);
    assert(entriesWithPersistentShortcuts(withFolders).count==withFolders.count);
    atomic_store(&g_persistentShortcutMask,0);
    assert(entriesWithPersistentShortcuts(withFolders).count==normal.count);
    assert(windowAccessAllowsMinimizing(NO,kAXErrorSuccess));
    assert(!windowAccessAllowsMinimizing(NO,kAXErrorAPIDisabled));
    assert(!windowAccessAllowsMinimizing(NO,kAXErrorCannotComplete));
    assert(!windowAccessAllowsMinimizing(NO,kAXErrorAttributeUnsupported));
    assert(windowAccessAllowsMinimizing(YES,kAXErrorCannotComplete));
    NSMutableArray *manyCards=[NSMutableArray array];
    for (int i=0;i<37;i++) [manyCards addObject:[RingEntry new]];
    NSMutableSet *seenPages=[NSMutableSet set];
    for (NSUInteger page=0;page<4;page++) {
        NSArray *cards=ringEntriesOnPage(manyCards,page);
        assert(cards.count<=10 && cards.count>0);
        for (RingEntry *entry in cards) { assert(![seenPages containsObject:entry]); [seenPages addObject:entry]; }
    }
    assert(seenPages.count==37);
    assert(ringEntriesOnPage(@[],0).count==0);
    assert(ringEntriesOnPage(manyCards,99).count==7);
    assert(ringEntriesOnPage([manyCards subarrayWithRange:NSMakeRange(0,10)],0).count==10);
    assert(!atomic_load(&g_hiddenTabLoaderRunning));
    loadHiddenChromeTabs(123);
    assert(!atomic_load(&g_hiddenTabLoaderRunning));
    printf("37 kartica: četiri stranice, bez duplikata i gubitka; skriveni tabovi se ne aktiviraju.\n");
    uint64_t start=1000000000ULL;
    assert(isQuickThreeFingerTap(start,start+499000000ULL,0,YES));
    assert(!isQuickThreeFingerTap(start,start+500000000ULL,0,YES));
    assert(!isQuickThreeFingerTap(start,start+100000000ULL,0.2,YES));
    assert(!isQuickThreeFingerTap(start,start+100000000ULL,0,NO));
    assert(!isQuickThreeFingerTap(start,start-1,0,YES));
    NSMutableArray *savedHistory=g_recentWindowKeys;
    RingEntry *recentA=[RingEntry new],*recentB=[RingEntry new],*recentC=[RingEntry new];
    recentA.application=recentB.application=recentC.application=NSRunningApplication.currentApplication;
    recentA.windowID=101; recentB.windowID=102; recentC.windowID=103;
    NSArray *recentEntries=@[recentA,recentB,recentC];
    g_recentWindowKeys=[NSMutableArray array];
    recordRecentWindow(recentWindowKey(recentA));
    assert(previousRecentWindow(recentEntries)==nil);
    recordRecentWindow(recentWindowKey(recentB));
    assert(previousWindowIndex(recentEntries,previousRecentWindow(recentEntries))==0);
    recordRecentWindow(recentWindowKey(recentA));
    assert(previousWindowIndex(recentEntries,previousRecentWindow(recentEntries))==1);
    recordRecentWindow(recentWindowKey(recentA));
    assert(g_recentWindowKeys.count==2); // Ponovljeni uzorak fokusa ne pravi duplikate.
    recordRecentWindow(recentWindowKey(recentC));
    assert([previousRecentWindow(@[recentB,recentC]) isEqualToString:recentWindowKey(recentB)]);
    assert(previousWindowIndex(@[recentC],recentWindowKey(recentB))==-1);
    recentB.isTab=YES; recentB.isSelectedTab=YES; recentB.chromeTabID=@"123";
    RingEntry *quickWindow=windowEntryForQuickSwitch(recentB);
    assert(quickWindow.windowID==recentB.windowID && quickWindow.application==recentB.application);
    assert(!quickWindow.isTab && quickWindow.chromeTabID==nil && recentB.isTab);
    recentB.isSelectedTab=NO;
    assert(recentWindowKey(recentB)==nil); // Ne aktiviraj drugi tab istog prozora.
    g_recentWindowKeys=savedHistory;
    printf("Brzi tap: prag 0.5 s, povlačenje, ponavljanje A/B i uklonjen prozor prolaze.\n");
    TestMinimizeWindow first={0},second={0},already={.minimized=YES},denied={.error=kAXErrorAPIDisabled},ignored={.ignoresWrite=YES};
    assert(minimizeWindow((void *)&first,testReadWindow,testWriteWindow,testPressWindow)==kAXErrorSuccess);
    assert(minimizeWindow((void *)&second,testReadWindow,testWriteWindow,testPressWindow)==kAXErrorSuccess);
    assert(first.minimized && second.minimized && first.writes==1 && second.writes==1);
    assert(minimizeWindow((void *)&already,testReadWindow,testWriteWindow,testPressWindow)==kAXErrorSuccess && already.writes==0);
    assert(minimizeWindow((void *)&denied,testReadWindow,testWriteWindow,testPressWindow)==kAXErrorAPIDisabled);
    assert(minimizeWindow((void *)&ignored,testReadWindow,testWriteWindow,testPressWindow)==kAXErrorCannotComplete);
    TestMinimizeWindow buttonOnly={.error=kAXErrorAttributeUnsupported,.button=YES};
    TestMinimizeWindow ignoredButton={.ignoresWrite=YES,.button=YES,.ignoresPress=YES};
    assert(minimizeWindow((void *)&buttonOnly,testReadWindow,testWriteWindow,testPressWindow)==kAXErrorSuccess);
    assert(buttonOnly.minimized && buttonOnly.presses==1);
    assert(minimizeWindow((void *)&ignoredButton,testReadWindow,testWriteWindow,testPressWindow)==kAXErrorCannotComplete);
    assert(ignoredButton.presses==1 && !ignoredButton.minimized);
    RingView *pointerTest=[[RingView alloc] initWithFrame:NSMakeRect(0,0,800,600)];
    pointerTest.anchorPoint=NSMakePoint(400,300); pointerTest.ringRadius=200;
    int savedStyle=atomic_load(&g_settingPointerStyle);
    for (int style=PointerStyleArrow;style<=PointerStyleDot;style++) {
        atomic_store(&g_settingPointerStyle,style);
        [pointerTest resetPointer]; [pointerTest movePointerTo:NSZeroPoint];
        assert(![pointerTest.pointerView.layer animationForKey:@"pointerMovement"]);
        [pointerTest movePointerTo:NSMakePoint(-0.5,0.01)];
        [pointerTest movePointerTo:NSMakePoint(-0.5,-0.01)];
        CABasicAnimation *rotation=(id)[pointerTest.pointerArrow animationForKey:@"pointerRotation"];
        assert(rotation && fabs([rotation.toValue doubleValue]-[rotation.fromValue doubleValue])<=M_PI);
        assert([pointerTest.pointerView.layer animationForKey:@"pointerMovement"]);
        assert(NSEqualPoints(pointerTest.lastPointer,NSMakePoint(-0.5,-0.01)));
        [pointerTest movePointerTo:NSZeroPoint];
        assert(![pointerTest.pointerArrow animationForKey:@"pointerRotation"]);
    }
    atomic_store(&g_settingPointerStyle,savedStyle);
    NSArray *desktop=shortcutEntriesForMask(32);
    assert(desktop.count==1);
    RingEntry *desktopEntry=desktop.firstObject;
    assert(desktopEntry.minimizesAllWindows && desktopEntry.isShortcut && desktopEntry.icon);
    assert(!desktopEntry.opensNewChromeTab && !desktopEntry.folderPath.length);
    atomic_store(&g_persistentShortcutMask,32);
    assert(entriesWithPersistentShortcuts(normal).count==normal.count+1);
    NSArray *newTabs=shortcutEntriesForMask(24);
    NSURL *chromeURL=[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.google.Chrome"];
    assert(newTabs.count==(chromeURL ? 2 : 0));
    if (chromeURL) {
        RingEntry *chrome=newTabs[0], *youtube=newTabs[1];
        assert(chrome.opensNewChromeTab && youtube.opensNewChromeTab);
        assert([youtube.tabURL isEqualToString:@"https://www.youtube.com/"] && youtube.icon);
        assert([newChromeTabScript(chrome) containsString:@"chrome://newtab/"]);
        assert([newChromeTabScript(youtube) containsString:@"https://www.youtube.com/"]);
        atomic_store(&g_persistentShortcutMask,24);
        NSArray *permanent=entriesWithPersistentShortcuts(normal);
        assert(permanent.count==normal.count+2);
        assert(entriesWithPersistentShortcuts(permanent).count==permanent.count);
        g_ringView=preview.ring;
        g_standardRingEntries=permanent;
        g_commandShortcutMode=NO;
        atomic_store(&g_shortcutMask,7);
        setCommandShortcutMode(YES);
        assert(g_windowEntries.count==3);
        setCommandShortcutMode(NO);
        assert(g_windowEntries==permanent && g_windowEntries.count==normal.count+2);
        g_ringView=savedRing; g_windowEntries=savedEntries;
        g_standardRingEntries=savedStandard; g_commandShortcutMode=savedMode;
        atomic_store(&g_windowEntryCount,savedCount);
    }
    atomic_store(&g_persistentShortcutMask,savedPersistent);
    atomic_store(&g_shortcutMask,savedMask);
    printf("Stalne prečice: bez duplikata, uklanjanje, novi Chrome/YouTube tab i povratak sa Cmd-a prolaze.\n");
    printf("Poništavanje: šira zona sa histerezom. Cmd prečice poštuju izabrane opcije.\n");
    MTTouch contacts[4]={0};
    for (int i=0;i<4;i++) {
        contacts[i].state=MTTouchStateTouching;
        contacts[i].normalizedVector.position.x=0.4;
        contacts[i].normalizedVector.position.y=0.6;
    }
    CGEventRef scroll=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitPixel,1,12);
    CGEventRef motion=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,CGPointZero,kCGMouseButtonLeft);
    for (int repeat=0;repeat<20;repeat++) for (int fingers=2;fingers>=0;fingers--) {
        // Skrol sa dva prsta prolazi pre otvaranja menija.
        atomic_store(&g_gestureActive,false);
        atomic_store(&g_gestureEnding,false);
        atomic_store(&g_ringOverlayVisible,false);
        atomic_store(&g_scrollSuppressionActive,false);
        atomic_store(&g_suppressGestureMomentum,false);
        CGEventSetIntegerValueField(scroll,kCGScrollWheelEventMomentumPhase,kCGMomentumScrollPhaseNone);
        assert(filterScrollDuringRing(NULL,kCGEventScrollWheel,scroll,NULL)==scroll);
        ringTouchCallback(NULL,contacts,3,0,0);
        assert(atomic_load(&g_gestureActive) && !atomic_load(&g_gestureEnding));
        uint64_t generation=atomic_load(&g_gestureGeneration);
        ringTouchCallback(NULL,contacts,3,0,0);
        assert(atomic_load(&g_gestureGeneration)==generation); // Isti dodir ne otvara novi meni.
        assert(filterScrollDuringRing(NULL,kCGEventScrollWheel,scroll,NULL)==NULL);
        assert(filterScrollDuringRing(NULL,kCGEventMouseMoved,motion,NULL)==NULL);
        g_selectedIndex=2;
        ringTouchCallback(NULL,contacts,fingers,0,0);
        assert(atomic_load(&g_gestureEnding) && selectionForLift()==2);
        ringTouchCallback(NULL,contacts,3,0,0);
        assert(atomic_load(&g_gestureEnding)); // Brz povratak čeka završetak prethodnog izbora.
        assert(atomic_load(&g_gestureGeneration)==generation);
        // Simulacija završenog izbora, bez aktiviranja stvarnih aplikacija u testu.
        atomic_store(&g_gestureActive,false);
        atomic_store(&g_gestureEnding,false);
        if (repeat%2==0) reopenTouchGestureWhenReady(NULL,generation);
        else ringTouchCallback(NULL,contacts,3,0,0);
        assert(atomic_load(&g_gestureActive) && !atomic_load(&g_gestureEnding));
        assert(atomic_load(&g_gestureGeneration)==generation+1);
        assert(g_selectedIndex==-1 && g_pointerX==0 && g_pointerY==0);
        assert(fabs(g_previousX-0.4)<0.001 && fabs(g_previousY-0.6)<0.001);
        // Stari zahtevi više ne smeju promeniti novu gestu.
        reopenTouchGestureWhenReady(NULL,generation);
        assert(atomic_load(&g_gestureGeneration)==generation+1);
        assert(filterScrollDuringRing(NULL,kCGEventScrollWheel,scroll,NULL)==NULL);
        atomic_fetch_add(&g_gestureGeneration,1); // Otkaži UI i aktivaciju zakazane iz testa.
        atomic_store(&g_gestureActive,false);
        atomic_store(&g_gestureEnding,false);
        ringTouchCallback(NULL,NULL,0,0,0);
        // Inercija starog skrola ostaje blokirana i posle isteka kratke zaštite.
        atomic_store(&g_scrollSuppressionUntilNanos,0);
        CGEventSetIntegerValueField(scroll,kCGScrollWheelEventMomentumPhase,kCGMomentumScrollPhaseContinue);
        assert(filterScrollDuringRing(NULL,kCGEventScrollWheel,scroll,NULL)==NULL);
        CGEventSetIntegerValueField(scroll,kCGScrollWheelEventMomentumPhase,kCGMomentumScrollPhaseEnd);
        assert(filterScrollDuringRing(NULL,kCGEventScrollWheel,scroll,NULL)==NULL);
        CGEventSetIntegerValueField(scroll,kCGScrollWheelEventMomentumPhase,kCGMomentumScrollPhaseNone);
        assert(filterScrollDuringRing(NULL,kCGEventScrollWheel,scroll,NULL)==scroll);
        assert(filterScrollDuringRing(NULL,kCGEventMouseMoved,motion,NULL)==motion);
        showSystemCursorAfterGesture();
    }
    // Zakašnjeni zahtev otpada ako su prsti već ponovo podignuti.
    uint64_t idleGeneration=atomic_load(&g_gestureGeneration);
    atomic_store(&g_activeTouchCount,2);
    reopenTouchGestureWhenReady(NULL,idleGeneration);
    assert(!atomic_load(&g_gestureActive));
    ringTouchCallback(NULL,contacts,4,0,0);
    ringTouchCallback(NULL,contacts,3,0,0);
    reopenTouchGestureWhenReady(NULL,idleGeneration);
    assert(atomic_load(&g_gestureActive));
    ringTouchCallback(NULL,NULL,0,0,0);
    atomic_store(&g_gestureActive,false);
    atomic_store(&g_gestureEnding,false);
    ringTouchCallback(NULL,contacts,3,0,0);
    assert(atomic_load(&g_gestureActive));
    atomic_fetch_add(&g_gestureGeneration,1);
    atomic_store(&g_gestureActive,false);
    atomic_store(&g_gestureEnding,false);
    ringTouchCallback(NULL,NULL,0,0,0);
    showSystemCursorAfterGesture();
    CFRelease(scroll); CFRelease(motion);
    printf("20 ponavljanja: 3 -> 2/1/0 -> 3, brz povratak, stari zahtevi i blokiranje skrola prolaze.\n");
    // Jedan prazan frejm mora osloboditi novu gestu, bez daljih callbackova.
    BOOL waiting = NO;
    assert(suppressTouchFrameAfterFourFingers(4, &waiting) && waiting);
    assert(!suppressTouchFrameAfterFourFingers(3, &waiting) && !waiting);
    assert(!suppressTouchFrameAfterFourFingers(1, &waiting) && !waiting);
    assert(!suppressTouchFrameAfterFourFingers(0, &waiting) && !waiting);
    assert(!suppressTouchFrameAfterFourFingers(3, &waiting));
    for (int repeat = 0; repeat < 20; repeat++) {
        assert(suppressTouchFrameAfterFourFingers(5, &waiting));
        assert(!suppressTouchFrameAfterFourFingers(0, &waiting) && !waiting);
        assert(!suppressTouchFrameAfterFourFingers(3, &waiting));
    }
    printf("Četiri prsta: oporavak nakon jednog praznog frejma i 20 ponavljanja prolaze.\n");
    assert(!shortcutSectionWanted(ShortcutTriggerNone, YES, YES));
    assert(shortcutSectionWanted(ShortcutTriggerCommand, YES, NO));
    assert(!shortcutSectionWanted(ShortcutTriggerCommand, NO, YES));
    assert(shortcutSectionWanted(ShortcutTriggerFourFingers, NO, YES));
    assert(!shortcutSectionWanted(ShortcutTriggerFourFingers, YES, NO));
    assert(shortcutSectionWanted(ShortcutTriggerBoth, NO, YES));
    assert(shortcutSectionWanted(ShortcutTriggerBoth, YES, NO));
    assert(!shortcutSectionWanted(ShortcutTriggerBoth, NO, NO));
    assert(fourFingersCancelOpenMenu(ShortcutTriggerNone));
    assert(fourFingersCancelOpenMenu(ShortcutTriggerCommand));
    assert(!fourFingersCancelOpenMenu(ShortcutTriggerFourFingers));
    assert(!fourFingersCancelOpenMenu(ShortcutTriggerBoth));
    int savedTrigger=atomic_load(&g_settingShortcutTrigger);
    atomic_store(&g_settingShortcutTrigger, ShortcutTriggerFourFingers);
    atomic_store(&g_gestureActive, false);
    atomic_store(&g_gestureEnding, false);
    atomic_store(&g_fourFingerShortcutHeld, false);
    atomic_store(&g_fourFingerReleaseCandidateNanos, 0);
    ringTouchCallback(NULL, contacts, 3, 0, 0);
    assert(atomic_load(&g_gestureActive) && !atomic_load(&g_fourFingerShortcutHeld));
    uint64_t shortcutGeneration=atomic_load(&g_gestureGeneration);
    ringTouchCallback(NULL, contacts, 4, 0, 0);
    assert(atomic_load(&g_gestureActive) && !atomic_load(&g_gestureEnding));
    assert(atomic_load(&g_gestureGeneration)==shortcutGeneration);
    assert(atomic_load(&g_fourFingerShortcutHeld));
    ringTouchCallback(NULL, contacts, 3, 0, 0);
    assert(atomic_load(&g_fourFingerShortcutHeld) && atomic_load(&g_gestureActive));
    atomic_store(&g_settingShortcutTrigger, ShortcutTriggerCommand);
    ringTouchCallback(NULL, contacts, 4, 0, 0);
    assert(!atomic_load(&g_gestureActive) && !atomic_load(&g_fourFingerShortcutHeld));
    atomic_fetch_add(&g_gestureGeneration, 1);
    atomic_store(&g_gestureEnding, false);
    atomic_store(&g_fourFingerReleaseCandidateNanos, 0);
    ringTouchCallback(NULL, NULL, 0, 0, 0);
    showSystemCursorAfterGesture();
    atomic_store(&g_settingShortcutTrigger, savedTrigger);
    printf("Poseban meni: Cmd, četiri prsta, oba ili ništa; četvrti prst ne gasi gestu kad otvara meni.\n");
    preview.shapeControl.selectedSegment=0;
    [preview rebuild:5];
    RingEntry *arriving=preview.ring.entries.lastObject;
    NSImage *arrivingPicture=arriving.thumbnail;
    arriving.thumbnail=nil;
    [preview.ring updateCardLayersAnimated:NO refreshContents:YES];
    CGFloat iconWidth=NSWidth([preview.ring cardRectForIndex:4]);
    arriving.thumbnail=arrivingPicture;
    [preview.ring updateCardLayersAnimated:NO refreshContents:YES];
    assert(NSWidth([preview.ring cardRectForIndex:4])>iconWidth*1.5);
    printf("Novi thumbnail odmah dobija punu veličinu bez ponovnog otvaranja menija.\n");
    // Poređenje sa sredinom ekrana pre zajedničkog pomeranja grupe.
    for (NSInteger shape=0;shape<3;shape++) {
        preview.shapeControl.selectedSegment=shape;
        [preview rebuild:5];
        NSSize screen=preview.ring.bounds.size;
        CGFloat rx,ry;
        NSArray *rects=adaptiveCardLayout(preview.ring.entries,screen,&rx,&ry);
        NSMutableArray *visible=[NSMutableArray array];
        for (NSUInteger i=0;i<rects.count;i++)
            [visible addObject:[NSValue valueWithRect:visibleCardRect(preview.ring.entries[i],[rects[i] rectValue])]];
        NSPoint origin=NSMakePoint(screen.width/2,screen.height/2);
        NSPoint balanced=balancedHubPoint(preview.ring.entries,rects,screen);
        CGFloat before=hubGapVariation(visible,origin),after=hubGapVariation(visible,balanced);
        assert(after<=before+0.001);
        assert(hubClearance(rects,balanced)+0.001>=MIN(28.0,hubClearance(rects,origin)));
        printf("Balans, oblik %ld: odstupanje razmaka %.1f -> %.1f pt.\n",(long)shape,before,after);
    }
    const NSSize sizes[] = {{800,600},{1100,688},{1440,900},{1600,900},{1996,1248}};
    const NSUInteger counts[] = {1,2,3,4,5,6,7,8,9,10,12,16};
    for (NSUInteger sizeIndex=0;sizeIndex<5;sizeIndex++) {
        NSSize size=sizes[sizeIndex];
        [preview.window setContentSize:NSMakeSize(size.width,size.height+88)];
        for (NSInteger shape=0;shape<3;shape++) {
        preview.shapeControl.selectedSegment=shape;
        for (NSUInteger countIndex=0;countIndex<sizeof(counts)/sizeof(counts[0]);countIndex++) {
            NSUInteger count=counts[countIndex];
            [preview rebuild:count];
            // Bez snimka prostor pripada samo ikonici i nazivu.
            preview.ring.entries.lastObject.thumbnail=nil;
            preview.ring.layoutEntries=nil;
            [preview.ring updateCardLayersAnimated:NO refreshContents:YES];
            NSRect visibleBounds=visibleLayoutBounds(preview.ring.entries,preview.ring.layoutRects,preview.ring.anchorPoint);
            NSPoint remaining=centeredLayoutOffset(preview.ring.entries,preview.ring.layoutRects,preview.ring.anchorPoint,size);
            assert(fabs(remaining.x)<0.001 && fabs(remaining.y)<0.001);
            // Pet horizontalnih kartica mora imati jednake spoljne margine.
            if (shape==0 && count==5) {
                assert(fabs(NSMidX(visibleBounds)-size.width/2)<0.001);
                assert(fabs(NSMidY(visibleBounds)-size.height/2)<0.001);
            }
            for (NSUInteger i=0;i<count;i++) {
                NSRect rect=[preview.ring cardRectForIndex:i];
                assert(NSWidth(rect)>0 && NSHeight(rect)>0);
                NSImage *thumbnail=resolvedThumbnail(preview.ring.entries[i]);
                if (thumbnail) {
                    CGFloat aspect=(NSHeight(rect)-cardFooterHeight(NSWidth(rect)))/NSWidth(rect);
                    assert(fabs(aspect-thumbnail.size.height/thumbnail.size.width)<0.001);
                }
                CGFloat angle=atan2(NSMidY(rect)-preview.ring.anchorPoint.y,NSMidX(rect)-preview.ring.anchorPoint.x);
                assert(fabs(remainder(angle-cardScreenAngle(i,count),2*M_PI))<0.001);
                if (count>2) {
                    CGFloat step=fmod(cardScreenAngle(i,count)-cardScreenAngle((i+1)%count,count)+2*M_PI,2*M_PI);
                    if (!(step>0 && step<M_PI)) fprintf(stderr,"Raspored: %ld, broj: %lu, kartica: %lu, korak: %.3f\n",(long)shape,(unsigned long)count,(unsigned long)i,step);
                    assert(step>0 && step<M_PI);
                }
            }
            for (NSInteger selected=0;selected<(NSInteger)count;selected++) {
                preview.ring.selectedIndex=selected;
                assert([preview.ring.hubLayer animationForKey:@"pop"] != nil);
                CGFloat angle=cardScreenAngle(selected,count);
                // Stvarno kretanje i ograničavanje elipsom, uključujući uske rasporede.
                g_pointerX=g_pointerY=0;
                moveRingPointer(cos(angle)*0.2,sin(angle)*0.2,count);
                assert(pointerSelection(count,-1)==selected);
                NSRect visible[16];
                for (NSUInteger i=0;i<count;i++) {
                    NSRect rect=[preview.ring cardRectForIndex:i];
                    CALayer *layer=preview.ring.cardLayers[i];
                    CGFloat scale=i==(NSUInteger)selected?kSelectedCardScale:1;
                    visible[i]=NSMakeRect(layer.position.x-NSWidth(rect)*scale/2,
                                          layer.position.y-NSHeight(rect)*scale/2,
                                          NSWidth(rect)*scale,NSHeight(rect)*scale);
                    assert(NSMinX(visible[i])>=0 && NSMaxX(visible[i])<=size.width);
                    assert(NSMinY(visible[i])>=0 && NSMaxY(visible[i])<=size.height);
                    assert(fabs(layer.transform.m11-scale)<0.001);
                    assert(!NSIntersectsRect(visible[i],NSMakeRect(preview.ring.anchorPoint.x-kHubRadius,
                        preview.ring.anchorPoint.y-kHubRadius,kHubRadius*2,kHubRadius*2)));
                }
                for (NSUInteger i=0;i<count;i++) for (NSUInteger j=i+1;j<count;j++)
                    assert(!NSIntersectsRect(visible[i],visible[j]));
            }
            preview.ring.selectedIndex=-1;
            assert(!preview.ring.hubLayer.hidden && preview.ring.hubLayer.contents);
            assert([preview.ring.hubLayer animationForKey:@"pop"] != nil);
            [preview.ring updateHubAnimated:NO];
            assert([preview.ring.hubLayer animationForKey:@"pop"] != nil);
            assert(fabs(preview.ring.hubLayer.shadowOpacity-0.42)<0.001);
            assert(preview.ring.hubLayer.shadowPath!=NULL);
            for (CALayer *layer in preview.ring.cardLayers) {
                assert(fabs(layer.transform.m11-1)<0.001);
                assert(layer.shadowOpacity==0);
            }
        }
        }
        printf("%.0f×%.0f: horizontalni, uspravni i mešoviti snimci; 1-16 kartica, proporcionalni snimci i tačni smerovi izbora, svaki izbor bez preklapanja.\n",size.width,size.height);
    }
}

// Provera stvarnih asinhronih završetaka, bez zamene stanja ručno.
static void waitForInputCondition(BOOL (^condition)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
    while (!condition() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(condition());
}

static void verifyInputLifecycle(LayoutPreview *preview) {
    g_windowEntries=preview.ring.entries;
    atomic_store(&g_windowEntryCount,(int)g_windowEntries.count);
    g_windowScanQueue=dispatch_queue_create("touchpad.test.scan",DISPATCH_QUEUE_SERIAL);
    atomic_store(&g_isScanning,true); // Test ne pokreće inventar stvarnih prozora.
    MTTouch contacts[4]={0};
    for (int i=0;i<4;i++) {
        contacts[i].state=MTTouchStateTouching;
        contacts[i].normalizedVector.position.x=0.4;
        contacts[i].normalizedVector.position.y=0.6;
    }
    for (int cycle=0;cycle<12;cycle++) {
        ringTouchCallback(NULL,contacts,3,0,0);
        waitForInputCondition(^BOOL{ return atomic_load(&g_ringOverlayVisible); });
        uint64_t previous=atomic_load(&g_gestureGeneration);
        ringTouchCallback(NULL,contacts,cycle%2+1,0,0);
        // Povratak pre obrade glavnog reda ili nakon stvarnog zatvaranja.
        if (cycle%3==0)
            waitForInputCondition(^BOOL{ return !atomic_load(&g_gestureActive); });
        ringTouchCallback(NULL,contacts,3,0,0);
        waitForInputCondition(^BOOL{
            return atomic_load(&g_gestureGeneration)>previous && atomic_load(&g_ringOverlayVisible) &&
                !atomic_load(&g_gestureEnding) && atomic_load(&g_ringShownGeneration)==atomic_load(&g_gestureGeneration);
        });
        assert(g_selectedIndex==-1 && g_pointerX==0 && g_pointerY==0);
        // Kratak četvrti kontakt takođe ne zahteva potpuno podizanje.
        previous=atomic_load(&g_gestureGeneration);
        ringTouchCallback(NULL,contacts,4,0,0);
        ringTouchCallback(NULL,contacts,3,0,0);
        waitForInputCondition(^BOOL{
            return atomic_load(&g_gestureGeneration)>previous+1 && atomic_load(&g_ringOverlayVisible) &&
                !atomic_load(&g_gestureEnding);
        });
        ringTouchCallback(NULL,NULL,0,0,0);
        waitForInputCondition(^BOOL{ return !atomic_load(&g_gestureActive) && !atomic_load(&g_ringOverlayVisible); });
    }
    NSMutableArray *many=[NSMutableArray array];
    for (int i=0;i<37;i++) {
        RingEntry *entry=[RingEntry new]; entry.windowTitle=[NSString stringWithFormat:@"Tab %d",i];
        entry.icon=[NSImage imageNamed:NSImageNameFolder]; [many addObject:entry];
    }
    g_windowEntries=many;
    atomic_store(&g_windowEntryCount,37);
    ringTouchCallback(NULL,contacts,3,0,0);
    waitForInputCondition(^BOOL{ return atomic_load(&g_ringOverlayVisible); });
    assert(g_windowEntries.count==10 && g_standardRingEntries.count==37 && !g_ringPageLabel.hidden);
    changeRingPage(1);
    assert(g_ringPage==1 && g_windowEntries.firstObject==many[10] && g_selectedIndex==-1);
    assert(!atomic_load(&g_quickTapEligible));
    setCommandShortcutMode(YES); assert(g_commandShortcutMode && g_ringPageLabel.hidden);
    setCommandShortcutMode(NO); assert(!g_commandShortcutMode && !g_ringPageLabel.hidden);
    changeRingPage(1); changeRingPage(1); changeRingPage(1); changeRingPage(1);
    assert(g_ringPage==3 && g_windowEntries.count==7 && g_windowEntries.firstObject==many[30]);
    g_selectedIndex=0;
    ringTouchCallback(NULL,NULL,0,0,0);
    waitForInputCondition(^BOOL{ return !atomic_load(&g_gestureActive) && !atomic_load(&g_ringOverlayVisible); });
    assert(g_windowEntries.count==37 && g_standardRingEntries==nil);
    printf("Stranice u stvarnom meniju: 37 kartica, reset izbora, Cmd i zatvaranje prolaze.\n");
    printf("Stvarni asinhroni tok: 12 ciklusa, brz/spor povratak sa 1/2 prsta i 4 -> 3 prolaze.\n");
}

static void verifyDiagnosticLogging(void) {
    char tempPath[]="/tmp/touchpad-log-test-XXXXXX";
    assert(mkdtemp(tempPath));
    NSString *directory=[NSString stringWithUTF8String:tempPath];
    startDiagnosticLoggingAt(directory,1024);
    assert(g_diagnosticQueue && g_diagnosticFD>=0);
    dispatch_apply(40,dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^(size_t index) {
        diagnosticEvent(@"test_event",@{@"index":@(index)});
    });
    dispatch_sync(g_diagnosticQueue, ^{ fsync(g_diagnosticFD); });
    for (NSString *name in @[@"events.jsonl",@"events.jsonl.previous"]) {
        NSString *path=[directory stringByAppendingPathComponent:name];
        NSString *contents=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        assert(contents.length);
        assert([NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileSize<=1024);
        for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
            if (!line.length) continue;
            NSDictionary *record=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            assert([record[@"event"] isEqualToString:@"test_event"]);
            assert(record[@"time"] && record[@"uptime"] && record[@"pid"] && record[@"generation"] && record[@"fingers"]);
        }
    }
    dispatch_sync(g_diagnosticQueue, ^{ close(g_diagnosticFD); g_diagnosticFD=-1; });
    printf("Dijagnostika: paralelni zapisi, JSON i rotacija prolaze. Putanja: %s\n",tempPath);
}

static NSUInteger testSystemConflicts;
static NSUInteger testSystemConflictReader(void) { return testSystemConflicts; }

static void verifySystemGestureGate(NSString *renderPath) {
    NSDictionary *offDock = @{@"showMissionControlGestureEnabled":@NO, @"showAppExposeGestureEnabled":@NO};
    assert(conflictsForTrackpadPreferences(@{}, @{}, @{}) == 0);
    assert(conflictsForTrackpadPreferences(@{@"TrackpadThreeFingerDrag":@YES}, @{}, @{}) == SystemGestureDrag);
    assert(conflictsForTrackpadPreferences(@{@"TrackpadThreeFingerHorizSwipeGesture":@2}, @{}, @{}) == SystemGestureSpaces);
    assert(conflictsForTrackpadPreferences(@{@"TrackpadThreeFingerHorizSwipeGesture":@1}, @{}, @{}) == SystemGesturePages);
    assert(conflictsForTrackpadPreferences(@{@"TrackpadThreeFingerVertSwipeGesture":@2}, @{}, @{}) == SystemGestureExpose);
    assert(conflictsForTrackpadPreferences(@{@"TrackpadThreeFingerVertSwipeGesture":@2}, offDock, @{}) == 0);
    assert(conflictsForTrackpadPreferences(@{@"TrackpadThreeFingerVertSwipeGesture":@2},
        @{@"showMissionControlGestureEnabled":@NO, @"showAppExposeGestureEnabled":@YES}, @{}) == SystemGestureExpose);
    assert(conflictsForTrackpadPreferences(@{}, @{},
        @{@"com.apple.trackpad.threeFingerHorizSwipeGesture":@2}) == SystemGestureSpaces);
    assert(conflictsForTrackpadPreferences(@{@"TrackpadThreeFingerHorizSwipeGesture":@0}, @{},
        @{@"com.apple.trackpad.threeFingerHorizSwipeGesture":@2}) == 0);
    assert(conflictsForTrackpadPreferences(@{@"TrackpadThreeFingerHorizSwipeGesture":@0,
        @"TrackpadThreeFingerVertSwipeGesture":@0, @"TrackpadFourFingerHorizSwipeGesture":@2,
        @"TrackpadFourFingerVertSwipeGesture":@2}, @{}, @{}) == 0);

    g_systemGestureConflictReader = testSystemConflictReader;
    testSystemConflicts = SystemGestureDrag | SystemGestureSpaces | SystemGestureExpose | SystemGesturePages;
    atomic_store(&g_systemGestureConflicts, testSystemConflicts);
    MTTouch contacts[3] = {0};
    for (int i=0; i<3; i++) contacts[i].state=MTTouchStateTouching;
    ringTouchCallback(NULL, contacts, 3, 0, 0);
    assert(!atomic_load(&g_gestureActive) && !atomic_load(&g_ringOverlayVisible));
    assert(!atomic_load(&g_systemCursorHidden) && !atomic_load(&g_scrollSuppressionActive));
    beginTouchGesture(NULL, 0.5, 0.5);
    assert(!atomic_load(&g_gestureActive));

    g_windowScanQueue=dispatch_queue_create("touchpad.test.scan",DISPATCH_QUEUE_SERIAL);
    atomic_store(&g_isScanning,true);
    CGEventRef cursor=CGEventCreate(NULL);
    g_cursorAtGestureStart=CGEventGetLocation(cursor);
    CFRelease(cursor);
    atomic_store(&g_gestureActive,true);
    atomic_store(&g_mouseGestureActive,true);
    uint64_t generation=atomic_fetch_add(&g_gestureGeneration,1)+1;
    showRing(generation);
    assert(!atomic_load(&g_gestureActive) && !atomic_load(&g_mouseGestureActive));
    assert(!atomic_load(&g_gestureEnding) && !atomic_load(&g_ringOverlayVisible));
    assert(atomic_load(&g_gestureGeneration)!=generation);
    finishGesture(generation,0); // A queued lift from before the block is invalid.
    assert(!atomic_load(&g_gestureActive));

    g_settingsMenu=[SettingsMenu new];
    [g_settingsMenu presentGestureConflict:nil];
    assert(g_settingsMenu.gestureConflictWindow.isVisible);
    if (renderPath) {
        NSView *content=g_settingsMenu.gestureConflictWindow.contentView;
        [content layoutSubtreeIfNeeded];
        NSBitmapImageRep *bitmap=[content bitmapImageRepForCachingDisplayInRect:content.bounds];
        [content cacheDisplayInRect:content.bounds toBitmapImageRep:bitmap];
        assert([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:renderPath atomically:YES]);
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--preview-system-gestures"]) return;
    [g_settingsMenu dismissGestureConflict:nil];
    assert(threeFingerSystemGesturesOn()); // Dismissing the notice cannot bypass setup.
    testSystemConflicts=0;
    refreshSystemGestureConflicts();
    assert(!threeFingerSystemGesturesOn() && !g_settingsMenu.gestureConflictWindow.isVisible);
    g_systemGestureConflictReader=currentSystemGestureConflicts;
    printf("Sistemski gestovi: konflikt blokira dodir i miš, stari izbor se odbacuje, odlaganje ne otključava, promena podešavanja otključava meni.\n");
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSArray<NSString *> *args=NSProcessInfo.processInfo.arguments;
        NSString *(^argument)(NSString *)=^NSString *(NSString *flag) {
            NSUInteger i=[args indexOfObject:flag];
            return i!=NSNotFound && i+1<args.count ? args[i+1] : nil;
        };
        if ([args containsObject:@"--verify-system-gestures"] || [args containsObject:@"--preview-system-gestures"]) {
            verifySystemGestureGate(argument(@"--render-gesture-warning"));
            if ([args containsObject:@"--preview-system-gestures"]) [NSApp run];
            return 0;
        }
        if ([args containsObject:@"--no-titles"]) atomic_store(&g_settingCardTitles,CardTitlesNone);
        CGFloat width=argument(@"--width") ? argument(@"--width").doubleValue : 1100;
        CGFloat height=argument(@"--height") ? argument(@"--height").doubleValue : width/1.6;
        LayoutPreview *preview=[LayoutPreview new];
        NSString *referencePath=argument(@"--reference") ?: [NSBundle.mainBundle pathForResource:@"layout-reference" ofType:@"png"];
        if (referencePath) preview.reference=[[NSImage alloc] initWithContentsOfFile:referencePath];
        preview.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(80,70,width,height+88)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        preview.window.title=@"Touchpad Switcher: pregled rasporeda";
        preview.window.delegate=preview;
        preview.window.minSize=NSMakeSize(800,600);
        preview.ring=[[PreviewRingView alloc] initWithFrame:NSMakeRect(0,0,width,height)];
        preview.ring.wantsLayer=YES;
        preview.ring.layer.backgroundColor=[NSColor colorWithCalibratedWhite:0.065 alpha:1].CGColor;
        [preview.window.contentView addSubview:preview.ring];
        NSStackView *controls=[NSStackView stackViewWithViews:@[]];
        controls.orientation=NSUserInterfaceLayoutOrientationHorizontal;
        controls.spacing=16;
        controls.frame=NSMakeRect(20,height+25,width-40,30);
        controls.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
        preview.countControl=[NSSegmentedControl segmentedControlWithLabels:@[@"3",@"4",@"5",@"6",@"7",@"8",@"12"]
            trackingMode:NSSegmentSwitchTrackingSelectOne target:preview action:@selector(countChanged:)];
        preview.countControl.selectedSegment=2;
        [controls addArrangedSubview:preview.countControl];
        NSSegmentedControl *ratio=[NSSegmentedControl segmentedControlWithLabels:@[@"16:10",@"16:9",@"4:3"]
            trackingMode:NSSegmentSwitchTrackingSelectOne target:preview action:@selector(ratioChanged:)];
        ratio.selectedSegment=0;
        [controls addArrangedSubview:ratio];
        preview.selection=[NSSlider sliderWithValue:0 minValue:0 maxValue:5 target:preview action:@selector(choose:)];
        [preview.selection.widthAnchor constraintEqualToConstant:150].active=YES;
        [controls addArrangedSubview:preview.selection];
        preview.selectionLabel=[NSTextField labelWithString:@"Bez izbora"];
        [preview.selectionLabel.widthAnchor constraintEqualToConstant:80].active=YES;
        [controls addArrangedSubview:preview.selectionLabel];
        preview.guides=[NSButton checkboxWithTitle:@"Prsten i uglovi" target:preview action:@selector(toggleGuides:)];
        preview.guides.state=NSControlStateValueOn;
        preview.ring.showGuides=YES;
        [controls addArrangedSubview:preview.guides];
        [preview.window.contentView addSubview:controls];
        preview.shapeControl=[NSSegmentedControl segmentedControlWithLabels:@[@"Horizontalni",@"Uspravni",@"Mešoviti"]
            trackingMode:NSSegmentSwitchTrackingSelectOne target:preview action:@selector(shapeChanged:)];
        preview.shapeControl.frame=NSMakeRect(20,height+58,340,24);
        preview.shapeControl.autoresizingMask=NSViewMinYMargin;
        NSString *shape=argument(@"--shape");
        preview.shapeControl.selectedSegment=[shape isEqualToString:@"portrait"] ? 1 : ([shape isEqualToString:@"mixed"] ? 2 : 0);
        [preview.window.contentView addSubview:preview.shapeControl];
        __weak LayoutPreview *weakPreview=preview;
        preview.ring.selectionChanged=^(NSInteger selection) {
            weakPreview.selection.doubleValue=selection+1;
            weakPreview.selectionLabel.stringValue=selection<0?@"Bez izbora":[NSString stringWithFormat:@"Izbor: %ld",selection+1];
        };
        [preview rebuild:argument(@"--count") ? argument(@"--count").integerValue : 5];
        if ([args containsObject:@"--shortcuts"]) {
            preview.ring.entries=commandShortcutEntries();
            preview.ring.layoutEntries=nil;
            [preview.ring updateCardLayersAnimated:NO refreshContents:YES];
            [preview.ring updateHubAnimated:NO];
        }
        preview.ring.selectedIndex=argument(@"--selected") ? argument(@"--selected").integerValue : -1;
        if ([args containsObject:@"--verify-logs"]) { verifyDiagnosticLogging(); return 0; }
        if ([args containsObject:@"--verify-input"]) { verifyInputLifecycle(preview); return 0; }
        if ([args containsObject:@"--verify"]) { verifyPreview(preview); return 0; }
        NSString *output=argument(@"--render");
        if (output) { renderPreview(preview.ring,output); return 0; }
        if ([args containsObject:@"--test-hide-windows"]) {
            NSButton *desktopTest=[NSButton buttonWithTitle:@"Spusti sve prozore" target:preview.ring action:@selector(testDesktop:)];
            desktopTest.frame=NSMakeRect(20,20,160,32);
            [preview.window.contentView addSubview:desktopTest];
        }
        [preview.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
    }
    return 0;
}
