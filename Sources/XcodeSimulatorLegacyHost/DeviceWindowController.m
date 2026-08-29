#import "DeviceWindowController.h"

#import "HostLogging.h"
#import "PrivateInterfaces.h"
#import "PrivateRuntime.h"
#import "SwiftABI.h"

#import <stdlib.h>

static const CGFloat XSHControlBarHeight = 46.0;
static const CGFloat XSHDisplayInset = 10.0;

@interface XSHDeviceContentView : NSView
@property (nonatomic, readonly) NSView *displayView;
@property (nonatomic, readonly) NSView *controlBar;
- (instancetype)initWithDisplayView:(NSView *)displayView
                         controlBar:(NSView *)controlBar;
- (CGSize)availableDisplaySize;
@end

@implementation XSHDeviceContentView

- (instancetype)initWithDisplayView:(NSView *)displayView
                         controlBar:(NSView *)controlBar {
    self = [super initWithFrame:NSZeroRect];
    if (self != nil) {
        _displayView = displayView;
        _controlBar = controlBar;
        self.wantsLayer = YES;
        [self addSubview:displayView];
        [self addSubview:controlBar];
    }
    return self;
}

- (CGSize)availableDisplaySize {
    return CGSizeMake(
        MAX(1.0, NSWidth(self.bounds) - (2.0 * XSHDisplayInset)),
        MAX(1.0, NSHeight(self.bounds) - XSHControlBarHeight - (2.0 * XSHDisplayInset))
    );
}

- (void)layout {
    [super layout];

    self.controlBar.frame = NSMakeRect(
        0.0,
        0.0,
        NSWidth(self.bounds),
        XSHControlBarHeight
    );

    NSSize displaySize = self.displayView.intrinsicContentSize;
    if (displaySize.width <= 0.0 || displaySize.height <= 0.0) {
        displaySize = self.displayView.frame.size;
    }

    NSRect availableRect = NSMakeRect(
        XSHDisplayInset,
        XSHControlBarHeight + XSHDisplayInset,
        MAX(1.0, NSWidth(self.bounds) - (2.0 * XSHDisplayInset)),
        MAX(1.0, NSHeight(self.bounds) - XSHControlBarHeight - (2.0 * XSHDisplayInset))
    );
    self.displayView.frame = NSMakeRect(
        NSMidX(availableRect) - (displaySize.width / 2.0),
        NSMidY(availableRect) - (displaySize.height / 2.0),
        displaySize.width,
        displaySize.height
    );
}

@end

@interface XSHDeviceWindowController ()
@property (nonatomic, readwrite) NSString *deviceIdentifier;
@property (nonatomic) XSHSimDevice *device;
@property (nonatomic) XSHPrivateRuntime *runtime;
@property (nonatomic) XSHLegacyHIDClient *hidClient;
@property (nonatomic) NSView *displayView;
@property (nonatomic) XSHDeviceContentView *deviceContentView;
@property (nonatomic, copy) XSHDeviceWindowCloseHandler closeHandler;
@property (nonatomic) BOOL invalidated;
@property (nonatomic) BOOL disconnected;
@property (nonatomic) BOOL applyingResize;
@end

@implementation XSHDeviceWindowController

