#import "DeviceWindowController.h"

#import "DeviceToolRunner.h"
#import "HostLogging.h"
#import "PrivateInterfaces.h"
#import "PrivateRuntime.h"
#import "SwiftABI.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <errno.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>

static const CGFloat XSHHeaderHeight = 74.0;
static const CGFloat XSHHeaderCornerRadius = 22.0;
static const CGFloat XSHHeaderDisplaySpacing = 14.0;
static const CGFloat XSHDisplayInset = 8.0;
static const CGFloat XSHMinimumHeaderWidth = 360.0;
static NSString *const XSHShakeNotification = @"com.apple.UIKit.SimulatorShake";

static NSError *XSHScreenshotError(NSString *description) {
    return XSHNeoHostError(XSHNeoHostErrorToolOperation, description);
}

static NSURL *XSHScreenshotTemporaryURL(NSURL *destinationURL, NSError **error) {
    NSURL *directoryURL = destinationURL.URLByDeletingLastPathComponent;
    NSString *name = [NSString stringWithFormat:@".neo-simulator-%@.png",
                                               NSUUID.UUID.UUIDString];
    NSURL *temporaryURL = [directoryURL URLByAppendingPathComponent:name];
    struct stat fileStatus;
    if (lstat(temporaryURL.fileSystemRepresentation, &fileStatus) == 0 ||
        errno != ENOENT) {
        if (error != NULL) {
            *error = XSHScreenshotError(
                [NSString stringWithFormat:@"could not reserve a screenshot file beside %@",
                                           destinationURL.lastPathComponent]
            );
        }
        return nil;
    }
    return temporaryURL;
}

static BOOL XSHValidatePNGAtURL(NSURL *fileURL, NSError **error) {
    struct stat fileStatus;
    if (lstat(fileURL.fileSystemRepresentation, &fileStatus) != 0 ||
        !S_ISREG(fileStatus.st_mode) ||
        fileStatus.st_size < 8) {
        if (error != NULL) {
            *error = XSHScreenshotError(@"the screenshot tool did not produce a regular PNG file");
        }
        return NO;
    }

    NSError *readError = nil;
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingFromURL:fileURL
                                                                   error:&readError];
    NSData *data = [fileHandle readDataUpToLength:8 error:&readError];
    [fileHandle closeAndReturnError:nil];
    const unsigned char expectedSignature[] = {0x89, 0x50, 0x4e, 0x47,
                                               0x0d, 0x0a, 0x1a, 0x0a};
    if (readError != nil ||
        data.length < sizeof(expectedSignature) ||
        memcmp(data.bytes, expectedSignature, sizeof(expectedSignature)) != 0) {
        if (error != NULL) {
            NSString *detail = readError.localizedDescription ?: @"invalid PNG signature";
            *error = XSHScreenshotError(
                [NSString stringWithFormat:@"could not validate the screenshot: %@", detail]
            );
        }
        return NO;
    }
    return YES;
}

static void XSHRemoveTemporaryScreenshot(NSURL *temporaryURL) {
    NSError *error = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:temporaryURL.path] &&
        ![NSFileManager.defaultManager removeItemAtURL:temporaryURL error:&error]) {
        XSHLog(@"could not remove temporary screenshot %@: %@",
               temporaryURL.path,
               error.localizedDescription ?: @"unknown error");
    }
}

