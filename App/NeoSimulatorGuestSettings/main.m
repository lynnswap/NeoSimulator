#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <TargetConditionals.h>
#import <math.h>
#import <signal.h>
#import <unistd.h>
#import <string.h>
#import <dlfcn.h>
#import <errno.h>
#import <stdlib.h>

#if !TARGET_OS_SIMULATOR
#error Build the guest settings helper for the iOS Simulator.
#endif

// Declarations match the installed DBS Objective-C methods. Calls are checked
// against NSMethodSignature before invoking this private runtime surface.
@protocol GuestDisplayZoomMode <NSObject>
- (NSUInteger)displayZoomOption;
- (NSString *)localizedName;
- (CGSize)size;
@end

@protocol GuestDisplayZoomController <NSObject>
- (NSDictionary<NSString *, id<GuestDisplayZoomMode>> *)displayZoomModes;
- (id<GuestDisplayZoomMode>)currentDisplayZoomMode;
@end

@protocol GuestDisplayZoomFactory <NSObject>
+ (id<GuestDisplayZoomController>)defaultController;
@end

static NSError *SettingsError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"NeoSimulatorGuestSettings" code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}


@protocol GuestRelaunchActionFactory <NSObject>
+ (id)actionWithReason:(NSString *)reason options:(NSUInteger)options targetURL:(NSURL *)url;
@end

@protocol GuestSystemService <NSObject>
- (void)sendActions:(NSSet *)actions withResult:(void (^)(NSError *error))result;
@end

@protocol GuestSystemServiceFactory <NSObject>
+ (id<GuestSystemService>)sharedService;
@end

// These C entry points are exported by the simulator's SimFramebuffer dependency.
typedef CFTypeRef (*ConnectionCreate)(CFAllocatorRef, CFStringRef);
typedef bool (*ConnectionConnect)(CFTypeRef, CFErrorRef *);
typedef CFTypeRef (*ConnectionCopyDisplay)(CFTypeRef, uint32_t);
typedef bool (*DisplaySetCanvasSize)(CFTypeRef, CGSize, CFErrorRef *);
static volatile sig_atomic_t CanvasApplied = 0;

static NSError *ApplyMode(id<GuestDisplayZoomMode> mode, void (^completion)(NSError *)) {
    ConnectionCreate create = (ConnectionCreate)dlsym(RTLD_DEFAULT, "SFBConnectionCreate");
    ConnectionConnect connect = (ConnectionConnect)dlsym(RTLD_DEFAULT, "SFBConnectionConnect");
    ConnectionCopyDisplay copyDisplay = (ConnectionCopyDisplay)dlsym(RTLD_DEFAULT, "SFBConnectionCopyDisplay");
    DisplaySetCanvasSize setCanvas = (DisplaySetCanvasSize)dlsym(RTLD_DEFAULT, "SFBDisplaySetCanvasSize");
    Class actionFactory = NSClassFromString(@"SBSRelaunchAction");
    Class serviceFactory = NSClassFromString(@"FBSSystemService");
    if (!create || !connect || !copyDisplay || !setCanvas
        || ![actionFactory respondsToSelector:@selector(actionWithReason:options:targetURL:)]
        || ![serviceFactory respondsToSelector:@selector(sharedService)]) {
        return SettingsError(6, @"The selected runtime does not supply the Display Zoom apply APIs.");
    }
    id action = [(Class<GuestRelaunchActionFactory>)actionFactory actionWithReason:@"magnify mode" options:1 targetURL:nil];
    id<GuestSystemService> service = [(Class<GuestSystemServiceFactory>)serviceFactory sharedService];
    if (!action || ![service respondsToSelector:@selector(sendActions:withResult:)]) {
        return SettingsError(6, @"The native interface relaunch service is unavailable.");
    }
    CFTypeRef connection = create(kCFAllocatorDefault, CFSTR("display_settings"));
    if (!connection) { return SettingsError(7, @"Could not create the display settings framebuffer connection."); }
    CFErrorRef failure = NULL;
    bool connected = connect(connection, &failure);
    CFTypeRef display = connected ? copyDisplay(connection, 1) : NULL;
    bool applied = display && setCanvas(display, mode.size, &failure);
    if (display) { CFRelease(display); }
    CFRelease(connection);
    NSError *error = CFBridgingRelease(failure);
    if (!applied) { return error ?: SettingsError(7, @"The framebuffer did not apply Display Zoom and supplied no error."); }
    CanvasApplied = 1;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("DBSMagnifyModeDidChangeNotification"), NULL, NULL, true);
    // Native DBS sends this SpringBoard action; retain its completion instead of
    // exiting after the void DBS setter has merely logged a framebuffer failure.
    dispatch_async(dispatch_get_main_queue(), ^{
        [service sendActions:[NSSet setWithObject:action] withResult:completion];
    });
    return nil;
}

