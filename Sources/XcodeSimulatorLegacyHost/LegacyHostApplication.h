#import <AppKit/AppKit.h>

@class XSHPrivateRuntime;

NS_ASSUME_NONNULL_BEGIN

@interface XSHLegacyHostApplication : NSObject <NSApplicationDelegate>

@property (class, nonatomic, readonly) BOOL isDeviceHubRunning;

- (instancetype)initWithXcodeURL:(NSURL *)xcodeURL;
- (BOOL)startWithRuntime:(XSHPrivateRuntime *)runtime error:(NSError **)error;
- (void)activateDeviceWindows;

@end

NS_ASSUME_NONNULL_END