static BOOL XSHAtomicallyReplaceURL(NSURL *temporaryURL,
                                    NSURL *destinationURL,
                                    NSError **error) {
    if (rename(temporaryURL.fileSystemRepresentation,
               destinationURL.fileSystemRepresentation) == 0) {
        return YES;
    }
    if (error != NULL) {
        *error = XSHScreenshotError(
            [NSString stringWithFormat:@"could not save %@: %s",
                                       destinationURL.lastPathComponent,
                                       strerror(errno)]
        );
    }
    return NO;
}

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
@property (nonatomic, readwrite, getter=isDeviceChromeVisible) BOOL deviceChromeVisible;
@property (nonatomic) XSHSimDevice *device;
@property (nonatomic) XSHPrivateRuntime *runtime;
@property (nonatomic) XSHLegacyHIDClient *hidClient;
@property (nonatomic) XSHDeviceToolRunner *toolRunner;
@property (nonatomic) NSView *displayView;
@property (nonatomic) XSHDeviceContentView *deviceContentView;
@property (nonatomic, nullable) NSSavePanel *savePanel;
@property (nonatomic) NSArray<NSButton *> *toolOperationButtons;
@property (nonatomic, copy) XSHDeviceWindowCloseHandler closeHandler;
@property (nonatomic) BOOL invalidated;
@property (nonatomic) BOOL disconnected;
@property (nonatomic) BOOL applyingResize;
@property (nonatomic) BOOL operationInProgress;
@property (nonatomic) BOOL requestedInitialOrientation;
@end

@implementation XSHDeviceWindowController

