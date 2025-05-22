
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <UserNotifications/UserNotifications.h>

#pragma mark -- Config
static NSString *const kOpenRouterAPIKey =
  @"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";

#pragma mark -- Globals (main-thread only after init)
static pid_t          gTargetPID   = 0;

static NSPanel       *gHUD         = nil;   // permanent panel, toggled with ⌘ A
static NSTextField   *gLabel       = nil;

static NSString      *gShortAns    = nil;   // what is visible in HUD
static NSString      *gFullAns     = nil;   // full reply (used for clipboard)
static BOOL           gHUDVisible  = NO;

static inline void onMain(void (^blk)(void)) {
    if (NSThread.isMainThread) blk();
    else dispatch_async(dispatch_get_main_queue(), blk);
}

#pragma mark -- HUD helpers
static void ensureHUD(void) {
    if (gHUD) return;
    NSScreen *s = NSScreen.mainScreen;
    NSRect   vf = s.visibleFrame;
    NSRect   fr = NSMakeRect(NSMaxX(vf)-160, NSMaxY(vf)-64, 150, 44);

    gHUD = [[NSPanel alloc] initWithContentRect:fr
                                       styleMask:NSWindowStyleMaskHUDWindow |
                                                  NSWindowStyleMaskNonactivatingPanel
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    gHUD.level              = CGShieldingWindowLevel();
    gHUD.backgroundColor    = NSColor.clearColor;
    gHUD.opaque             = NO;
    gHUD.ignoresMouseEvents = YES;
    gHUD.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary;

    gLabel = [[NSTextField alloc] initWithFrame:gHUD.contentView.bounds];
    gLabel.editable = gLabel.bordered = gLabel.drawsBackground = NO;
    gLabel.alignment = NSTextAlignmentCenter;
    gLabel.font      = [NSFont boldSystemFontOfSize:24];
    gLabel.textColor = NSColor.systemYellowColor;
    gLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [gHUD.contentView addSubview:gLabel];
}

static void showHUDText(NSString *txt) {
    onMain(^{
        ensureHUD();
        gShortAns  = txt;
        gLabel.stringValue = txt;
        if (!gHUDVisible) {
            [gHUD orderFront:nil];
            gHUDVisible = YES;
        }
    });
}

static void toggleHUD(void) {
    onMain(^{
        ensureHUD();
        if (gHUDVisible) { [gHUD orderOut:nil]; gHUDVisible = NO; }
        else            { gLabel.stringValue = gShortAns ?: @"…"; [gHUD orderFront:nil]; gHUDVisible = YES; }
    });
}

static void flashIcon(NSString *emoji, NSTimeInterval sec) {
    onMain(^{
        ensureHUD();
        gLabel.stringValue = emoji;
        if (!gHUDVisible) [gHUD orderFront:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gShortAns && gHUDVisible) gLabel.stringValue = gShortAns;
            else if (!gHUDVisible) [gHUD orderOut:nil];
        });
    });
}

#pragma mark -- Clipboard helper
static void copyToClipboard(NSString *text) {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
}

#pragma mark -- Gemini networking
static void sendToGemini(NSDictionary *body) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *req =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://openrouter.ai/api/v1/chat/completions"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:kOpenRouterAPIKey]
           forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = json;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                   completionHandler:^(NSData *d, NSURLResponse *_, NSError *err)
    {
        NSString *ans = @"";
        if (d && !err) {
            NSDictionary *r = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            NSArray *c = r[@"choices"]; if (c.count) ans = c[0][@"message"][@"content"] ?: @"";
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            // trim giant replies
            NSString *full = (ans.length > 20000) ? [ans substringToIndex:20000] : ans;
            gFullAns = [full stringByTrimmingCharactersInSet:
                               NSCharacterSet.whitespaceAndNewlineCharacterSet];

            // derive a short token (first non-blank line, ≤ 12 chars)
            NSString *firstLine = @"";
            for (NSString *ln in [gFullAns componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet newlineCharacterSet]]) {
                NSString *t = [ln stringByTrimmingCharactersInSet:
                               NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (t.length) { firstLine = t; break; }
            }
            if (firstLine.length > 12) firstLine = [firstLine substringToIndex:12];
            showHUDText(firstLine.length ? firstLine : @"✓");

            // copy whole answer on every FRQ (heuristic: > 15 chars or multi-line)
            if (gFullAns.length > 15 || [gFullAns containsString:@"\n"]) copyToClipboard(gFullAns);
        });
    }] resume];
}

