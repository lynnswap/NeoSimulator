#import "PrivateRuntime.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#import "HostLogging.h"

static NSString *const XSHCoreSimulatorFrameworkPath =
    @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework";

@interface XSHPrivateRuntime ()
@property (nonatomic, readwrite) NSURL *xcodeURL;
@property (nonatomic, readwrite) Class serviceContextClass;
@property (nonatomic, readwrite) Class deviceScreenClass;
@property (nonatomic, readwrite) Class displayFactoryClass;
@property (nonatomic, readwrite) Class legacyHIDClientClass;
@property (nonatomic, readwrite) XSHIndigoHIDMessageForButtonFunction messageForButton;
@property (nonatomic, readwrite) void *showDeviceChromeFunction;
@property (nonatomic, readwrite) void *renderScaleGetterFunction;
@property (nonatomic, readwrite) void *deviceRotationSetterFunction;
@property (nonatomic, readwrite) void *disconnectDisplayFunction;
@property (nonatomic, readwrite) void *beginResizeFunction;
@property (nonatomic, readwrite) void *resizeToFunction;
@property (nonatomic, readwrite) void *endResizeFunction;
@end

@implementation XSHPrivateRuntime {
    void *_coreSimulatorHandle;
    void *_simulatorKitHandle;
    void *_playgroundSimulatorHandle;
}

- (nullable instancetype)initWithXcodeURL:(NSURL *)xcodeURL
                                    error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _xcodeURL = xcodeURL.URLByResolvingSymlinksInPath;

    NSURL *coreSimulatorURL = [NSURL fileURLWithPath:XSHCoreSimulatorFrameworkPath
                                        isDirectory:YES];
    NSURL *simulatorKitURL = [_xcodeURL URLByAppendingPathComponent:
        @"Contents/SharedFrameworks/SimulatorKit.framework"
                                                    isDirectory:YES];
    NSURL *playgroundSimulatorURL = [_xcodeURL URLByAppendingPathComponent:
        @"Contents/Frameworks/IDEPlaygroundSimulator.framework"
                                                       isDirectory:YES];

    _coreSimulatorHandle = [self loadFrameworkAtURL:coreSimulatorURL error:error];
    if (_coreSimulatorHandle == NULL) {
        return nil;
    }

    _simulatorKitHandle = [self loadFrameworkAtURL:simulatorKitURL error:error];
    if (_simulatorKitHandle == NULL) {
        return nil;
    }

    _playgroundSimulatorHandle = [self loadFrameworkAtURL:playgroundSimulatorURL
                                                     error:error];
    if (_playgroundSimulatorHandle == NULL) {
        return nil;
    }

    _messageForButton = (XSHIndigoHIDMessageForButtonFunction)[self
        requiredSymbol:"IndigoHIDMessageForButton"
                handle:_simulatorKitHandle
                 error:error];
    if (_messageForButton == NULL) {
        return nil;
    }

    _showDeviceChromeFunction = [self
        requiredSymbol:"$s12SimulatorKit14SimDisplayViewC16showDeviceChromeSbvsTj"
                handle:_simulatorKitHandle
                 error:error];
    _renderScaleGetterFunction = [self
        requiredSymbol:"$s12SimulatorKit14SimDisplayViewC11renderScale12CoreGraphics7CGFloatVvgTj"
                handle:_simulatorKitHandle
                 error:error];
    _deviceRotationSetterFunction = [self
        requiredSymbol:"$s12SimulatorKit14SimDisplayViewC14deviceRotation10Foundation11MeasurementVySo11NSUnitAngleCGvsTj"
                handle:_simulatorKitHandle
                 error:error];
    _disconnectDisplayFunction = [self
        requiredSymbol:"$s12SimulatorKit14SimDisplayViewC10disconnect10completionyyycSg_tFTj"
                handle:_simulatorKitHandle
                 error:error];
    _beginResizeFunction = [self
        requiredSymbol:"$s12SimulatorKit14SimDisplayViewC11beginResizeyyFTj"
                handle:_simulatorKitHandle
                 error:error];
    _resizeToFunction = [self
        requiredSymbol:"$s12SimulatorKit14SimDisplayViewC8resizeTo4sizeySo6CGSizeV_tFTj"
                handle:_simulatorKitHandle
                 error:error];
    _endResizeFunction = [self
        requiredSymbol:"$s12SimulatorKit14SimDisplayViewC9endResizeyyFTj"
                handle:_simulatorKitHandle
                 error:error];
    if (_showDeviceChromeFunction == NULL ||
        _renderScaleGetterFunction == NULL ||
        _deviceRotationSetterFunction == NULL ||
        _disconnectDisplayFunction == NULL ||
        _beginResizeFunction == NULL ||
        _resizeToFunction == NULL ||
        _endResizeFunction == NULL) {
        return nil;
    }

    _serviceContextClass = NSClassFromString(@"SimServiceContext");
    _deviceScreenClass = NSClassFromString(@"SimulatorKit.SimDeviceScreen");
    _displayFactoryClass = NSClassFromString(
        @"IDEPlaygroundSimulator.IDESimulatorPlaygroundUntil"
    );
    _legacyHIDClientClass = NSClassFromString(
        @"SimulatorKit.SimDeviceLegacyHIDClient"
    );

    if (![self validateRequiredClassesWithError:error]) {
        return nil;
    }
    if (![self validateLoadedImagesWithError:error]) {
        return nil;
    }

    return self;
}