- (nullable instancetype)initWithDevice:(XSHSimDevice *)device
                               screenID:(uint32_t)screenID
                                runtime:(XSHPrivateRuntime *)runtime
                           closeHandler:(XSHDeviceWindowCloseHandler)closeHandler
                                  error:(NSError **)error {
    NSString *deviceName = device.name;
    NSString *runtimeName = device.runtime.name;
    NSString *deviceIdentifier = device.UDID.UUIDString;
    if (deviceName.length == 0 ||
        runtimeName.length == 0 ||
        deviceIdentifier.length == 0) {
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorDeviceConnection,
                @"booted simulator is missing its device or runtime display name"
            );
        }
        return nil;
    }
    NSString *windowTitle = [NSString stringWithFormat:@"%@ – %@",
                                                       deviceName,
                                                       runtimeName];

    NSError *toolError = nil;
    XSHDeviceToolRunner *toolRunner = [[XSHDeviceToolRunner alloc]
        initWithXcodeURL:runtime.xcodeURL
       deviceIdentifier:deviceIdentifier
                  error:&toolError];
    if (toolRunner == nil) {
        if (error != NULL) {
            *error = toolError;
        }
        return nil;
    }

    NSError *hidError = nil;
    XSHLegacyHIDClient *hidClient = [[runtime.legacyHIDClientClass alloc]
        initWithDevice:device
                 error:&hidError];
    if (hidClient == nil) {
        if (error != NULL) {
            NSString *detail = hidError.localizedDescription ?: @"unknown HID error";
            *error = XSHNeoHostError(
                XSHNeoHostErrorDeviceConnection,
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
            *error = XSHNeoHostError(
                XSHNeoHostErrorDeviceConnection,
                [NSString stringWithFormat:@"display factory raised %@: %@",
                                           exception.name,
                                           exception.reason ?: @"no reason"]
            );
        }
        return nil;
    }

    if (displayView == nil) {
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorDeviceConnection,
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
                *error = XSHNeoHostError(
                    XSHNeoHostErrorDeviceConnection,
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
    _toolRunner = toolRunner;
    _displayView = displayView;
    _deviceIdentifier = deviceIdentifier.copy;
    _deviceChromeVisible = YES;
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
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
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
    XSHHeaderView *header = [[XSHHeaderView alloc] initWithFrame:NSMakeRect(
        0.0,
        0.0,
        XSHMinimumHeaderWidth,
        XSHHeaderHeight
    )];
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
                                                action:@selector(homeButtonPressed:)];
    [self configureControlButton:homeButton label:@"Home"];

    NSButton *saveScreenButton = [NSButton buttonWithImage:[self
        imageWithSystemName:@"camera.on.rectangle"
       accessibilityLabel:@"Save Screen"]
                                                      target:self
                                                      action:@selector(saveFramebufferImage:)];
    [self configureControlButton:saveScreenButton label:@"Save Screen"];

    NSButton *rotateRightButton = [NSButton buttonWithImage:[self
        imageWithSystemName:@"rotate.right"
       accessibilityLabel:@"Rotate Right"]
                                                       target:self
                                                       action:@selector(toggleRotationRight:)];
    [self configureControlButton:rotateRightButton label:@"Rotate Right"];

    NSButton *keyboardButton = [NSButton buttonWithImage:[self
        imageWithSystemName:@"keyboard"
       accessibilityLabel:@"Software Keyboard"]
                                                    target:self
                                                    action:@selector(toggleSoftwareKeyboard:)];
    [self configureControlButton:keyboardButton label:@"Software Keyboard"];

    NSStackView *controls = [NSStackView stackViewWithViews:@[
        homeButton,
        saveScreenButton,
        rotateRightButton,
        keyboardButton,
    ]];
    self.toolOperationButtons = @[saveScreenButton, rotateRightButton];
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
        [capsule.widthAnchor constraintEqualToConstant:168.0],
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
    if (!self.requestedInitialOrientation) {
        self.requestedInitialOrientation = YES;
        [self synchronizeDeviceRotationPresentingError:NO];
    }
}

- (BOOL)canPerformCommands {
    return !self.invalidated && self.device.state == XSHSimDeviceStateBooted;
}

- (BOOL)canPerformToolOperation {
    return self.canPerformCommands && !self.operationInProgress;
}

- (BOOL)isStayingOnTop {
    return self.window.level == NSFloatingWindowLevel;
}

- (void)setOperationInProgress:(BOOL)operationInProgress {
    _operationInProgress = operationInProgress;
    for (NSButton *button in self.toolOperationButtons) {
        button.enabled = !operationInProgress && self.canPerformCommands;
    }
}

- (void)saveFramebufferImage:(id)sender {
    (void)sender;
    if (!self.canPerformToolOperation) {
        return;
    }

    self.operationInProgress = YES;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePNG];
    panel.allowsOtherFileTypes = NO;
    panel.canCreateDirectories = YES;
    panel.extensionHidden = NO;
    panel.nameFieldStringValue = @"Simulator Screenshot.png";
    self.savePanel = panel;

    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window
                 completionHandler:^(NSModalResponse result) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.savePanel = nil;
        if (result != NSModalResponseOK || strongSelf.invalidated) {
            strongSelf.operationInProgress = NO;
            return;
        }

        NSURL *destinationURL = panel.URL;
        NSError *temporaryError = nil;
        NSURL *temporaryURL = XSHScreenshotTemporaryURL(
            destinationURL,
            &temporaryError
        );
        if (temporaryURL == nil) {
            strongSelf.operationInProgress = NO;
            [strongSelf presentActionError:temporaryError];
            return;
        }

        [strongSelf.toolRunner captureScreenshotAtURL:temporaryURL
                                           completion:^(NSError *toolError) {
            typeof(self) completedSelf = weakSelf;
            if (toolError != nil || completedSelf == nil || completedSelf.invalidated) {
                XSHRemoveTemporaryScreenshot(temporaryURL);
                if (completedSelf != nil) {
                    completedSelf.operationInProgress = NO;
                    if (!completedSelf.invalidated &&
                        toolError.code != NSUserCancelledError) {
                        [completedSelf presentActionError:toolError];
                    }
                }
                return;
            }

            NSError *saveError = nil;
            BOOL isValid = XSHValidatePNGAtURL(temporaryURL, &saveError);
            BOOL didReplace = isValid && XSHAtomicallyReplaceURL(
                temporaryURL,
                destinationURL,
                &saveError
            );
            if (!didReplace) {
                XSHRemoveTemporaryScreenshot(temporaryURL);
            }
            completedSelf.operationInProgress = NO;
            if (!didReplace) {
                [completedSelf presentActionError:saveError];
            }
        }];
    }];
}

- (void)toggleRotationLeft:(id)sender {
    (void)sender;
    [self rotate:XSHDeviceRotationDirectionLeft];
}

