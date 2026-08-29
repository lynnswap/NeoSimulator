#import <AppKit/AppKit.h>
#import <stdlib.h>
#import <string.h>
#import <sysexits.h>

#import "HostLogging.h"
#import "LegacyHostApplication.h"
#import "MenuController.h"
#import "PrivateRuntime.h"

static void XSHPrintUsage(FILE *stream) {
    fprintf(stream,
            "usage: XcodeSimulatorLegacyHost [--validate-runtime] "
            "[--startup-result /absolute/path] --xcode "
            "/absolute/path/to/Xcode.app\n");
}

static void XSHSetInvalidArgumentsError(NSError **error) {
    if (error != NULL) {
        *error = XSHLegacyHostError(
            XSHLegacyHostErrorInvalidArguments,
            @"expected [--validate-runtime] [--startup-result /absolute/path] "
             "--xcode /absolute/path/to/Xcode.app"
        );
    }
}

static NSURL *XSHParseXcodeURL(int argc,
                              const char *argv[],
                              BOOL *validateRuntimeOnly,
                              NSURL **startupResultURL,
                              NSError **error) {
    *validateRuntimeOnly = NO;
    *startupResultURL = nil;
    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        XSHPrintUsage(stdout);
        exit(EX_OK);
    }

    const char *xcodePath = NULL;
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--validate-runtime") == 0) {
            if (*validateRuntimeOnly) {
                XSHSetInvalidArgumentsError(error);
                return nil;
            }
            *validateRuntimeOnly = YES;
            continue;
        }
        if (strcmp(argv[index], "--xcode") == 0) {
            if (xcodePath != NULL || index + 1 >= argc) {
                XSHSetInvalidArgumentsError(error);
                return nil;
            }
            xcodePath = argv[++index];
            continue;
        }
        if (strcmp(argv[index], "--startup-result") == 0) {
            if (*startupResultURL != nil || index + 1 >= argc) {
                XSHSetInvalidArgumentsError(error);
                return nil;
            }
            NSString *resultPath = [NSString stringWithUTF8String:argv[++index]];
            if (resultPath.length == 0 || !resultPath.isAbsolutePath) {
                XSHSetInvalidArgumentsError(error);
                return nil;
            }
            *startupResultURL = [NSURL fileURLWithPath:resultPath isDirectory:NO]
                .URLByStandardizingPath;
            continue;
        }

        XSHSetInvalidArgumentsError(error);
        return nil;
    }

    if (xcodePath == NULL || (*validateRuntimeOnly && *startupResultURL != nil)) {
        XSHSetInvalidArgumentsError(error);
        return nil;
    }

    NSString *path = [NSString stringWithUTF8String:xcodePath];
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

static BOOL XSHWriteStartupResult(NSURL *startupResultURL, NSError **error) {
    if (startupResultURL == nil) {
        return YES;
    }
    NSData *payload = [@"ready\n" dataUsingEncoding:NSUTF8StringEncoding];
    return [payload writeToURL:startupResultURL
                      options:NSDataWritingAtomic
                        error:error];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSError *argumentError = nil;
        BOOL validateRuntimeOnly = NO;
        NSURL *startupResultURL = nil;
        NSURL *xcodeURL = XSHParseXcodeURL(
            argc,
            argv,
            &validateRuntimeOnly,
            &startupResultURL,
            &argumentError
        );
        if (xcodeURL == nil) {
            if (argumentError.code == XSHLegacyHostErrorInvalidArguments) {
                XSHPrintUsage(stderr);
            }
            XSHLog(@"%@", argumentError.localizedDescription);
            return argumentError.code == XSHLegacyHostErrorInvalidArguments
                ? EX_USAGE
                : EX_UNAVAILABLE;
        }

        if (validateRuntimeOnly) {
            NSError *runtimeError = nil;
            XSHPrivateRuntime *runtime = [[XSHPrivateRuntime alloc]
                initWithXcodeURL:xcodeURL
                           error:&runtimeError];
            if (runtime == nil) {
                XSHLog(@"%@", runtimeError.localizedDescription);
                return EX_UNAVAILABLE;
            }
            return EX_OK;
        }

        if (XSHLegacyHostApplication.isDeviceHubRunning) {
            XSHLog(@"Device Hub is already running; refusing to start");
            return EX_TEMPFAIL;
        }

        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        XSHMenuController *menuController = [[XSHMenuController alloc] init];
        [menuController installMainMenu];

        __attribute__((objc_precise_lifetime)) XSHLegacyHostApplication *controller =
            [[XSHLegacyHostApplication alloc]
            initWithXcodeURL:xcodeURL
             menuController:menuController];
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
        if (controller.deviceHubConflictObserved ||
            XSHLegacyHostApplication.isDeviceHubRunning) {
            XSHLog(@"Device Hub launched before startup completed; refusing to connect");
            return EX_TEMPFAIL;
        }
        NSError *startupResultError = nil;
        // LaunchServices reports process creation, not successful simulator-host
        // startup. Acknowledge only after the runtime and device-set owners exist.
        if (!XSHWriteStartupResult(startupResultURL, &startupResultError)) {
            XSHLog(@"could not write startup result: %@",
                   startupResultError.localizedDescription);
            return EX_CANTCREAT;
        }
        [application run];
    }
    return EX_OK;
}