- (nullable void *)loadFrameworkAtURL:(NSURL *)frameworkURL
                                error:(NSError **)error {
    NSBundle *bundle = [NSBundle bundleWithURL:frameworkURL];
    NSString *executablePath = bundle.executablePath;
    if (bundle == nil || executablePath.length == 0) {
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorInvalidInstallation,
                [NSString stringWithFormat:@"missing framework at %@", frameworkURL.path]
            );
        }
        return NULL;
    }

    dlerror();
    void *handle = dlopen(executablePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        const char *detail = dlerror();
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorPrivateRuntime,
                [NSString stringWithFormat:@"could not load %@: %s",
                                           executablePath,
                                           detail != NULL ? detail : "unknown error"]
            );
        }
        return NULL;
    }

    return handle;
}

- (nullable void *)requiredSymbol:(const char *)name
                           handle:(void *)handle
                            error:(NSError **)error {
    dlerror();
    void *symbol = dlsym(handle, name);
    const char *detail = dlerror();
    if (symbol == NULL || detail != NULL) {
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorPrivateRuntime,
                [NSString stringWithFormat:@"required private symbol %s is unavailable: %s",
                                           name,
                                           detail != NULL ? detail : "not found"]
            );
        }
        return NULL;
    }
    return symbol;
}

- (BOOL)validateRequiredClassesWithError:(NSError **)error {
    Class deviceSetClass = NSClassFromString(@"SimDeviceSet");
    Class deviceClass = NSClassFromString(@"SimDevice");
    Class runtimeClass = NSClassFromString(@"SimRuntime");

    return [self validateClass:self.serviceContextClass
                          name:@"SimServiceContext"
                classSelectors:@[
                    NSStringFromSelector(
                        @selector(sharedServiceContextForDeveloperDir:error:)
                    ),
                ]
             instanceSelectors:@[
                    NSStringFromSelector(@selector(defaultDeviceSetWithError:)),
                ]
                         error:error] &&
        [self validateClass:deviceSetClass
                       name:@"SimDeviceSet"
             classSelectors:@[]
          instanceSelectors:@[
                NSStringFromSelector(@selector(subscribeToNotificationsWithError:)),
                NSStringFromSelector(@selector(availableDevices)),
                NSStringFromSelector(
                    @selector(registerNotificationHandlerOnQueue:handler:)
                ),
                NSStringFromSelector(
                    @selector(unregisterNotificationHandler:error:)
                ),
            ]
                      error:error] &&
        [self validateClass:deviceClass
                       name:@"SimDevice"
             classSelectors:@[]
          instanceSelectors:@[
                NSStringFromSelector(@selector(state)),
                NSStringFromSelector(@selector(name)),
                NSStringFromSelector(@selector(UDID)),
                NSStringFromSelector(@selector(runtime)),
                NSStringFromSelector(@selector(currentUIInterfaceStyle)),
                NSStringFromSelector(@selector(setUIInterfaceStyle:error:)),
                NSStringFromSelector(@selector(postDarwinNotification:error:)),
            ]
                      error:error] &&
        [self validateClass:runtimeClass
                       name:@"SimRuntime"
             classSelectors:@[]
          instanceSelectors:@[
                NSStringFromSelector(@selector(name)),
                NSStringFromSelector(@selector(platformIdentifier)),
            ]
                      error:error] &&
        [self validateClass:self.deviceScreenClass
                       name:@"SimulatorKit.SimDeviceScreen"
             classSelectors:@[]
          instanceSelectors:@[
                NSStringFromSelector(@selector(initWithDevice:screenID:)),
                NSStringFromSelector(@selector(screen)),
                NSStringFromSelector(@selector(isDefault)),
                NSStringFromSelector(@selector(isCarPlay)),
            ]
                      error:error] &&
        [self validateClass:self.displayFactoryClass
                       name:@"IDEPlaygroundSimulator.IDESimulatorPlaygroundUntil"
             classSelectors:@[
                NSStringFromSelector(
                    @selector(createSimDisplayViewWithDevice:simScreenID:)
                ),
            ]
          instanceSelectors:@[]
                      error:error] &&
        [self validateClass:self.legacyHIDClientClass
                       name:@"SimulatorKit.SimDeviceLegacyHIDClient"
             classSelectors:@[]
          instanceSelectors:@[
                NSStringFromSelector(@selector(initWithDevice:error:)),
                NSStringFromSelector(
                    @selector(sendWithMessage:freeWhenDone:completionQueue:completion:)
                ),
            ]
                      error:error];
}

