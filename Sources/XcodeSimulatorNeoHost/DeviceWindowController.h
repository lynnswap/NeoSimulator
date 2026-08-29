#import <AppKit/AppKit.h>

@class XSHPrivateRuntime;
@class XSHSimDevice;

NS_ASSUME_NONNULL_BEGIN

typedef void (^XSHDeviceWindowCloseHandler)(NSString *deviceIdentifier);

@interface XSHDeviceWindowController : NSWindowController <NSWindowDelegate>

@property (nonatomic, readonly) NSString *deviceIdentifier;
@property (nonatomic, readonly) BOOL canPerformCommands;
@property (nonatomic, readonly) BOOL canPerformToolOperation;
@property (nonatomic, readonly, getter=isDeviceChromeVisible) BOOL deviceChromeVisible;
@property (nonatomic, readonly, getter=isStayingOnTop) BOOL stayingOnTop;

- (nullable instancetype)initWithDevice:(XSHSimDevice *)device
                               screenID:(uint32_t)screenID
                                runtime:(XSHPrivateRuntime *)runtime
                           closeHandler:(XSHDeviceWindowCloseHandler)closeHandler
                                  error:(NSError **)error;

- (void)showAndActivate;
- (void)saveFramebufferImage:(nullable id)sender;
- (void)toggleRotationLeft:(nullable id)sender;
- (void)toggleRotationRight:(nullable id)sender;
- (void)homeButtonPressed:(nullable id)sender;
- (void)lockButtonPressed:(nullable id)sender;
- (void)shakeDevice:(nullable id)sender;
- (void)toggleSoftwareKeyboard:(nullable id)sender;
- (void)toggleAppearance:(nullable id)sender;
- (void)toggleShowChrome:(nullable id)sender;
- (void)toggleAlwaysOnTop:(nullable id)sender;
- (void)fitScreen:(nullable id)sender;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