- (void)toggleRotationRight:(id)sender {
    (void)sender;
    [self rotate:XSHDeviceRotationDirectionRight];
}

- (void)rotate:(XSHDeviceRotationDirection)direction {
    if (!self.canPerformToolOperation) {
        return;
    }

    self.operationInProgress = YES;
    __weak typeof(self) weakSelf = self;
    [self.toolRunner rotate:direction completion:^(NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (error != nil || strongSelf.invalidated) {
            strongSelf.operationInProgress = NO;
            if (!strongSelf.invalidated && error.code != NSUserCancelledError) {
                [strongSelf presentActionError:error];
            }
            return;
        }
        [strongSelf readAndApplyDeviceRotationPresentingError:YES];
    }];
}

- (void)synchronizeDeviceRotationPresentingError:(BOOL)presentError {
    if (!self.canPerformToolOperation) {
        return;
    }
    self.operationInProgress = YES;
    [self readAndApplyDeviceRotationPresentingError:presentError];
}

- (void)readAndApplyDeviceRotationPresentingError:(BOOL)presentError {
    __weak typeof(self) weakSelf = self;
    [self.toolRunner readOrientationWithCompletion:^(
        double rotationDegrees,
        NSError *error
    ) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.operationInProgress = NO;
        if (error != nil || strongSelf.invalidated) {
            if (!strongSelf.invalidated && error.code != NSUserCancelledError) {
                if (presentError) {
                    [strongSelf presentActionError:error];
                } else {
                    XSHLog(@"could not synchronize orientation for %@: %@",
                           strongSelf.deviceIdentifier,
                           error.localizedDescription);
                }
            }
            return;
        }
        [strongSelf applyRotationDegrees:rotationDegrees];
    }];
}

- (void)applyRotationDegrees:(double)rotationDegrees {
    XSHSwiftSetAngleMeasurement(
        self.runtime.deviceRotationSetterFunction,
        self.displayView,
        rotationDegrees,
        NSUnitAngle.degrees
    );
    [self.displayView invalidateIntrinsicContentSize];
    [self.deviceContentView setNeedsLayout:YES];
    [self fitScreen:nil];
    [self.window invalidateShadow];
}

- (void)homeButtonPressed:(id)sender {
    (void)sender;
    NSError *error = [self sendButton:XSHHomeButton name:@"Home"];
    [self presentActionError:error];
    [self.window makeFirstResponder:self.displayView];
}

- (void)toggleSoftwareKeyboard:(id)sender {
    (void)sender;
    NSError *error = [self sendButton:XSHSoftwareKeyboardButton
                                  name:@"Software Keyboard"];
    [self presentActionError:error];
    [self.window makeFirstResponder:self.displayView];
}

- (void)lockButtonPressed:(id)sender {
    (void)sender;
    NSError *error = [self sendButton:XSHLockButton name:@"Lock"];
    [self presentActionError:error];
    [self.window makeFirstResponder:self.displayView];
}

- (nullable NSError *)sendButton:(uint32_t)button name:(NSString *)name {
    if (!self.canPerformCommands) {
        return nil;
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
        return XSHNeoHostError(
            XSHNeoHostErrorDeviceConnection,
            [NSString stringWithFormat:@"could not allocate %@ HID messages", name]
        );
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
        return XSHNeoHostError(
            XSHNeoHostErrorDeviceConnection,
            [NSString stringWithFormat:@"%@ failed: %@",
                                       name,
                                       exception.reason ?: exception.name]
        );
    }
    return nil;
}

- (void)shakeDevice:(id)sender {
    (void)sender;
    if (!self.canPerformCommands) {
        return;
    }

    NSError *error = nil;
    @try {
        if (![self.device postDarwinNotification:XSHShakeNotification error:&error] &&
            error == nil) {
            error = XSHNeoHostError(
                XSHNeoHostErrorDeviceConnection,
                @"the simulator rejected the shake notification"
            );
        }
    } @catch (NSException *exception) {
        error = XSHNeoHostError(
            XSHNeoHostErrorDeviceConnection,
            [NSString stringWithFormat:@"Shake failed: %@",
                                       exception.reason ?: exception.name]
        );
    }
    [self presentActionError:error];
}

