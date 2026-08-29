#import "DeviceWindowController.h"

#import "HostLogging.h"
#import "PrivateInterfaces.h"
#import "PrivateRuntime.h"
#import "SwiftABI.h"

#import <stdlib.h>

static const CGFloat XSHHeaderHeight = 74.0;
static const CGFloat XSHHeaderCornerRadius = 22.0;
static const CGFloat XSHHeaderDisplaySpacing = 14.0;
static const CGFloat XSHDisplayInset = 8.0;
static const CGFloat XSHMinimumHeaderWidth = 360.0;

@interface XSHHeaderView : NSVisualEffectView
@end

@implementation XSHHeaderView

- (nullable NSView *)hitTest:(NSPoint)point {
    NSView *hitView = [super hitTest:point];
    if (hitView == nil || [hitView isKindOfClass:NSButton.class]) {
        return hitView;
    }
    return self;
}

- (BOOL)mouseDownCanMoveWindow {
    return YES;
}

@end

@interface XSHDeviceContentView : NSView
@property (nonatomic, readonly) NSView *displayView;
@property (nonatomic, readonly) NSView *headerView;
- (instancetype)initWithDisplayView:(NSView *)displayView
                         headerView:(NSView *)headerView;
- (CGSize)availableDisplaySize;
@end

@implementation XSHDeviceContentView

- (instancetype)initWithDisplayView:(NSView *)displayView
                         headerView:(NSView *)headerView {
    self = [super initWithFrame:NSZeroRect];
    if (self != nil) {
        _displayView = displayView;
        _headerView = headerView;
        self.wantsLayer = YES;
        [self addSubview:displayView];
        [self addSubview:headerView];
    }
    return self;
}

- (CGSize)availableDisplaySize {
    CGFloat availableHeight = NSHeight(self.bounds) -
        XSHHeaderHeight -
        XSHHeaderDisplaySpacing -
        XSHDisplayInset;
    return CGSizeMake(
        MAX(1.0, NSWidth(self.bounds) - (2.0 * XSHDisplayInset)),
        MAX(1.0, availableHeight)
    );
}

- (void)layout {
    [super layout];

    self.headerView.frame = NSMakeRect(
        0.0,
        MAX(0.0, NSHeight(self.bounds) - XSHHeaderHeight),
        NSWidth(self.bounds),
        XSHHeaderHeight
    );

    NSSize displaySize = self.displayView.intrinsicContentSize;
    if (displaySize.width <= 0.0 || displaySize.height <= 0.0) {
        displaySize = self.displayView.frame.size;
    }

    NSRect availableRect = NSMakeRect(
        XSHDisplayInset,
        XSHDisplayInset,
        MAX(1.0, NSWidth(self.bounds) - (2.0 * XSHDisplayInset)),
        MAX(1.0,
            NSHeight(self.bounds) -
                XSHHeaderHeight -
                XSHHeaderDisplaySpacing -
                XSHDisplayInset)
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
    NSString *deviceName = device.name;
    NSString *runtimeName = device.runtime.name;
    if (deviceName.length == 0 || runtimeName.length == 0) {
        if (error != NULL) {
            *error = XSHLegacyHostError(
                XSHLegacyHostErrorDeviceConnection,
                @"booted simulator is missing its device or runtime display name"
            );
        }
        return nil;
    }
    NSString *windowTitle = [NSString stringWithFormat:@"%@ – %@",
                                                       deviceName,
                                                       runtimeName];

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
                                           deviceName,
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
                                           deviceName]
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

    XSHSwiftCallBoolMethod(runtime.showDeviceChromeFunction, displayView, YES);

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
                                               deviceName]
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

    NSView *headerView = [self makeHeaderViewWithTitle:windowTitle];
    _deviceContentView = [[XSHDeviceContentView alloc]
        initWithDisplayView:displayView
                 headerView:headerView];

    NSSize initialDisplaySize = [self initialDisplaySizeForNaturalSize:naturalSize];
    NSRect contentRect = NSMakeRect(
        0.0,
        0.0,
        MAX(initialDisplaySize.width + (2.0 * XSHDisplayInset),
            XSHMinimumHeaderWidth),
        initialDisplaySize.height +
            XSHDisplayInset +
            XSHHeaderDisplaySpacing +
            XSHHeaderHeight
    );
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable |
        NSWindowStyleMaskResizable |
        NSWindowStyleMaskFullSizeContentView;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:contentRect
                                                  styleMask:styleMask
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    window.title = windowTitle;
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    window.backgroundColor = NSColor.clearColor;
    window.opaque = NO;
    window.hasShadow = YES;
    window.movableByWindowBackground = NO;
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.contentView = self.deviceContentView;
    window.contentMinSize = NSMakeSize(300.0, 460.0);
    self.window = window;

    [self.deviceContentView layoutSubtreeIfNeeded];
    [self resizeDisplayToFit];
    [window invalidateShadow];

    return self;
}

