#import "EvangelionClock.h"
#import <WebKit/WebKit.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>

static NSString * const evangelionClockModule = @"de.pascal-wagler.evangelion-clock";

// The wabe daemon's loopback port, WABE_TCP_PORT in wabe.h. The screensaver host's sandbox refuses
// the daemon's unix socket but allows loopback TCP.
static const uint16_t wabePort = 7465;

@implementation EvangelionClock {
    WebView *_page;
    dispatch_source_t _wabe;  // the daemon connection; nil between attempts
    NSMutableData *_unread;
}

- (id)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if (!(self = [super initWithFrame:frame isPreview:isPreview])) return nil;

    // legacyScreenSaver keeps a dismissed saver alive and animating, still reading the daemon, so
    // the host has to go when the screensaver stops.
    if (!isPreview) {
        [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"com.apple.screensaver.willstop"
                                                                   object:nil
                                                                    queue:NSOperationQueue.mainQueue
                                                               usingBlock:^(NSNotification *note) {
            exit(0);
        }];
    }

    // Preference Defaults
    ScreenSaverDefaults *defaults;
    defaults = [ScreenSaverDefaults defaultsForModuleWithName:evangelionClockModule];

    [defaults registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
        @"0", @"screenDisplayOption", // Default to show only on primary display
        nil]];
    [defaults registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
        @"0", @"styleOption", // Default to use normal style
        nil]];

    NSString *style = @"/Webview/style-normal-3d.html";
    switch ([defaults integerForKey:@"styleOption"]) {
        case 0:
            style = @"/Webview/style-normal-3d.html";
            break;
        case 1:
            style = @"/Webview/style-red-3d.html";
            break;
        case 2:
            style = @"/Webview/style-normal.html";
            break;
        case 3:
            style = @"/Webview/style-red.html";
            break;
        default:
            style = @"/Webview/style-normal-3d.html";
            break;
    }

    // Webview
    NSURL* indexHTMLDocumentURL = [NSURL URLWithString:[[[NSURL fileURLWithPath:[[NSBundle bundleForClass:self.class].resourcePath stringByAppendingString:style] isDirectory:NO] description] stringByAppendingFormat:@"?screensaver=1%@", self.isPreview ? @"&is_preview=1" : @""]];

    WebView* webView = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    webView.drawsBackground = NO; // Avoids a "white flash" just before the index.html file has loaded
    [webView.mainFrame loadRequest:[NSURLRequest requestWithURL:indexHTMLDocumentURL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:30.0]];

    // Show on screens based on preferences
    NSArray* screens = [NSScreen screens];
    NSScreen* primaryScreen = [screens objectAtIndex:0];

    switch ([defaults integerForKey:@"screenDisplayOption"]) {
        // Primary screen (System Preferences > Displays).
        // The screen the menubar is shown on under 'arrangement'
        case 0:
            if ((primaryScreen.frame.origin.x == frame.origin.x) || isPreview) {
                [self show:webView];
            }
            break;
        // Last Focussed Screen
        // This _sometimes_ results in nothing being shown when previewing in system prefs.
        case 1:
            if (([NSScreen mainScreen].frame.origin.x == frame.origin.x) || isPreview) {
                [self show:webView];
            }
            break;
        // All Screens
        case 2:
            [self show:webView];
            break;
        default:
            [self show:webView];
            break;
    }

    return self;
}

- (void)show:(WebView *)webView {
    [self addSubview:webView];
    _page = webView;
    [self connectWabe];
}

- (void)dealloc {
    if (_wabe) dispatch_source_cancel(_wabe);
}

#pragma mark - wabe

// Hands the page the screen normal from the daemon's newest line, retrying each second while no
// daemon answers.
- (void)connectWabe {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {
        .sin_len = sizeof(addr),
        .sin_family = AF_INET,
        .sin_port = htons(wabePort),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        [self retryWabe];
        return;
    }
    send(fd, "rate 60\n", 8, 0);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    _unread = [NSMutableData data];
    _wabe = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
    __weak EvangelionClock *weakSelf = self;
    dispatch_source_set_event_handler(_wabe, ^{ [weakSelf readWabe:fd]; });
    dispatch_source_set_cancel_handler(_wabe, ^{ close(fd); });
    dispatch_resume(_wabe);
}

