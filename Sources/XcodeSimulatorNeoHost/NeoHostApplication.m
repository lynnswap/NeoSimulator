#import "NeoHostApplication.h"

#import "DeviceWindowController.h"
#import "HostLogging.h"
#import "MenuController.h"
#import "PrivateInterfaces.h"
#import "PrivateRuntime.h"

static NSString *const XSHDeviceHubBundleIdentifier = @"com.apple.dt.Devices";
static NSString *const XSHLegacySimulatorBundleIdentifier = @"com.apple.iphonesimulator";
static NSString *const XSHIOSSimulatorPlatformIdentifier =
    @"com.apple.platform.iphonesimulator";
static const NSUInteger XSHMaximumScreenIDCandidate = 63;
static const NSUInteger XSHMaximumScreenDiscoveryAttempts = 40;
static const NSTimeInterval XSHScreenDiscoveryRetryInterval = 0.25;

static NSString *XSHConflictingHostName(NSString *bundleIdentifier) {
    if ([bundleIdentifier isEqualToString:XSHDeviceHubBundleIdentifier]) {
        return @"Device Hub";
    }
    if ([bundleIdentifier isEqualToString:XSHLegacySimulatorBundleIdentifier]) {
        return @"Legacy Simulator";
    }
    return nil;
}

@interface XSHNeoHostApplication ()
@property (nonatomic) NSURL *xcodeURL;
@property (nonatomic) XSHMenuController *menuController;
@property (nonatomic, nullable) XSHPrivateRuntime *runtime;
@property (nonatomic, nullable) XSHSimServiceContext *serviceContext;
@property (nonatomic, nullable) XSHSimDeviceSet *deviceSet;
@property (nonatomic) NSMutableDictionary<NSString *, XSHDeviceWindowController *> *sessions;
@property (nonatomic) NSMutableSet<NSString *> *suppressedDeviceIdentifiers;
@property (nonatomic) NSMutableDictionary<NSString *, NSNumber *> *pendingAttempts;
@property (nonatomic) NSMutableSet<NSString *> *reportedConnectionFailures;
@property (nonatomic, nullable) id workspaceLaunchObserver;
@property (atomic, copy, nullable) NSString *conflictingHostName;
@property (atomic) BOOL started;
@property (nonatomic) BOOL shuttingDown;
@property (nonatomic) BOOL hasDeviceSetNotificationToken;
@property (nonatomic) unsigned long long deviceSetNotificationToken;
@end

@implementation XSHNeoHostApplication

+ (NSString *)runningConflictingHostName {
    for (NSString *bundleIdentifier in @[
        XSHDeviceHubBundleIdentifier,
        XSHLegacySimulatorBundleIdentifier,
    ]) {
        if ([NSRunningApplication
                runningApplicationsWithBundleIdentifier:bundleIdentifier].count > 0) {
            return XSHConflictingHostName(bundleIdentifier);
        }
    }
    return nil;
}

- (instancetype)initWithXcodeURL:(NSURL *)xcodeURL
                  menuController:(XSHMenuController *)menuController {
    self = [super init];
    if (self != nil) {
        _xcodeURL = xcodeURL;
        _menuController = menuController;
        _sessions = [NSMutableDictionary dictionary];
        _suppressedDeviceIdentifiers = [NSMutableSet set];
        _pendingAttempts = [NSMutableDictionary dictionary];
        _reportedConnectionFailures = [NSMutableSet set];
        [self installHostConflictObserver];
    }
    return self;
}

- (void)installHostConflictObserver {
    __weak typeof(self) weakSelf = self;
    self.workspaceLaunchObserver = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        NSRunningApplication *application =
            notification.userInfo[NSWorkspaceApplicationKey];
        NSString *conflictingHostName =
            XSHConflictingHostName(application.bundleIdentifier);
        if (conflictingHostName == nil) {
            return;
        }

        weakSelf.conflictingHostName = conflictingHostName;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleHostConflict];
        });
    }];
}

