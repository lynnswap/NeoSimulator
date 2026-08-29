#import "MenuController.h"

#import "DeviceWindowController.h"

static NSString *XSHFunctionKeyEquivalent(unichar character) {
    return [NSString stringWithCharacters:&character length:1];
}

@implementation XSHMenuController

- (void)installMainMenu {
    NSString *applicationName = @"Xcode Simulator Legacy Host";
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

    NSMenu *applicationMenu = [self addMenuWithTitle:applicationName
                                         toMainMenu:mainMenu];
    [self addItemWithTitle:[@"About " stringByAppendingString:applicationName]
                    action:@selector(orderFrontStandardAboutPanel:)
             keyEquivalent:@""
                 modifiers:0
                     toMenu:applicationMenu];
    [applicationMenu addItem:NSMenuItem.separatorItem];
    [self addItemWithTitle:[@"Hide " stringByAppendingString:applicationName]
                    action:@selector(hide:)
             keyEquivalent:@"h"
                 modifiers:NSEventModifierFlagCommand
                     toMenu:applicationMenu];
    [self addItemWithTitle:@"Hide Others"
                    action:@selector(hideOtherApplications:)
             keyEquivalent:@"h"
                 modifiers:NSEventModifierFlagOption | NSEventModifierFlagCommand
                     toMenu:applicationMenu];
    [self addItemWithTitle:@"Show All"
                    action:@selector(unhideAllApplications:)
             keyEquivalent:@""
                 modifiers:0
                     toMenu:applicationMenu];
    [applicationMenu addItem:NSMenuItem.separatorItem];
    [self addItemWithTitle:[@"Quit " stringByAppendingString:applicationName]
                    action:@selector(quit:)
             keyEquivalent:@"q"
                 modifiers:NSEventModifierFlagCommand
                     toMenu:applicationMenu];

    NSMenu *fileMenu = [self addMenuWithTitle:@"File" toMainMenu:mainMenu];
    [self addItemWithTitle:@"Save Screen…"
                    action:@selector(saveFramebufferImage:)
             keyEquivalent:@"s"
                 modifiers:NSEventModifierFlagCommand
                     toMenu:fileMenu];
    [fileMenu addItem:NSMenuItem.separatorItem];
    [self addItemWithTitle:@"Close Window"
                    action:@selector(performClose:)
             keyEquivalent:@"w"
                 modifiers:NSEventModifierFlagCommand
                     toMenu:fileMenu];

    NSMenu *deviceMenu = [self addMenuWithTitle:@"Device" toMainMenu:mainMenu];
    [self addItemWithTitle:@"Rotate Left"
                    action:@selector(toggleRotationLeft:)
             keyEquivalent:XSHFunctionKeyEquivalent(NSLeftArrowFunctionKey)
                 modifiers:NSEventModifierFlagCommand
                     toMenu:deviceMenu];
    [self addItemWithTitle:@"Rotate Right"
                    action:@selector(toggleRotationRight:)
             keyEquivalent:XSHFunctionKeyEquivalent(NSRightArrowFunctionKey)
                 modifiers:NSEventModifierFlagCommand
                     toMenu:deviceMenu];
    [deviceMenu addItem:NSMenuItem.separatorItem];
    [self addItemWithTitle:@"Home"
                    action:@selector(homeButtonPressed:)
             keyEquivalent:@"h"
                 modifiers:NSEventModifierFlagShift | NSEventModifierFlagCommand
                     toMenu:deviceMenu];
    [self addItemWithTitle:@"Lock"
                    action:@selector(lockButtonPressed:)
             keyEquivalent:@"l"
                 modifiers:NSEventModifierFlagCommand
                     toMenu:deviceMenu];
    [self addItemWithTitle:@"Shake"
                    action:@selector(shakeDevice:)
             keyEquivalent:@"z"
                 modifiers:NSEventModifierFlagControl | NSEventModifierFlagCommand
                     toMenu:deviceMenu];

    NSMenu *inputOutputMenu = [self addMenuWithTitle:@"I/O" toMainMenu:mainMenu];
    [self addItemWithTitle:@"Toggle Software Keyboard"
                    action:@selector(toggleSoftwareKeyboard:)
             keyEquivalent:@"k"
                 modifiers:NSEventModifierFlagCommand
                     toMenu:inputOutputMenu];

    NSMenu *featuresMenu = [self addMenuWithTitle:@"Features" toMainMenu:mainMenu];
    [self addItemWithTitle:@"Toggle Appearance"
                    action:@selector(toggleAppearance:)
             keyEquivalent:@"a"
                 modifiers:NSEventModifierFlagShift | NSEventModifierFlagCommand
                     toMenu:featuresMenu];

    NSMenu *windowMenu = [self addMenuWithTitle:@"Window" toMainMenu:mainMenu];
    [self addItemWithTitle:@"Minimize"
                    action:@selector(performMiniaturize:)
             keyEquivalent:@"m"
                 modifiers:NSEventModifierFlagCommand
                     toMenu:windowMenu];
    [self addItemWithTitle:@"Zoom"
                    action:@selector(performZoom:)
             keyEquivalent:@""
                 modifiers:0
                     toMenu:windowMenu];
    [self addItemWithTitle:@"Enter Full Screen"
                    action:@selector(toggleFullScreen:)
             keyEquivalent:@"f"
                 modifiers:NSEventModifierFlagControl | NSEventModifierFlagCommand
                     toMenu:windowMenu];
    [self addItemWithTitle:@"Show Device Bezels"
                    action:@selector(toggleShowChrome:)
             keyEquivalent:@""
                 modifiers:0
                     toMenu:windowMenu];
    [self addItemWithTitle:@"Stay On Top"
                    action:@selector(toggleAlwaysOnTop:)
             keyEquivalent:@""
                 modifiers:0
                     toMenu:windowMenu];
    [windowMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *fitScreenItem = [self addItemWithTitle:@"Fit Screen"
                                                action:@selector(windowScaleChanged:)
                                         keyEquivalent:@"4"
                                             modifiers:NSEventModifierFlagCommand
                                                 toMenu:windowMenu];
    fitScreenItem.tag = 4111;
    [windowMenu addItem:NSMenuItem.separatorItem];
    [self addItemWithTitle:@"Bring All to Front"
                    action:@selector(arrangeInFront:)
             keyEquivalent:@""
                 modifiers:0
                     toMenu:windowMenu];

    NSApp.mainMenu = mainMenu;
    NSApp.windowsMenu = windowMenu;
}

- (NSMenu *)addMenuWithTitle:(NSString *)title toMainMenu:(NSMenu *)mainMenu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:nil
                                           keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    item.submenu = menu;
    [mainMenu addItem:item];
    return menu;
}