#pragma mark -- CMD G  (screenshot routine unchanged)
static void sendScreenshot(void) {
    if (gTargetPID == 0) {
        gTargetPID = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        flashIcon(@"🔒", 0.8);
    }
    flashIcon(@"📧", 0.8);

    CFArrayRef arr = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    uint32_t winID = 0;
    for (NSDictionary *d in (__bridge NSArray *)arr) {
        if ([d[(id)kCGWindowOwnerPID] intValue] == gTargetPID) {
            winID = [d[(id)kCGWindowNumber] unsignedIntValue]; break;
        }
    }
    CFRelease(arr);
    if (!winID) { flashIcon(@"❌", 1.0); return; }

    CGImageRef shot = CGWindowListCreateImage(
        CGRectNull, kCGWindowListOptionIncludingWindow, winID,
        kCGWindowImageBoundsIgnoreFraming | kCGWindowImageShouldBeOpaque);
    if (!shot) { flashIcon(@"❌", 1.0); return; }

    NSImage *ni = [[NSImage alloc] initWithCGImage:shot size:NSZeroSize];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard writeObjects:@[ni]];

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:shot];
    CGImageRelease(shot);
    NSString *b64 = [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                     base64EncodedStringWithOptions:0];

    NSDictionary *tp = @{@"type":@"text",
                         @"text":@"Answer the questions shown. MCQs: A/B/C/D. FRQs: brief steps."};
    NSDictionary *ip = @{@"type":@"image_url",
                         @"image_url":@{@"url":[@"data:image/png;base64," stringByAppendingString:b64]}};
    NSDictionary *msg  = @{@"role":@"user", @"content":@[tp, ip]};
    NSDictionary *body = @{@"model":@"google/gemini-2.5-pro-preview", @"messages":@[msg]};

    sendToGemini(body);
}

#pragma mark -- CMD T  (prompt)
static void promptGemini(void) {
    onMain(^{
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Enter prompt:";
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
        a.accessoryView = tf;
        [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
        if ([a runModal] != NSAlertFirstButtonReturn) return;

        flashIcon(@"✉️", 0.8);

        NSDictionary *tp = @{@"type":@"text", @"text":tf.stringValue};
        NSDictionary *msg = @{@"role":@"user", @"content":@[tp]};
        NSDictionary *body = @{@"model":@"google/gemini-2.5-pro-preview", @"messages":@[msg]};
        sendToGemini(body);
    });
}

#pragma mark -- Event tap
static CGEventRef tapCb(CGEventTapProxy, CGEventType t, CGEventRef e, void *) {
    if (t == kCGEventKeyDown) {
        CGKeyCode kc = (CGKeyCode)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
        CGEventFlags fl = CGEventGetFlags(e);
        if (fl & kCGEventFlagMaskCommand) {
            if (kc == kVK_ANSI_G) { sendScreenshot();  return NULL; }
            if (kc == kVK_ANSI_T) { promptGemini();    return NULL; }
            if (kc == kVK_ANSI_A) { toggleHUD();       return NULL; }
        }
    }
    return e;
}

#pragma mark -- Constructor
__attribute__((constructor))
static void bootstrap(void) {
    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:UNAuthorizationOptionAlert |
                                         UNAuthorizationOptionSound
                      completionHandler:^(__unused BOOL ok, __unused NSError *err) {}];

    CGEventMask m = CGEventMaskBit(kCGEventKeyDown);
    CFMachPortRef tap = CGEventTapCreate(kCGAnnotatedSessionEventTap,
                                         kCGHeadInsertEventTap,
                                         kCGEventTapOptionDefault,
                                         m, tapCb, NULL);
    if (!tap) return;
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
}