- (BOOL)startWithRuntime:(XSHPrivateRuntime *)runtime error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Neo host startup must run on the main thread");

    NSString *conflictingHostName =
        self.conflictingHostName ?: self.class.runningConflictingHostName;
    if (conflictingHostName != nil) {
        self.conflictingHostName = conflictingHostName;
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorHostConflict,
                [NSString stringWithFormat:
                    @"%@ is running; refusing to connect to CoreSimulator",
                    conflictingHostName]
            );
        }
        return NO;
    }

    NSError *imageError = nil;
    if (![runtime validateLoadedImagesWithError:&imageError]) {
        if (error != NULL) {
            *error = imageError;
        }
        return NO;
    }

    NSString *developerDirectory = [self.xcodeURL.path
        stringByAppendingPathComponent:@"Contents/Developer"];
    NSError *contextError = nil;
    XSHSimServiceContext *serviceContext = [runtime.serviceContextClass
        sharedServiceContextForDeveloperDir:developerDirectory
                                      error:&contextError];
    if (serviceContext == nil) {
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorPrivateRuntime,
                [NSString stringWithFormat:@"could not connect to CoreSimulator: %@",
                                           contextError.localizedDescription ?: @"unknown error"]
            );
        }
        return NO;
    }

    NSError *deviceSetError = nil;
    XSHSimDeviceSet *deviceSet = [serviceContext
        defaultDeviceSetWithError:&deviceSetError];
    if (deviceSet == nil) {
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorPrivateRuntime,
                [NSString stringWithFormat:@"could not open the default simulator device set: %@",
                                           deviceSetError.localizedDescription ?: @"unknown error"]
            );
        }
        return NO;
    }

    NSError *subscriptionError = nil;
    if (![deviceSet subscribeToNotificationsWithError:&subscriptionError]) {
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorPrivateRuntime,
                [NSString stringWithFormat:@"could not subscribe to simulator devices: %@",
                                           subscriptionError.localizedDescription ?: @"unknown error"]
            );
        }
        return NO;
    }

    self.runtime = runtime;
    self.serviceContext = serviceContext;
    self.deviceSet = deviceSet;

    __weak typeof(self) weakSelf = self;
    self.deviceSetNotificationToken = [deviceSet
        registerNotificationHandlerOnQueue:dispatch_get_main_queue()
                                    handler:^(NSDictionary *notification) {
        (void)notification;
        [weakSelf rescanDevices];
    }];
    self.hasDeviceSetNotificationToken = YES;
    self.started = YES;

    conflictingHostName =
        self.conflictingHostName ?: self.class.runningConflictingHostName;
    if (conflictingHostName != nil) {
        self.conflictingHostName = conflictingHostName;
        [self shutdown];
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorHostConflict,
                [NSString stringWithFormat:
                    @"%@ launched during Neo host startup",
                    conflictingHostName]
            );
        }
        return NO;
    }

    [self rescanDevices];
    XSHLog(@"watching the default CoreSimulator device set for booted iOS devices");
    return YES;
}

