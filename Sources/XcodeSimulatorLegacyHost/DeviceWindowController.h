#import <AppKit/AppKit.h>

@class XSHPrivateRuntime;
@class XSHSimDevice;

NS_ASSUME_NONNULL_BEGIN

typedef void (^XSHDeviceWindowCloseHandler)(NSString *deviceIdentifier);

@interface XSHDeviceWindowController : NSWindowController <NSWindowDelegate>

@property (nonatomic, readonly) NSString *deviceIdentifier;

- (nullable instancetype)initWithDevice:(XSHSimDevice *)device
                               screenID:(uint32_t)screenID
                                runtime:(XSHPrivateRuntime *)runtime
                           closeHandler:(XSHDeviceWindowCloseHandler)closeHandler
                                  error:(NSError **)error;

- (void)showAndActivate;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