- (NSMenuItem *)addItemWithTitle:(NSString *)title
                          action:(SEL)action
                   keyEquivalent:(NSString *)keyEquivalent
                       modifiers:(NSEventModifierFlags)modifiers
                           toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:keyEquivalent];
    item.target = self;
    item.keyEquivalentModifierMask = modifiers;
    [menu addItem:item];
    return item;
}

- (nullable XSHDeviceWindowController *)activeSession {
    NSWindowController *controller = NSApp.keyWindow.windowController;
    if (![controller isKindOfClass:XSHDeviceWindowController.class]) {
        return nil;
    }
    return (XSHDeviceWindowController *)controller;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    SEL action = menuItem.action;
    XSHDeviceWindowController *session = self.activeSession;

    if (action == @selector(orderFrontStandardAboutPanel:) ||
        action == @selector(hide:) ||
        action == @selector(hideOtherApplications:) ||
        action == @selector(unhideAllApplications:) ||
        action == @selector(quit:)) {
        return YES;
    }

    if (action == @selector(arrangeInFront:)) {
        return NSApp.windows.count > 0;
    }
    if (session == nil) {
        menuItem.state = NSControlStateValueOff;
        return NO;
    }

    if (action == @selector(toggleShowChrome:)) {
        menuItem.state = session.deviceChromeVisible
            ? NSControlStateValueOn
            : NSControlStateValueOff;
        return session.canPerformCommands;
    }
    if (action == @selector(toggleAlwaysOnTop:)) {
        menuItem.state = session.stayingOnTop
            ? NSControlStateValueOn
            : NSControlStateValueOff;
        return session.canPerformCommands;
    }
    if (action == @selector(saveFramebufferImage:) ||
        action == @selector(toggleRotationLeft:) ||
        action == @selector(toggleRotationRight:)) {
        return session.canPerformToolOperation;
    }
    if (action == @selector(windowScaleChanged:)) {
        return session.canPerformCommands &&
            !session.window.inLiveResize &&
            !(session.window.styleMask & NSWindowStyleMaskFullScreen);
    }
    if (action == @selector(toggleFullScreen:)) {
        BOOL isFullScreen = session.window.styleMask & NSWindowStyleMaskFullScreen;
        menuItem.title = isFullScreen ? @"Exit Full Screen" : @"Enter Full Screen";
        return session.window != nil;
    }
    if (action == @selector(performClose:) ||
        action == @selector(performMiniaturize:) ||
        action == @selector(performZoom:)) {
        return session.window != nil;
    }
    return session.canPerformCommands;
}

- (void)orderFrontStandardAboutPanel:(id)sender {
    [NSApp orderFrontStandardAboutPanel:sender];
}

- (void)hide:(id)sender {
    [NSApp hide:sender];
}

- (void)hideOtherApplications:(id)sender {
    [NSApp hideOtherApplications:sender];
}

- (void)unhideAllApplications:(id)sender {
    [NSApp unhideAllApplications:sender];
}

- (void)quit:(id)sender {
    [NSApp terminate:sender];
}

- (void)saveFramebufferImage:(id)sender {
    [self.activeSession saveFramebufferImage:sender];
}

- (void)performClose:(id)sender {
    [self.activeSession.window performClose:sender];
}

- (void)toggleRotationLeft:(id)sender {
    [self.activeSession toggleRotationLeft:sender];
}

- (void)toggleRotationRight:(id)sender {
    [self.activeSession toggleRotationRight:sender];
}

- (void)homeButtonPressed:(id)sender {
    [self.activeSession homeButtonPressed:sender];
}

- (void)lockButtonPressed:(id)sender {
    [self.activeSession lockButtonPressed:sender];
}

- (void)shakeDevice:(id)sender {
    [self.activeSession shakeDevice:sender];
}

- (void)toggleSoftwareKeyboard:(id)sender {
    [self.activeSession toggleSoftwareKeyboard:sender];
}

- (void)toggleAppearance:(id)sender {
    [self.activeSession toggleAppearance:sender];
}

- (void)performMiniaturize:(id)sender {
    [self.activeSession.window performMiniaturize:sender];
}

- (void)performZoom:(id)sender {
    [self.activeSession.window performZoom:sender];
}

- (void)toggleFullScreen:(id)sender {
    [self.activeSession.window toggleFullScreen:sender];
}

- (void)toggleShowChrome:(id)sender {
    [self.activeSession toggleShowChrome:sender];
}

- (void)toggleAlwaysOnTop:(id)sender {
    [self.activeSession toggleAlwaysOnTop:sender];
}

- (void)windowScaleChanged:(id)sender {
    [self.activeSession fitScreen:sender];
}

- (void)arrangeInFront:(id)sender {
    [NSApp arrangeInFront:sender];
}

@end
