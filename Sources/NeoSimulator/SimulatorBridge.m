#import "SimulatorBridge.h"
#import "PrivateInterfaces.h"

static NSError *XSHBridgeError(NSString *message) {
    return [NSError errorWithDomain:@"dev.lynnswap.NeoSimulator" code:5
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void XSHRecordException(NSException *exception, NSError **error) {
    if (error != NULL) {
        *error = XSHBridgeError([NSString stringWithFormat:@"%@: %@",
                                exception.name, exception.reason ?: @"Private simulator operation failed"]);
    }
}

@interface XSHDeviceHandle ()
@property (nonatomic) XSHSimDevice *device;
- (instancetype)initWithDevice:(XSHSimDevice *)device;
@end

@implementation XSHDeviceHandle

- (instancetype)initWithDevice:(XSHSimDevice *)device {
    self = [super init];
    if (self != nil) {
        _device = device;
        _identifier = device.UDID.UUIDString;
        _name = device.name ?: @"iOS Simulator";
        _runtimeName = device.runtime.name ?: @"iOS";
        _platformIdentifier = device.runtime.platformIdentifier ?: @"";
    }
    return self;
}

- (NSUInteger)state { return self.device.state; }

- (BOOL)toggleAppearanceWithError:(NSError **)error {
    @try {
        return [self.device setUIInterfaceStyle:self.device.currentUIInterfaceStyle == 2 ? 1 : 2 error:error];
    } @catch (NSException *exception) {
        XSHRecordException(exception, error);
        return NO;
    }
}

- (BOOL)shakeWithError:(NSError **)error {
    @try {
        return [self.device postDarwinNotification:@"com.apple.UIKit.SimulatorShake" error:error];
    } @catch (NSException *exception) {
        XSHRecordException(exception, error);
        return NO;
    }
}
@end

@implementation XSHDeviceSetHandle {
    XSHSimServiceContext *_context;
    XSHSimDeviceSet *_deviceSet;
}

- (instancetype)initWithServiceClass:(Class)serviceClass
                 developerDirectory:(NSString *)developerDirectory
                              error:(NSError **)error {
    self = [super init];
    if (self == nil) { return nil; }
    @try {
        _context = [serviceClass sharedServiceContextForDeveloperDir:developerDirectory error:error];
        if (_context == nil) { return nil; }
        _deviceSet = [_context defaultDeviceSetWithError:error];
        if (_deviceSet == nil || ![_deviceSet subscribeToNotificationsWithError:error]) { return nil; }
    } @catch (NSException *exception) {
        XSHRecordException(exception, error);
        return nil;
    }
    return self;
}

- (NSArray<XSHDeviceHandle *> *)readDevicesWithError:(NSError **)error {
    @try {
        NSMutableArray<XSHDeviceHandle *> *devices = [NSMutableArray array];
        for (XSHSimDevice *device in _deviceSet.availableDevices) {
            if (device.UDID != nil) {
                [devices addObject:[[XSHDeviceHandle alloc] initWithDevice:device]];
            }
        }
        return devices;
    } @catch (NSException *exception) {
        XSHRecordException(exception, error);
        return nil;
    }
}

- (NSNumber *)observeWithHandler:(void (^)(void))handler error:(NSError **)error {
    @try {
        return @([_deviceSet registerNotificationHandlerOnQueue:dispatch_get_main_queue()
                                                     handler:^(NSDictionary *notification) {
            (void)notification;
            handler();
        }]);
    } @catch (NSException *exception) {
        XSHRecordException(exception, error);
        return nil;
    }
}

- (BOOL)stopObserving:(unsigned long long)token error:(NSError **)error {
    @try {
        return [_deviceSet unregisterNotificationHandler:token error:error];
    } @catch (NSException *exception) {
        XSHRecordException(exception, error);
        return NO;
    }
}
@end

NSNumber *XSHFindDefaultScreen(Class screenClass, XSHDeviceHandle *device) {
    // Invalid screen IDs can throw in SimulatorKit; absence is retried during boot.
    for (uint32_t identifier = 0; identifier <= 63; identifier++) {
        @try {
            XSHSimDeviceScreen *screen = [[screenClass alloc] initWithDevice:device.device screenID:identifier];
            if (screen.screen != nil && screen.isDefault && !screen.isCarPlay) {
                return @(identifier);
            }
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
    return nil;
}

NSView *XSHCreateDisplay(Class factoryClass, XSHDeviceHandle *device, uint32_t screenID, NSError **error) {
    @try {
        NSView *view = [factoryClass createSimDisplayViewWithDevice:device.device simScreenID:screenID];
        if (view == nil && error != NULL) { *error = XSHBridgeError(@"SimulatorKit returned no display"); }
        return view;
    } @catch (NSException *exception) {
        XSHRecordException(exception, error);
        return nil;
    }
}

id XSHCreateHIDClient(Class clientClass, XSHDeviceHandle *device, NSError **error) {
    @try {
        return [[clientClass alloc] initWithDevice:device.device error:error];
    } @catch (NSException *exception) {
        XSHRecordException(exception, error);
        return nil;
    }
}

BOOL XSHSendButton(id client, void *messageFunction, uint32_t button, NSError **error) {
    XSHIndigoHIDMessageForButtonFunction makeMessage = (XSHIndigoHIDMessageForButtonFunction)messageFunction;
    IndigoHIDMessageStruct *down = makeMessage(button, XSHButtonStateDown, XSHIntegratedDisplayHIDTarget);
    IndigoHIDMessageStruct *up = makeMessage(button, XSHButtonStateUp, XSHIntegratedDisplayHIDTarget);
    if (down == NULL || up == NULL) {
        free(down);
        free(up);
        if (error != NULL) { *error = XSHBridgeError(@"Could not allocate simulator button input"); }
        return NO;
    }
    // Each call transfers ownership. Catching an exception and freeing or retrying
    // could reuse a message that SimulatorKit has already enqueued.
    [client sendWithMessage:down freeWhenDone:YES completionQueue:nil completion:nil];
    [client sendWithMessage:up freeWhenDone:YES completionQueue:nil completion:nil];
    return YES;
}
