#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Opaque ownership of dynamically loaded CoreSimulator objects. Swift never
// assumes that our declarations are real Objective-C runtime class names.
@interface XSHDeviceHandle : NSObject
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *runtimeName;
@property (nonatomic, readonly) NSString *platformIdentifier;
@property (nonatomic, readonly) NSUInteger state;
/// `SimDeviceType.productFamilyID`: 1 iPhone, 2 iPad, 3 TV, 4 Watch, 7 Vision.
@property (nonatomic, readonly) NSInteger productFamily;
/// `SimRuntime.version`, packed as major << 16 | minor << 8 | patch.
@property (nonatomic, readonly) uint32_t runtimeVersion;
- (BOOL)supportsFeature:(NSString *)feature;
- (BOOL)toggleAppearanceWithError:(NSError **)error;
- (BOOL)shakeWithError:(NSError **)error;
@end

@interface XSHDeviceSetHandle : NSObject
- (nullable instancetype)initWithServiceClass:(Class)serviceClass
                          developerDirectory:(NSString *)developerDirectory
                                       error:(NSError **)error;
- (nullable NSArray<XSHDeviceHandle *> *)readDevicesWithError:(NSError **)error;
- (nullable NSNumber *)observeWithHandler:(void (^)(void))handler error:(NSError **)error;
- (BOOL)stopObserving:(unsigned long long)token error:(NSError **)error;
@end

FOUNDATION_EXPORT NSNumber * _Nullable XSHFindDefaultScreen(Class screenClass, XSHDeviceHandle *device);
FOUNDATION_EXPORT NSView * _Nullable XSHCreateDisplay(Class factoryClass, XSHDeviceHandle *device,
                                                     uint32_t screenID, NSError **error);
FOUNDATION_EXPORT id _Nullable XSHCreateHIDClient(Class clientClass, XSHDeviceHandle *device, NSError **error);
FOUNDATION_EXPORT BOOL XSHSendButton(id client, void *messageFunction, uint32_t button, NSError **error);

NS_ASSUME_NONNULL_END
