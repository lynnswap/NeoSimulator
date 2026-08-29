#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct IndigoHIDMessageStruct IndigoHIDMessageStruct;
typedef IndigoHIDMessageStruct * _Nullable (*XSHIndigoHIDMessageForButtonFunction)(
    uint32_t button,
    uint32_t state,
    uint32_t target
);

static const NSUInteger XSHSimDeviceStateBooted = 3;
static const uint32_t XSHIntegratedDisplayHIDTarget = 0x33;
static const uint32_t XSHHomeButton = 0;
static const uint32_t XSHSoftwareKeyboardButton = 0x3f0;
static const uint32_t XSHButtonStateDown = 1;
static const uint32_t XSHButtonStateUp = 2;

@interface XSHSimServiceContext : NSObject
+ (nullable instancetype)sharedServiceContextForDeveloperDir:(NSString *)developerDir
                                                       error:(NSError **)error;
- (nullable id)defaultDeviceSetWithError:(NSError **)error;
@end

@interface XSHSimDeviceSet : NSObject
- (BOOL)subscribeToNotificationsWithError:(NSError **)error;
- (NSArray *)availableDevices;
- (unsigned long long)registerNotificationHandlerOnQueue:(dispatch_queue_t)queue
                                                  handler:(void (^)(NSDictionary *notification))handler;
- (BOOL)unregisterNotificationHandler:(unsigned long long)handler
                                 error:(NSError **)error;
@end

@interface XSHSimRuntime : NSObject
- (nullable NSString *)platformIdentifier;
@end

@interface XSHSimDevice : NSObject
- (NSUInteger)state;
- (nullable NSString *)name;
- (nullable NSUUID *)UDID;
- (nullable XSHSimRuntime *)runtime;
@end

@interface XSHSimDeviceScreen : NSObject
- (nullable instancetype)initWithDevice:(XSHSimDevice *)device
                               screenID:(uint32_t)screenID;
- (BOOL)isDefault;
- (BOOL)isCarPlay;
- (nullable id)screen;
@end

@interface XSHLegacyHIDClient : NSObject
- (nullable instancetype)initWithDevice:(XSHSimDevice *)device
                                  error:(NSError **)error;
- (void)sendWithMessage:(IndigoHIDMessageStruct *)message
           freeWhenDone:(BOOL)freeWhenDone
        completionQueue:(nullable dispatch_queue_t)completionQueue
             completion:(nullable id)completion;
@end

@interface XSHDisplayFactory : NSObject
+ (nullable NSView *)createSimDisplayViewWithDevice:(XSHSimDevice *)device
                                        simScreenID:(uint32_t)screenID;
@end

NS_ASSUME_NONNULL_END