- (void)rescanDevices {
    NSAssert(NSThread.isMainThread, @"device membership must be updated on the main thread");
    if (!self.started || self.shuttingDown || self.deviceSet == nil) {
        return;
    }

    if (self.conflictingHostName != nil ||
        self.class.runningConflictingHostName != nil) {
        [self handleHostConflict];
        return;
    }

    NSMutableDictionary<NSString *, XSHSimDevice *> *bootedDevices =
        [NSMutableDictionary dictionary];
    for (XSHSimDevice *device in self.deviceSet.availableDevices) {
        NSString *identifier = device.UDID.UUIDString;
        NSString *platformIdentifier = device.runtime.platformIdentifier;
        if (identifier.length == 0 ||
            ![platformIdentifier isEqualToString:XSHIOSSimulatorPlatformIdentifier]) {
            continue;
        }
        if (device.state == XSHSimDeviceStateBooted) {
            bootedDevices[identifier] = device;
        }
    }

    for (NSString *identifier in self.sessions.allKeys.copy) {
        if (bootedDevices[identifier] == nil) {
            XSHDeviceWindowController *session = self.sessions[identifier];
            [self.sessions removeObjectForKey:identifier];
            [session invalidate];
            XSHLog(@"removed simulator window for %@ after shutdown", identifier);
        }
    }

    for (NSString *identifier in self.suppressedDeviceIdentifiers.allObjects) {
        if (bootedDevices[identifier] == nil) {
            [self.suppressedDeviceIdentifiers removeObject:identifier];
        }
    }
    for (NSString *identifier in self.pendingAttempts.allKeys.copy) {
        if (bootedDevices[identifier] == nil) {
            [self.pendingAttempts removeObjectForKey:identifier];
        }
    }
    for (NSString *identifier in self.reportedConnectionFailures.allObjects) {
        if (bootedDevices[identifier] == nil) {
            [self.reportedConnectionFailures removeObject:identifier];
        }
    }

    [bootedDevices enumerateKeysAndObjectsUsingBlock:^(
        NSString *identifier,
        XSHSimDevice *device,
        BOOL *stop
    ) {
        (void)stop;
        if (self.sessions[identifier] == nil &&
            self.pendingAttempts[identifier] == nil &&
            ![self.suppressedDeviceIdentifiers containsObject:identifier] &&
            ![self.reportedConnectionFailures containsObject:identifier]) {
            [self connectDeviceIfReady:device identifier:identifier];
        }
    }];
}

- (void)connectDeviceIfReady:(XSHSimDevice *)device
                  identifier:(NSString *)identifier {
    if (self.sessions[identifier] != nil || self.shuttingDown) {
        return;
    }

    uint32_t screenID = 0;
    if (![self findDefaultIntegratedScreenForDevice:device screenID:&screenID]) {
        [self scheduleScreenDiscoveryForDevice:device identifier:identifier];
        return;
    }

    [self.pendingAttempts removeObjectForKey:identifier];
    [self.reportedConnectionFailures removeObject:identifier];

    if (self.conflictingHostName != nil ||
        self.class.runningConflictingHostName != nil) {
        [self handleHostConflict];
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSError *connectionError = nil;
    XSHDeviceWindowController *session = [[XSHDeviceWindowController alloc]
        initWithDevice:device
               screenID:screenID
                runtime:self.runtime
           closeHandler:^(NSString *closedIdentifier) {
        [weakSelf deviceWindowClosed:closedIdentifier];
    }
                  error:&connectionError];
    if (session == nil) {
        [self reportConnectionFailure:connectionError
                           identifier:identifier
                                 name:device.name];
        return;
    }

    if (self.conflictingHostName != nil ||
        self.class.runningConflictingHostName != nil) {
        [session invalidate];
        [self handleHostConflict];
        return;
    }

    self.sessions[identifier] = session;
    [session showAndActivate];
    XSHLog(@"opened simulator window for %@ (%@)",
           device.name ?: @"iOS Simulator",
           identifier);
}

- (BOOL)findDefaultIntegratedScreenForDevice:(XSHSimDevice *)device
                                     screenID:(uint32_t *)screenID {
    for (uint32_t candidateID = 0;
         candidateID <= XSHMaximumScreenIDCandidate;
         candidateID++) {
        @try {
            XSHSimDeviceScreen *candidate = [[self.runtime.deviceScreenClass alloc]
                initWithDevice:device
                       screenID:candidateID];
            if (candidate != nil &&
                candidate.screen != nil &&
                candidate.isDefault &&
                !candidate.isCarPlay) {
                *screenID = candidateID;
                return YES;
            }
        } @catch (NSException *exception) {
            XSHLog(@"screen candidate %u raised %@ for %@: %@",
                   candidateID,
                   exception.name,
                   device.UDID.UUIDString ?: @"unknown device",
                   exception.reason ?: @"no reason");
        }
    }
    return NO;
}

- (void)scheduleScreenDiscoveryForDevice:(XSHSimDevice *)device
                              identifier:(NSString *)identifier {
    NSUInteger attempt = self.pendingAttempts[identifier].unsignedIntegerValue + 1;
    if (attempt > XSHMaximumScreenDiscoveryAttempts) {
        [self.pendingAttempts removeObjectForKey:identifier];
        if (![self.reportedConnectionFailures containsObject:identifier]) {
            [self.reportedConnectionFailures addObject:identifier];
            XSHLog(@"no default integrated screen became available for %@ (%@)",
                   device.name ?: @"iOS Simulator",
                   identifier);
        }
        return;
    }

    self.pendingAttempts[identifier] = @(attempt);
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(XSHScreenDiscoveryRetryInterval * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil ||
                strongSelf.sessions[identifier] != nil ||
                [strongSelf.suppressedDeviceIdentifiers containsObject:identifier] ||
                device.state != XSHSimDeviceStateBooted) {
                [strongSelf.pendingAttempts removeObjectForKey:identifier];
                return;
            }
            [strongSelf connectDeviceIfReady:device identifier:identifier];
        }
    );
}

