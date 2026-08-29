#import <AppKit/AppKit.h>
#import <stdlib.h>
#import <string.h>
#import <sysexits.h>

#import "HostLogging.h"
#import "LegacyHostApplication.h"
#import "PrivateRuntime.h"

static void XSHPrintUsage(FILE *stream) {
    fprintf(stream, "usage: XcodeSimulatorLegacyHost --xcode /absolute/path/to/Xcode.app\n");
}

static NSURL *XSHParseXcodeURL(int argc, const char *argv[], NSError **error) {
    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        XSHPrintUsage(stdout);
        exit(EX_OK);
    }

    if (argc != 3 || strcmp(argv[1], "--xcode") != 0) {
        if (error != NULL) {
            *error = XSHLegacyHostError(
                XSHLegacyHostErrorInvalidArguments,
                @"expected --xcode followed by an absolute Xcode.app path"
            );
        }
        return nil;
    }

    NSString *path = [NSString stringWithUTF8String:argv[2]];
    if (path.length == 0 || !path.isAbsolutePath) {
        if (error != NULL) {
            *error = XSHLegacyHostError(
                XSHLegacyHostErrorInvalidArguments,
                @"--xcode must be an absolute path"
            );
        }
        return nil;
    }

    NSURL *xcodeURL = [NSURL fileURLWithPath:path isDirectory:YES]
        .URLByStandardizingPath.URLByResolvingSymlinksInPath;
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:xcodeURL.path
                                             isDirectory:&isDirectory] ||
        !isDirectory ||
        ![xcodeURL.pathExtension.lowercaseString isEqualToString:@"app"]) {
        if (error != NULL) {
            *error = XSHLegacyHostError(
                XSHLegacyHostErrorInvalidInstallation,
                [NSString stringWithFormat:@"%@ is not an Xcode application directory",
                                           xcodeURL.path]
            );
        }
        return nil;
    }

    NSBundle *xcodeBundle = [NSBundle bundleWithURL:xcodeURL];
    if (![xcodeBundle.bundleIdentifier isEqualToString:@"com.apple.dt.Xcode"]) {
        if (error != NULL) {
            *error = XSHLegacyHostError(
                XSHLegacyHostErrorInvalidInstallation,
                [NSString stringWithFormat:@"%@ is not a com.apple.dt.Xcode bundle",
                                           xcodeURL.path]
            );
        }
        return nil;
    }

    NSString *developerDirectory = [xcodeURL.path
        stringByAppendingPathComponent:@"Contents/Developer"];
    if (![NSFileManager.defaultManager fileExistsAtPath:developerDirectory
                                             isDirectory:&isDirectory] ||
        !isDirectory) {
        if (error != NULL) {
            *error = XSHLegacyHostError(
                XSHLegacyHostErrorInvalidInstallation,
                [NSString stringWithFormat:@"%@ has no Contents/Developer directory",
                                           xcodeURL.path]
            );
        }
        return nil;
    }

    return xcodeURL;
}

static void XSHInstallMainMenu(void) {
    NSString *applicationName = @"Xcode Simulator Legacy Host";
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *applicationMenuItem = [[NSMenuItem alloc] initWithTitle:@""
                                                                 action:nil
                                                          keyEquivalent:@""];
    [mainMenu addItem:applicationMenuItem];
    NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:applicationName];
    applicationMenuItem.submenu = applicationMenu;
    [applicationMenu addItemWithTitle:[@"Hide " stringByAppendingString:applicationName]
                                action:@selector(hide:)
                         keyEquivalent:@"h"];
    [applicationMenu addItem:[NSMenuItem separatorItem]];
    [applicationMenu addItemWithTitle:[@"Quit " stringByAppendingString:applicationName]
                                action:@selector(terminate:)
                         keyEquivalent:@"q"];

    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@""
                                                            action:nil
                                                     keyEquivalent:@""];
    [mainMenu addItem:windowMenuItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    windowMenuItem.submenu = windowMenu;
    [windowMenu addItemWithTitle:@"Bring All to Front"
                           action:@selector(arrangeInFront:)
                    keyEquivalent:@""];

    NSApp.mainMenu = mainMenu;
    NSApp.windowsMenu = windowMenu;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSError *argumentError = nil;
        NSURL *xcodeURL = XSHParseXcodeURL(argc, argv, &argumentError);
        if (xcodeURL == nil) {
            if (argumentError.code == XSHLegacyHostErrorInvalidArguments) {
                XSHPrintUsage(stderr);
            }
            XSHLog(@"%@", argumentError.localizedDescription);
            return argumentError.code == XSHLegacyHostErrorInvalidArguments
                ? EX_USAGE
                : EX_UNAVAILABLE;
        }

        if (XSHLegacyHostApplication.isDeviceHubRunning) {
            XSHLog(@"Device Hub is already running; refusing to start");
            return EX_TEMPFAIL;
        }

        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        XSHInstallMainMenu();

        XSHLegacyHostApplication *controller = [[XSHLegacyHostApplication alloc]
            initWithXcodeURL:xcodeURL];
        application.delegate = controller;
        [application finishLaunching];

        if (XSHLegacyHostApplication.isDeviceHubRunning) {
            XSHLog(@"Device Hub launched during host startup; refusing to connect");
            return EX_TEMPFAIL;
        }

        NSError *runtimeError = nil;
        XSHPrivateRuntime *runtime = [[XSHPrivateRuntime alloc]
            initWithXcodeURL:xcodeURL
                       error:&runtimeError];
        if (runtime == nil) {
            XSHLog(@"%@", runtimeError.localizedDescription);
            return EX_UNAVAILABLE;
        }

        NSError *startupError = nil;
        if (![controller startWithRuntime:runtime error:&startupError]) {
            XSHLog(@"%@", startupError.localizedDescription);
            return startupError.code == XSHLegacyHostErrorDeviceHubConflict
                ? EX_TEMPFAIL
                : EX_UNAVAILABLE;
        }

        [application activate];
        [controller activateDeviceWindows];
        [application run];
    }
    return EX_OK;
}