static BOOL CheckGetter(id receiver, SEL selector, const char *returnType, NSError **error) {
    NSMethodSignature *signature = [receiver methodSignatureForSelector:selector];
    BOOL matches = signature && signature.numberOfArguments == 2;
    if (matches) {
        const char *actual = signature.methodReturnType;
        matches = returnType[0] == '@' ? actual[0] == '@' : strcmp(actual, returnType) == 0;
    }
    if (!matches && error) {
        *error = SettingsError(2, [NSString stringWithFormat:@"The installed API has no matching getter for %@.",
                               NSStringFromSelector(selector)]);
    }
    return matches;
}

static NSDictionary *ModeJSON(id candidate, NSError **error) {
    if (!CheckGetter(candidate, @selector(displayZoomOption), @encode(NSUInteger), error)
        || !CheckGetter(candidate, @selector(localizedName), @encode(id), error)
        || !CheckGetter(candidate, @selector(size), @encode(CGSize), error)) { return nil; }
    id<GuestDisplayZoomMode> mode = candidate;
    NSString *name = [mode localizedName];
    if (name && ![name isKindOfClass:NSString.class]) {
        if (error) { *error = SettingsError(3, @"The mode's native name is not a string."); }
        return nil;
    }
    CGSize size = [mode size];
    if (!isfinite(size.width) || !isfinite(size.height)) {
        if (error) { *error = SettingsError(3, @"The native mode has non-finite dimensions that JSON cannot represent."); }
        return nil;
    }
    return @{@"rawMode": @([mode displayZoomOption]), @"nativeName": name ?: NSNull.null,
             @"width": @(size.width), @"height": @(size.height)};
}

static void Deadline(int signal) {
    const char json[] = "{\"schemaVersion\":1,\"success\":false,\"modes\":[],\"current\":null,\"stage\":\"deadline\",\"error\":{\"domain\":\"NeoSimulatorGuestSettings\",\"code\":124,\"description\":\"The guest settings helper exceeded its 15-second process deadline.\"}}\n";
    const char message[] = "The guest settings helper exceeded its 15-second process deadline.\n";
    const char partial[] = "{\"success\":false,\"modes\":[],\"current\":null,\"canvasApplied\":true,\"error\":{\"description\":\"Display Zoom was applied, but the interface relaunch result did not arrive before the helper deadline.\"}}\n";
    (void)write(STDOUT_FILENO, CanvasApplied ? partial : json, CanvasApplied ? sizeof(partial) - 1 : sizeof(json) - 1);
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static int Emit(NSDictionary *result, int status) {
    // No signal can interrupt the one JSON write after the private API returns.
    alarm(0);
    NSError *error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:&error];
    if (!data) {
        fprintf(stderr, "JSON serialization failed: %s\n", error.localizedDescription.UTF8String);
        return 74;
    }
    if (fwrite(data.bytes, 1, data.length, stdout) != data.length || fputc('\n', stdout) == EOF) {
        fprintf(stderr, "Could not write the JSON result.\n");
        return 74;
    }
    return status;
}

