#import <Cocoa/Cocoa.h>
// Geometrijska ikonica prati kartice kružnog menija i pokret sa tri prsta.
int main(int argc,const char **argv) {
    @autoreleasepool {
        if (argc!=2) return 1;
        NSString *output=[NSString stringWithUTF8String:argv[1]];
        [NSFileManager.defaultManager createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil];
        NSImage *icon=[NSImage imageWithSize:NSMakeSize(1024,1024) flipped:NO drawingHandler:^BOOL(NSRect bounds) {
            NSBezierPath *background=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds,32,32) xRadius:200 yRadius:200];
            NSGradient *gradient=[[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.12 green:0.44 blue:0.94 alpha:1]
                endingColor:[NSColor colorWithSRGBRed:0.20 green:0.12 blue:0.58 alpha:1]];
            [gradient drawInBezierPath:background angle:70];
            const NSRect cards[]={{368,706,288,170},{120,456,248,156},{656,456,248,156},{234,196,240,150},{550,196,240,150}};
            for (int i=0;i<5;i++) {
                [[NSColor colorWithWhite:1 alpha:i==0?1:0.90] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:cards[i] xRadius:24 yRadius:24] fill];
                [[NSColor colorWithSRGBRed:0.24 green:0.34 blue:0.74 alpha:0.35] setFill];
                NSRect line=NSMakeRect(cards[i].origin.x+22,cards[i].origin.y+cards[i].size.height-34,cards[i].size.width-44,9);
                [[NSBezierPath bezierPathWithRoundedRect:line xRadius:4 yRadius:4] fill];
            }
            [[NSColor colorWithWhite:1 alpha:0.18] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(412,418,200,200)] fill];
            [[NSColor whiteColor] setFill];
            for (int i=0;i<3;i++) {
                NSRect finger=NSMakeRect(457+i*40,464,28,i==1?108:90);
                [[NSBezierPath bezierPathWithRoundedRect:finger xRadius:14 yRadius:14] fill];
            }
            return YES;
        }];
        for (int size=16;size<=512;size*=2) for (int retina=1;retina<=2;retina++) {
            int pixels=size*retina;
            NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
            [icon drawInRect:NSMakeRect(0,0,pixels,pixels)];
            [NSGraphicsContext restoreGraphicsState];
            NSString *name=[NSString stringWithFormat:@"icon_%dx%d%@.png",size,size,retina==2?@"@2x":@""];
            [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:name] atomically:YES];
        }
    }
    return 0;
}