- (void)reportConnectionFailure:(NSError *)error
                     identifier:(NSString *)identifier
                           name:(NSString *)name {
    if ([self.reportedConnectionFailures containsObject:identifier]) {
        return;
    }
    [self.reportedConnectionFailures addObject:identifier];
    XSHLog(@"could not open simulator window for %@ (%@): %@",
           name ?: @"iOS Simulator",
           identifier,
           error.localizedDescription ?: @"unknown connection error");
}

- (void)deviceWindowClosed:(NSString *)identifier {
    if (self.shuttingDown) {
        return;
    }
    [self.sessions removeObjectForKey:identifier];
    [self.suppressedDeviceIdentifiers addObject:identifier];
    XSHLog(@"simulator window for %@ will remain closed until the device shuts down",
           identifier);
}

- (void)handleHostConflict {
    NSString *conflictingHostName =
        self.conflictingHostName ?: self.class.runningConflictingHostName;
    if (conflictingHostName == nil) {
        return;
    }

    self.conflictingHostName = conflictingHostName;
    XSHLog(@"%@ appeared; disconnecting every simulator and exiting",
           conflictingHostName);
    [self shutdown];
    [NSApp terminate:nil];
}

- (void)activateDeviceWindows {
    for (XSHDeviceWindowController *session in self.sessions.allValues) {
        [session showAndActivate];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender
                    hasVisibleWindows:(BOOL)hasVisibleWindows {
    (void)sender;
    (void)hasVisibleWindows;
    [self activateDeviceWindows];
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self shutdown];
}

- (void)shutdown {
    if (self.shuttingDown) {
        return;
    }
    self.shuttingDown = YES;
    self.started = NO;

    if (self.hasDeviceSetNotificationToken && self.deviceSet != nil) {
        NSError *error = nil;
        if (![self.deviceSet unregisterNotificationHandler:self.deviceSetNotificationToken
                                                     error:&error]) {
            XSHLog(@"could not unregister CoreSimulator notifications: %@",
                   error.localizedDescription ?: @"unknown error");
        }
        self.hasDeviceSetNotificationToken = NO;
    }

    NSArray<XSHDeviceWindowController *> *sessions = self.sessions.allValues.copy;
    [self.sessions removeAllObjects];
    for (XSHDeviceWindowController *session in sessions) {
        [session invalidate];
    }

    [self.pendingAttempts removeAllObjects];
    self.deviceSet = nil;
    self.serviceContext = nil;
    self.runtime = nil;

    if (self.workspaceLaunchObserver != nil) {
        [NSWorkspace.sharedWorkspace.notificationCenter
            removeObserver:self.workspaceLaunchObserver];
        self.workspaceLaunchObserver = nil;
    }
}

- (void)dealloc {
    [self shutdown];
}

@end