int main(int argc, const char *argv[]) {
    struct sigaction action = {0};
    action.sa_handler = Deadline;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGALRM, &action, NULL) != 0) {
        perror("Could not install the helper deadline");
        return 71;
    }
    alarm(15);
    @autoreleasepool {
        NSMutableDictionary *result = [@{@"schemaVersion": @1, @"success": @NO,
            @"modes": @[], @"current": NSNull.null} mutableCopy];
        NSString *stage = @"arguments";
        NSError *error;
        @try {
            BOOL writing = argc == 4 && strcmp(argv[2], "set") == 0;
            char *end = NULL;
            errno = 0;
            unsigned long long requested = writing ? strtoull(argv[3], &end, 10) : 0;
            if ((argc != 3 && !writing) || strcmp(argv[1], "display-zoom")
                || (!writing && strcmp(argv[2], "read"))
                || (writing && (errno || !argv[3][0] || argv[3][0] == '-' || *end))) {
                error = SettingsError(1, @"Usage: NeoSimulatorGuestSettings display-zoom read | set <raw-mode>");
            } else {
                stage = @"runtime";
                NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
                NSString *runtimeRoot = environment[@"SIMULATOR_ROOT"];
                if (!runtimeRoot.length) {
                    error = SettingsError(1, @"SIMULATOR_ROOT is unavailable. Run this simulator binary through simctl spawn.");
                } else {
                    NSString *framework = [runtimeRoot stringByAppendingPathComponent:
                        @"System/Library/PrivateFrameworks/Settings/DisplayAndBrightnessSettings.framework"];
                    result[@"runtimeRoot"] = runtimeRoot;
                    result[@"runtimeVersion"] = NSProcessInfo.processInfo.operatingSystemVersionString;
                    result[@"deviceIdentifier"] = environment[@"SIMULATOR_UDID"] ?: NSNull.null;
                    result[@"framework"] = framework;
                    stage = @"load";
                    NSBundle *bundle = [NSBundle bundleWithPath:framework];
                    if (!bundle) {
                        error = SettingsError(1, @"The selected runtime does not contain the DisplayAndBrightnessSettings framework bundle.");
                    } else {
                        BOOL loaded = [bundle loadAndReturnError:&error];
                        if (!loaded && !error) { error = SettingsError(1, @"The framework did not load and supplied no NSError."); }
                        if (loaded) {
                        stage = @"controller";
                        Class factory = NSClassFromString(@"DBSDisplayZoomConfigurationController");
                        if (CheckGetter(factory, @selector(defaultController), @encode(id), &error)) {
                            id<GuestDisplayZoomController> controller = [(Class<GuestDisplayZoomFactory>)factory defaultController];
                            if (CheckGetter(controller, @selector(displayZoomModes), @encode(id), &error)
                                && CheckGetter(controller, @selector(currentDisplayZoomMode), @encode(id), &error)) {
                                stage = @"modes";
                                id candidate = [controller displayZoomModes];
                                if (![candidate isKindOfClass:NSDictionary.class]) {
                                    error = SettingsError(3, @"The native modes API did not return a dictionary.");
                                } else {
                                    NSDictionary *nativeModes = candidate;
                                    NSMutableArray *modes = NSMutableArray.array;
                                    for (id key in nativeModes) {
                                        if (![key isKindOfClass:NSString.class]) {
                                            error = SettingsError(3, @"A native mode key is not a string.");
                                            break;
                                        }
                                        NSDictionary *mode = ModeJSON(nativeModes[key], &error);
                                        if (!mode) { break; }
                                        NSMutableDictionary *entry = mode.mutableCopy;
                                        entry[@"key"] = key;
                                        [modes addObject:entry];
                                    }
                                    [modes sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                                        return [a[@"key"] compare:b[@"key"]];
                                    }];
                                    result[@"modes"] = modes;
                                    if (!error) {
                                        result[@"hasNativeModes"] = modes.count ? @YES : @NO;
                                        if (modes.count == 0) {
                                            result[@"status"] = @"no-native-modes";
                                            result[@"success"] = @YES;
                                            if (writing) { error = SettingsError(8, @"This device supplied no Display Zoom modes to apply."); }
                                        } else {
                                            stage = @"current";
                                            id<GuestDisplayZoomMode> current = [controller currentDisplayZoomMode];
                                            if (!current) {
                                                error = SettingsError(4, @"The native API returned no current mode. Its service may be unavailable, or the current canvas may not match a supplied mode; the API provides no NSError for this result.");
                                            } else {
                                                NSDictionary *currentMode = ModeJSON(current, &error);
                                                if (currentMode) {
                                                    result[@"current"] = currentMode;
                                                    result[@"status"] = @"read";
                                                    result[@"success"] = @YES;
                                                    if (writing) {
                                                        stage = @"apply";
                                                        id<GuestDisplayZoomMode> selected = nil;
                                                        for (id<GuestDisplayZoomMode> mode in nativeModes.allValues) {
                                                            if (mode.displayZoomOption == requested) { selected = mode; break; }
                                                        }
                                                        if (!selected) {
                                                            error = SettingsError(8, @"The selected Display Zoom mode is not supplied by this device.");
                                                        } else if (current.displayZoomOption != requested) {
                                                            result[@"success"] = @NO;
                                                            error = ApplyMode(selected, ^(NSError *relaunchError) {
                                                                result[@"canvasApplied"] = @YES;
                                                                result[@"stage"] = @"relaunch";
                                                                result[@"success"] = relaunchError ? @NO : @YES;
                                                                if (relaunchError) {
                                                                    result[@"error"] = @{@"domain": relaunchError.domain,
                                                                        @"code": @(relaunchError.code), @"description": relaunchError.localizedDescription};
                                                                }
                                                                exit(Emit(result, relaunchError ? 1 : 0));
                                                            });
                                                            if (!error) { dispatch_main(); }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        }
                    }
                }
            }
        } @catch (NSException *exception) {
            error = SettingsError(5, [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]);
        }
        if (error) {
            result[@"canvasApplied"] = CanvasApplied ? @YES : @NO;
            result[@"success"] = @NO;
            result[@"stage"] = stage;
            result[@"error"] = @{@"domain": error.domain, @"code": @(error.code),
                                 @"description": error.localizedDescription};
            return Emit(result, 1);
        }
        return Emit(result, [result[@"success"] boolValue] ? 0 : 1);
    }
}