- (void)retryWabe {
    __weak EvangelionClock *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakSelf connectWabe];
    });
}

- (void)readWabe:(int)fd {
    char chunk[4096];
    ssize_t n = read(fd, chunk, sizeof(chunk));
    if (n < 0 && errno == EAGAIN) return;
    if (n <= 0) {
        dispatch_source_cancel(_wabe);
        _wabe = nil;
        [_page.windowScriptObject callWebScriptMethod:@"wabePose" withArguments:@[]];
        [self retryWabe];
        return;
    }
    [_unread appendBytes:chunk length:(NSUInteger)n];

    // Only the newest complete line matters; any before it in the same read are already stale.
    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    NSRange end = [_unread rangeOfData:newline options:NSDataSearchBackwards range:NSMakeRange(0, _unread.length)];
    if (end.location == NSNotFound) return;
    NSRange before = [_unread rangeOfData:newline options:NSDataSearchBackwards range:NSMakeRange(0, end.location)];
    NSUInteger start = before.location == NSNotFound ? 0 : NSMaxRange(before);
    NSData *line = [_unread subdataWithRange:NSMakeRange(start, end.location - start)];
    [_unread replaceBytesInRange:NSMakeRange(0, NSMaxRange(end)) withBytes:NULL length:0];

    NSDictionary *pose = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    NSArray *normal = pose[@"n"];
    // A machine without the hinge sensor publishes a zero normal: nothing to follow.
    if (normal.count == 3 && ![normal isEqual:@[@0, @0, @0]])
        [_page.windowScriptObject callWebScriptMethod:@"wabePose" withArguments:normal];
}

#pragma mark - ScreenSaverView

- (void)animateOneFrame { [self stopAnimation]; }

#pragma mark - Config
// http://cocoadevcentral.com/articles/000088.php

- (BOOL)hasConfigureSheet { return YES; }

- (NSWindow *)configureSheet
{
    ScreenSaverDefaults *defaults;
    defaults = [ScreenSaverDefaults defaultsForModuleWithName:evangelionClockModule];

    if (!configSheet)
    {
        if (![NSBundle loadNibNamed:@"ConfigureSheet" owner:self])
        {
            NSLog( @"Failed to load configure sheet." );
        }
    }

    [styleOption selectItemAtIndex:[defaults integerForKey:@"styleOption"]];
    [screenDisplayOption selectItemAtIndex:[defaults integerForKey:@"screenDisplayOption"]];
    return configSheet;
}

- (IBAction)cancelClick:(id)sender
{
    [[NSApplication sharedApplication] endSheet:configSheet];
}

- (IBAction) okClick: (id)sender
{
    ScreenSaverDefaults *defaults;
    defaults = [ScreenSaverDefaults defaultsForModuleWithName:evangelionClockModule];

    // Update our defaults
    [defaults setInteger:[styleOption indexOfSelectedItem] forKey:@"styleOption"];
    [defaults setInteger:[screenDisplayOption indexOfSelectedItem]
               forKey:@"screenDisplayOption"];

    // Save the settings to disk
    [defaults synchronize];

    // Close the sheet
    [[NSApplication sharedApplication] endSheet:configSheet];
}

#pragma mark - WebFrameLoadDelegate

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
    NSLog(@"%@ error=%@", NSStringFromSelector(_cmd), error);
}

#pragma mark Focus Overrides

- (NSView *)hitTest:(NSPoint)aPoint {return self;}
//- (void)keyDown:(NSEvent *)theEvent {return;}
//- (void)keyUp:(NSEvent *)theEvent {return;}
- (void)mouseDown:(NSEvent *)theEvent {return;}
- (void)mouseUp:(NSEvent *)theEvent {return;}
- (void)mouseDragged:(NSEvent *)theEvent {return;}
- (void)mouseEntered:(NSEvent *)theEvent {return;}
- (void)mouseExited:(NSEvent *)theEvent {return;}
- (BOOL)acceptsFirstResponder {return YES;}
- (BOOL)resignFirstResponder {return NO;}

@end