- (BOOL)validateClass:(Class)cls
                 name:(NSString *)name
       classSelectors:(NSArray<NSString *> *)classSelectorNames
    instanceSelectors:(NSArray<NSString *> *)instanceSelectorNames
                error:(NSError **)error {
    if (cls == Nil) {
        if (error != NULL) {
            *error = XSHNeoHostError(
                XSHNeoHostErrorPrivateRuntime,
                [NSString stringWithFormat:@"required private class %@ is unavailable", name]
            );
        }
        return NO;
    }

    for (NSString *selectorName in classSelectorNames) {
        if (![cls respondsToSelector:NSSelectorFromString(selectorName)]) {
            if (error != NULL) {
                *error = XSHNeoHostError(
                    XSHNeoHostErrorPrivateRuntime,
                    [NSString stringWithFormat:@"%@ does not provide +%@",
                                               name,
                                               selectorName]
                );
            }
            return NO;
        }
    }

    for (NSString *selectorName in instanceSelectorNames) {
        if (class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) == NULL) {
            if (error != NULL) {
                *error = XSHNeoHostError(
                    XSHNeoHostErrorPrivateRuntime,
                    [NSString stringWithFormat:@"%@ does not provide -%@",
                                               name,
                                               selectorName]
                );
            }
            return NO;
        }
    }

    return YES;
}

- (BOOL)validateLoadedImagesWithError:(NSError **)error {
    NSString *selectedXcodePrefix = [self.xcodeURL.path stringByAppendingString:@"/"];

    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *imageName = _dyld_get_image_name(index);
        if (imageName == NULL) {
            continue;
        }

        NSString *path = [@(imageName) stringByResolvingSymlinksInPath];
        if ([path containsString:@"/DeviceKit.framework/"] ||
            [path containsString:@"/DeviceHub.app/"]) {
            if (error != NULL) {
                *error = XSHNeoHostError(
                    XSHNeoHostErrorPrivateRuntime,
                    [NSString stringWithFormat:@"forbidden Device Hub component is loaded: %@",
                                               path]
                );
            }
            return NO;
        }

        BOOL isSelectedFramework =
            [path containsString:@"/SimulatorKit.framework/"] ||
            [path containsString:@"/IDEPlaygroundSimulator.framework/"];
        if (isSelectedFramework && ![path hasPrefix:selectedXcodePrefix]) {
            if (error != NULL) {
                *error = XSHNeoHostError(
                    XSHNeoHostErrorPrivateRuntime,
                    [NSString stringWithFormat:
                        @"private simulator framework came from a different Xcode: %@",
                        path]
                );
            }
            return NO;
        }
    }

    return YES;
}

@end
