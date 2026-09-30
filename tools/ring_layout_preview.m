// Pregled koristi stvarni RingView i isti proračun rasporeda kao aplikacija.
#define main ring_application_main
#include "../touchpad_ring_test.m"
#undef main
#include <assert.h>

@interface PreviewRingView : RingView
@property BOOL showGuides;
@property(copy) void (^selectionChanged)(NSInteger);
@end
@implementation PreviewRingView
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
    // Jedan prazan frejm mora osloboditi novu gestu, bez daljih callbackova.
    BOOL waiting = NO;
    assert(suppressTouchFrameAfterFourFingers(4, &waiting) && waiting);
    assert(suppressTouchFrameAfterFourFingers(3, &waiting) && waiting);
    assert(suppressTouchFrameAfterFourFingers(1, &waiting) && waiting);
    assert(suppressTouchFrameAfterFourFingers(0, &waiting) && !waiting);
    assert(!suppressTouchFrameAfterFourFingers(3, &waiting));
    for (int repeat = 0; repeat < 20; repeat++) {
        assert(suppressTouchFrameAfterFourFingers(5, &waiting));
        assert(suppressTouchFrameAfterFourFingers(0, &waiting) && !waiting);
        assert(!suppressTouchFrameAfterFourFingers(3, &waiting));
    }
    printf("Četiri prsta: oporavak nakon jednog praznog frejma i 20 ponavljanja prolaze.\n");
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
    const NSSize sizes[] = {{800,600},{1100,688},{1440,900},{1600,900},{1996,1248}};
    const NSUInteger counts[] = {1,2,3,4,5,6,7,8,12,16};
    for (NSUInteger sizeIndex=0;sizeIndex<5;sizeIndex++) {
        NSSize size=sizes[sizeIndex];
        [preview.window setContentSize:NSMakeSize(size.width,size.height+88)];
        for (NSInteger shape=0;shape<3;shape++) {
        preview.shapeControl.selectedSegment=shape;
        for (NSUInteger countIndex=0;countIndex<10;countIndex++) {
            NSUInteger count=counts[countIndex];
            [preview rebuild:count];
            // Bez snimka prostor pripada samo ikonici i nazivu.
            preview.ring.entries.lastObject.thumbnail=nil;
            preview.ring.layoutEntries=nil;
            [preview.ring updateCardLayersAnimated:NO refreshContents:YES];
            NSPoint originalHub=NSMakePoint(size.width/2,size.height/2);
            assert(hubClearance(preview.ring.layoutRects,preview.ring.anchorPoint)+0.001 >=
                   hubClearance(preview.ring.layoutRects,originalHub));
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
                g_pointerX=cos(angle)*0.5;g_pointerY=sin(angle)*0.5;
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
            for (CALayer *layer in preview.ring.cardLayers) {
                assert(fabs(layer.transform.m11-1)<0.001);
                assert(layer.shadowOpacity==0);
            }
        }
        }
        printf("%.0f×%.0f: horizontalni, uspravni i mešoviti snimci; 1-16 kartica, proporcionalni snimci i tačni smerovi izbora, svaki izbor bez preklapanja.\n",size.width,size.height);
    }
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
        preview.ring.selectedIndex=argument(@"--selected") ? argument(@"--selected").integerValue : -1;
        if ([args containsObject:@"--verify"]) { verifyPreview(preview); return 0; }
        NSString *output=argument(@"--render");
        if (output) { renderPreview(preview.ring,output); return 0; }
        [preview.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
    }
    return 0;
}
