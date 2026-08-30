#import <AppKit/AppKit.h>

@class XSHPrivateRuntime;
@class XSHMenuController;

NS_ASSUME_NONNULL_BEGIN

@interface XSHNeoHostApplication : NSObject <NSApplicationDelegate>

@property (class, nonatomic, copy, readonly, nullable) NSString *runningConflictingHostName;
@property (atomic, copy, readonly, nullable) NSString *conflictingHostName;

- (instancetype)initWithXcodeURL:(NSURL *)xcodeURL
                  menuController:(XSHMenuController *)menuController;
- (BOOL)startWithRuntime:(XSHPrivateRuntime *)runtime error:(NSError **)error;
- (void)activateDeviceWindows;

@end

NS_ASSUME_NONNULL_END