- (void)toggleAppearance:(id)sender {
    (void)sender;
    if (!self.canPerformCommands) {
        return;
    }

    NSError *error = nil;
    @try {
        NSUInteger currentStyle = self.device.currentUIInterfaceStyle;
        NSUInteger targetStyle = currentStyle == 2 ? 1 : 2;
        if (![self.device setUIInterfaceStyle:targetStyle error:&error] &&
            error == nil) {
            error = XSHNeoHostError(
                XSHNeoHostErrorDeviceConnection,
                @"the simulator rejected the appearance change"
            );
        }
    } @catch (NSException *exception) {
        error = XSHNeoHostError(
            XSHNeoHostErrorDeviceConnection,
            [NSString stringWithFormat:@"Toggle Appearance failed: %@",
                                       exception.reason ?: exception.name]
        );
    }
    [self presentActionError:error];
}

- (void)toggleShowChrome:(id)sender {
    (void)sender;
    if (!self.canPerformCommands) {
        return;
    }

    self.deviceChromeVisible = !self.deviceChromeVisible;
    XSHSwiftCallBoolMethod(
        self.runtime.showDeviceChromeFunction,
        self.displayView,
        self.deviceChromeVisible
    );
    [self.displayView invalidateIntrinsicContentSize];
    [self resizeDisplayToFit];
}

- (void)toggleAlwaysOnTop:(id)sender {
    (void)sender;
    if (!self.canPerformCommands) {
        return;
    }
    self.window.level = self.stayingOnTop
        ? NSNormalWindowLevel
        : NSFloatingWindowLevel;
}

- (void)fitScreen:(id)sender {
    (void)sender;
    if (!self.canPerformCommands ||
        self.window.inLiveResize ||
        (self.window.styleMask & NSWindowStyleMaskFullScreen)) {
        return;
    }

    CGFloat renderScale = XSHSwiftCallCGFloatGetter(
        self.runtime.renderScaleGetterFunction,
        self.displayView
    );
    NSSize currentSize = self.displayView.frame.size;
    if (renderScale <= 0.0 || currentSize.width <= 0.0 || currentSize.height <= 0.0) {
        return;
    }

    NSSize naturalSize = NSMakeSize(
        currentSize.width / renderScale,
        currentSize.height / renderScale
    );
    NSSize targetDisplaySize = [self initialDisplaySizeForNaturalSize:naturalSize];
    NSSize targetContentSize = NSMakeSize(
        MAX(targetDisplaySize.width + (2.0 * XSHDisplayInset), XSHMinimumHeaderWidth),
        targetDisplaySize.height +
            XSHDisplayInset +
            XSHHeaderDisplaySpacing +
            XSHHeaderHeight
    );
    [self.window setContentSize:targetContentSize];
    [self resizeDisplayToFit];
}

- (void)presentActionError:(nullable NSError *)error {
    if (error == nil || self.invalidated || self.window == nil) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Simulator Action Failed";
    alert.informativeText = error.localizedDescription;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
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
    [self cancelOutstandingOperation];
    [self disconnectDisplay];
    self.closeHandler(self.deviceIdentifier);
}

- (void)invalidate {
    if (self.invalidated) {
        return;
    }

    self.invalidated = YES;
    [self cancelOutstandingOperation];
    [self disconnectDisplay];
    self.window.delegate = nil;
    [self.window orderOut:nil];
    [self.window close];
}

- (void)cancelOutstandingOperation {
    NSSavePanel *panel = self.savePanel;
    if (panel.sheetParent != nil) {
        [panel.sheetParent endSheet:panel returnCode:NSModalResponseCancel];
    }
    [panel orderOut:nil];
    self.savePanel = nil;
    [self.toolRunner cancel];
    self.operationInProgress = NO;
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
