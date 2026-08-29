#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, XSHDeviceRotationDirection) {
    XSHDeviceRotationDirectionLeft,
    XSHDeviceRotationDirectionRight,
};

typedef void (^XSHDeviceToolCompletion)(NSError * _Nullable error);
typedef void (^XSHDeviceOrientationCompletion)(
    double rotationDegrees,
    NSError * _Nullable error
);

@interface XSHDeviceToolRunner : NSObject

@property (nonatomic, readonly, getter=isRunning) BOOL running;

- (nullable instancetype)initWithXcodeURL:(NSURL *)xcodeURL
                         deviceIdentifier:(NSString *)deviceIdentifier
                                    error:(NSError **)error;

- (void)captureScreenshotAtURL:(NSURL *)outputURL
                     completion:(XSHDeviceToolCompletion)completion;
- (void)rotate:(XSHDeviceRotationDirection)direction
     completion:(XSHDeviceToolCompletion)completion;
- (void)readOrientationWithCompletion:(XSHDeviceOrientationCompletion)completion;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