- (NSSize)initialDisplaySizeForNaturalSize:(NSSize)naturalSize {
    NSScreen *screen = NSScreen.mainScreen;
    if (screen == nil) {
        return naturalSize;
    }

    NSRect visibleFrame = screen.visibleFrame;
    CGFloat maximumWidth = (NSWidth(visibleFrame) * 0.8) - (2.0 * XSHDisplayInset);
    CGFloat maximumHeight = (NSHeight(visibleFrame) * 0.8) -
        XSHHeaderHeight -
        XSHHeaderDisplaySpacing -
        XSHDisplayInset;
    CGFloat scale = MIN(
        1.0,
        MIN(maximumWidth / naturalSize.width, maximumHeight / naturalSize.height)
    );
    return NSMakeSize(naturalSize.width * scale, naturalSize.height * scale);
}

- (NSView *)makeHeaderViewWithTitle:(NSString *)title {
    XSHHeaderView *header = [[XSHHeaderView alloc] initWithFrame:NSZeroRect];
    header.material = NSVisualEffectMaterialHUDWindow;
    header.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    header.state = NSVisualEffectStateActive;
    header.wantsLayer = YES;
    header.layer.cornerRadius = XSHHeaderCornerRadius;
    header.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.22].CGColor;
    header.layer.borderWidth = 1.0;
    header.layer.masksToBounds = YES;

    NSTextField *titleLabel = [NSTextField labelWithString:title];
    titleLabel.alignment = NSTextAlignmentCenter;
    titleLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
    titleLabel.textColor = NSColor.secondaryLabelColor;
    titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    titleLabel.maximumNumberOfLines = 1;
    titleLabel.toolTip = title;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [header addSubview:titleLabel];

    NSVisualEffectView *capsule = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    capsule.material = NSVisualEffectMaterialMenu;
    capsule.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    capsule.state = NSVisualEffectStateActive;
    capsule.wantsLayer = YES;
    capsule.layer.cornerRadius = 18.0;
    capsule.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.10].CGColor;
    capsule.layer.borderWidth = 1.0;
    capsule.layer.masksToBounds = YES;
    capsule.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:capsule];

    NSButton *homeButton = [NSButton buttonWithImage:[self
        imageWithSystemName:@"house"
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
    controls.spacing = 2.0;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    [capsule addSubview:controls];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:header.topAnchor constant:9.0],
        [titleLabel.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:header.leadingAnchor
                                                              constant:94.0],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor
                                                               constant:-16.0],
        [capsule.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [capsule.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6.0],
        [capsule.widthAnchor constraintEqualToConstant:88.0],
        [capsule.heightAnchor constraintEqualToConstant:36.0],
        [controls.centerXAnchor constraintEqualToAnchor:capsule.centerXAnchor],
        [controls.centerYAnchor constraintEqualToAnchor:capsule.centerYAnchor],
    ]];

    return header;
}

- (NSImage *)imageWithSystemName:(NSString *)systemName
              accessibilityLabel:(NSString *)accessibilityLabel {
    NSImage *image = [NSImage imageWithSystemSymbolName:systemName
                              accessibilityDescription:accessibilityLabel];
    NSAssert(image != nil, @"required system image %@ is unavailable", systemName);
    return image;
}

- (void)configureControlButton:(NSButton *)button label:(NSString *)label {
    button.bezelStyle = NSBezelStyleRegularSquare;
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.contentTintColor = NSColor.labelColor;
    button.toolTip = label;
    button.accessibilityLabel = label;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:38.0],
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
    [self.window invalidateShadow];
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