- (nullable instancetype)initWithDevice:(XSHSimDevice *)device
                               screenID:(uint32_t)screenID
                                runtime:(XSHPrivateRuntime *)runtime
                           closeHandler:(XSHDeviceWindowCloseHandler)closeHandler
                                  error:(NSError **)error {
    NSError *hidError = nil;
    XSHLegacyHIDClient *hidClient = [[runtime.legacyHIDClientClass alloc]
        initWithDevice:device
                 error:&hidError];
    if (hidClient == nil) {
        if (error != NULL) {
            NSString *detail = hidError.localizedDescription ?: @"unknown HID error";
            *error = XSHLegacyHostError(
                XSHLegacyHostErrorDeviceConnection,
                [NSString stringWithFormat:@"could not create HID client for %@: %@",
                                           device.name ?: @"simulator",
                                           detail]
            );
        }
        return nil;
    }

    NSView *displayView = nil;
    @try {
        displayView = [runtime.displayFactoryClass
            createSimDisplayViewWithDevice:device
                              simScreenID:screenID];
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = XSHLegacyHostError(
                XSHLegacyHostErrorDeviceConnection,
                [NSString stringWithFormat:@"display factory raised %@: %@",
                                           exception.name,
                                           exception.reason ?: @"no reason"]
            );
        }
        return nil;
    }

    if (displayView == nil) {
        if (error != NULL) {
            *error = XSHLegacyHostError(
                XSHLegacyHostErrorDeviceConnection,
                [NSString stringWithFormat:@"display factory returned no view for %@",
                                           device.name ?: @"simulator"]
            );
        }
        return nil;
    }

    NSError *imageError = nil;
    if (![runtime validateLoadedImagesWithError:&imageError]) {
        XSHSwiftDisconnect(runtime.disconnectDisplayFunction, displayView);
        if (error != NULL) {
            *error = imageError;
        }
        return nil;
    }

    NSSize naturalSize = displayView.intrinsicContentSize;
    if (naturalSize.width <= 0.0 || naturalSize.height <= 0.0) {
        if (displayView.frame.size.width > 0.0 && displayView.frame.size.height > 0.0) {
            naturalSize = displayView.frame.size;
        } else {
            XSHSwiftDisconnect(runtime.disconnectDisplayFunction, displayView);
            if (error != NULL) {
                *error = XSHLegacyHostError(
                    XSHLegacyHostErrorDeviceConnection,
                    [NSString stringWithFormat:@"display view for %@ has no usable size",
                                               device.name ?: @"simulator"]
                );
            }
            return nil;
        }
    }

    self = [super initWithWindow:nil];
    if (self == nil) {
        XSHSwiftDisconnect(runtime.disconnectDisplayFunction, displayView);
        return nil;
    }

    _device = device;
    _runtime = runtime;
    _hidClient = hidClient;
    _displayView = displayView;
    _deviceIdentifier = device.UDID.UUIDString.copy;
    _closeHandler = [closeHandler copy];

    NSView *controlBar = [self makeControlBar];
    _deviceContentView = [[XSHDeviceContentView alloc]
        initWithDisplayView:displayView
                 controlBar:controlBar];

    NSSize initialDisplaySize = [self initialDisplaySizeForNaturalSize:naturalSize];
    NSRect contentRect = NSMakeRect(
        0.0,
        0.0,
        initialDisplaySize.width + (2.0 * XSHDisplayInset),
        initialDisplaySize.height + XSHControlBarHeight + (2.0 * XSHDisplayInset)
    );
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable |
        NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:contentRect
                                                  styleMask:styleMask
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    window.title = device.name ?: @"iOS Simulator";
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.contentView = self.deviceContentView;
    window.minSize = NSMakeSize(260.0, 420.0);
    self.window = window;

    [self.deviceContentView layoutSubtreeIfNeeded];
    [self resizeDisplayToFit];

    return self;
}

- (NSSize)initialDisplaySizeForNaturalSize:(NSSize)naturalSize {
    NSScreen *screen = NSScreen.mainScreen;
    if (screen == nil) {
        return naturalSize;
    }

    NSRect visibleFrame = screen.visibleFrame;
    CGFloat maximumWidth = NSWidth(visibleFrame) * 0.8;
    CGFloat maximumHeight = (NSHeight(visibleFrame) * 0.8) - XSHControlBarHeight;
    CGFloat scale = MIN(
        1.0,
        MIN(maximumWidth / naturalSize.width, maximumHeight / naturalSize.height)
    );
    return NSMakeSize(naturalSize.width * scale, naturalSize.height * scale);
}

- (NSView *)makeControlBar {
    NSVisualEffectView *bar = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    bar.material = NSVisualEffectMaterialHeaderView;
    bar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    bar.state = NSVisualEffectStateActive;

    NSButton *homeButton = [NSButton buttonWithImage:[self
        imageWithSystemName:@"circle.inset.filled"
       accessibilityLabel:@"Home"]
                                                target:self
                                                action:@selector(pressHome:)];
    [self configureControlButton:homeButton label:@"Home"];

    NSButton *keyboardButton = [NSButton buttonWithImage:[self
        imageWithSystemName:@"keyboard"
       accessibilityLabel:@"Software Keyboard"]
                                                    target:self
                                                    action:@selector(toggleSoftwareKeyboard:)];
    [self configureControlButton:keyboardButton label:@"Software Keyboard"];

    NSStackView *controls = [NSStackView stackViewWithViews:@[
        homeButton,
        keyboardButton,
    ]];
    controls.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    controls.alignment = NSLayoutAttributeCenterY;
    controls.spacing = 8.0;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:controls];

    [NSLayoutConstraint activateConstraints:@[
        [controls.centerXAnchor constraintEqualToAnchor:bar.centerXAnchor],
        [controls.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];

    return bar;
}

- (NSImage *)imageWithSystemName:(NSString *)systemName
              accessibilityLabel:(NSString *)accessibilityLabel {
    NSImage *image = [NSImage imageWithSystemSymbolName:systemName
                              accessibilityDescription:accessibilityLabel];
    NSAssert(image != nil, @"required system image %@ is unavailable", systemName);
    return image;
}

- (void)configureControlButton:(NSButton *)button label:(NSString *)label {
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.imagePosition = NSImageOnly;
    button.toolTip = label;
    button.accessibilityLabel = label;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:34.0],
        [button.heightAnchor constraintEqualToConstant:30.0],
    ]];
}

