``` 

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <UserNotifications/UserNotifications.h>

//──────────────────────── CONFIG ────────────────────────
static NSString *const kOpenRouterAPIKey =
  @"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";

//──────────────────────── Globals ───────────────────────
static pid_t          gTargetPID   = 0;

static NSPanel       *gHUDPanel    = nil;
static NSTextField   *gHUDField    = nil;

static NSPanel       *gAnswerWin   = nil;
static NSScrollView  *gScroll      = nil;
static NSTextView    *gTextView    = nil;

static NSString      *gStoredGem   = nil;   // only touched on main thread

// helper
static inline void onMain(void (^blk)(void)) {
    if (NSThread.isMainThread) blk();
    else dispatch_async(dispatch_get_main_queue(), blk);
}

//───────────────────── HUD (top-right) ──────────────────
static void showHUD(NSString *glyph, NSTimeInterval sec) {
    onMain(^{
        if (!gHUDPanel) {
            NSScreen *s = NSScreen.mainScreen;
            NSRect vf = s.visibleFrame;
            NSRect fr = NSMakeRect(NSMaxX(vf)-60, NSMaxY(vf)-60, 44, 44);

            gHUDPanel = [[NSPanel alloc] initWithContentRect:fr
                                                   styleMask:NSWindowStyleMaskHUDWindow |
                                                              NSWindowStyleMaskNonactivatingPanel
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
            gHUDPanel.level              = CGShieldingWindowLevel();
            gHUDPanel.backgroundColor    = NSColor.clearColor;
            gHUDPanel.opaque             = NO;
            gHUDPanel.ignoresMouseEvents = YES;
            gHUDPanel.collectionBehavior =
                NSWindowCollectionBehaviorCanJoinAllSpaces |
                NSWindowCollectionBehaviorFullScreenAuxiliary;

            gHUDField = [[NSTextField alloc] initWithFrame:gHUDPanel.contentView.bounds];
            gHUDField.editable = gHUDField.bordered = gHUDField.drawsBackground = NO;
            gHUDField.alignment = NSTextAlignmentCenter;
            gHUDField.font      = [NSFont systemFontOfSize:30];
            gHUDField.textColor = NSColor.labelColor;
            gHUDField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [gHUDPanel.contentView addSubview:gHUDField];
        }
        gHUDField.stringValue = glyph;
        [gHUDPanel orderFront:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [gHUDPanel orderOut:nil]; });
    });
}

//───────────────────── Answer panel ─────────────────────
static void createAnswerWindow(void) {
    if (gAnswerWin) return;

    onMain(^{
        NSScreen *s = NSScreen.mainScreen;
        NSRect vf   = s.visibleFrame;
        CGFloat W = 320, H = 180;
        NSRect fr = NSMakeRect(NSMidX(vf)-W/2, NSMidY(vf)-H/2, W, H);

        gAnswerWin = [[NSPanel alloc] initWithContentRect:fr
                                                 styleMask:NSWindowStyleMaskTitled |
                                                            NSWindowStyleMaskResizable |
                                                            NSWindowStyleMaskHUDWindow |
                                                            NSWindowStyleMaskNonactivatingPanel
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
        gAnswerWin.level           = CGShieldingWindowLevel();
        gAnswerWin.backgroundColor = NSColor.windowBackgroundColor;
        gAnswerWin.opaque          = NO;
        gAnswerWin.hasShadow       = YES;
        gAnswerWin.collectionBehavior =
            NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorFullScreenAuxiliary;
        gAnswerWin.movableByWindowBackground = YES;
        gAnswerWin.releasedWhenClosed = NO;

        gAnswerWin.contentView.wantsLayer = YES;
        gAnswerWin.contentView.layer.borderWidth  = 1;
        gAnswerWin.contentView.layer.borderColor  = NSColo