- (void)showAndActivate {
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.displayView];
}

- (void)pressHome:(id)sender {
    (void)sender;
    [self sendButton:XSHHomeButton name:@"Home"];
    [self.window makeFirstResponder:self.displayView];
}

- (void)toggleSoftwareKeyboard:(id)sender {
    (void)sender;
    [self sendButton:XSHSoftwareKeyboardButton name:@"Software Keyboard"];
    [self.window makeFirstResponder:self.displayView];
}

- (void)sendButton:(uint32_t)button name:(NSString *)name {
    if (self.invalidated || self.device.state != XSHSimDeviceStateBooted) {
        return;
    }

    IndigoHIDMessageStruct *down = self.runtime.messageForButton(
        button,
        XSHButtonStateDown,
        XSHIntegratedDisplayHIDTarget
    );
    IndigoHIDMessageStruct *up = self.runtime.messageForButton(
        button,
        XSHButtonStateUp,
        XSHIntegratedDisplayHIDTarget
    );
    if (down == NULL || up == NULL) {
        free(down);
        free(up);
        XSHLog(@"could not allocate %@ HID messages for %@", name, self.deviceIdentifier);
        return;
    }

    @try {
        [self.hidClient sendWithMessage:down
                          freeWhenDone:YES
                       completionQueue:nil
                            completion:nil];
        [self.hidClient sendWithMessage:up
                          freeWhenDone:YES
                       completionQueue:nil
                            completion:nil];
    } @catch (NSException *exception) {
        XSHLog(@"%@ HID send raised %@ for %@: %@",
               name,
               exception.name,
               self.deviceIdentifier,
               exception.reason ?: @"no reason");
    }
}

- (void)windowWillStartLiveResize:(NSNotification *)notification {
    (void)notification;
    if (!self.invalidated) {
        XSHSwiftCallVoidMethod(self.runtime.beginResizeFunction, self.displayView);
    }
}

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    if (!self.invalidated) {
        [self resizeDisplayToFit];
    }
}

- (void)windowDidEndLiveResize:(NSNotification *)notification {
    (void)notification;
    if (!self.invalidated) {
        [self resizeDisplayToFit];
        XSHSwiftCallVoidMethod(self.runtime.endResizeFunction, self.displayView);
    }
}

- (void)resizeDisplayToFit {
    if (self.applyingResize || self.displayView == nil) {
        return;
    }

    CGSize availableSize = self.deviceContentView.availableDisplaySize;
    if (availableSize.width <= 0.0 || availableSize.height <= 0.0) {
        return;
    }

    self.applyingResize = YES;
    XSHSwiftCallCGSizeMethod(
        self.runtime.resizeToFunction,
        self.displayView,
        availableSize
    );
    [self.displayView invalidateIntrinsicContentSize];
    [self.deviceContentView setNeedsLayout:YES];
    [self.deviceContentView layoutSubtreeIfNeeded];
    self.applyingResize = NO;
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    if (self.invalidated) {
        return;
    }

    self.invalidated = YES;
    [self disconnectDisplay];
    self.closeHandler(self.deviceIdentifier);
}

- (void)invalidate {
    if (self.invalidated) {
        return;
    }

    self.invalidated = YES;
    [self disconnectDisplay];
    self.window.delegate = nil;
    [self.window orderOut:nil];
    [self.window close];
}

- (void)disconnectDisplay {
    if (self.disconnected || self.displayView == nil) {
        return;
    }

    self.disconnected = YES;
    XSHSwiftDisconnect(self.runtime.disconnectDisplayFunction, self.displayView);
    self.hidClient = nil;
}

- (void)dealloc {
    [self disconnectDisplay];
}

@end
