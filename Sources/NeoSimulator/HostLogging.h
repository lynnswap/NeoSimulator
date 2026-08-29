#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const XSHNeoHostErrorDomain;

typedef NS_ENUM(NSInteger, XSHNeoHostErrorCode) {
    XSHNeoHostErrorInvalidArguments = 1,
    XSHNeoHostErrorInvalidInstallation = 2,
    XSHNeoHostErrorPrivateRuntime = 3,
    XSHNeoHostErrorHostConflict = 4,
    XSHNeoHostErrorDeviceConnection = 5,
    XSHNeoHostErrorToolOperation = 6,
    XSHNeoHostErrorToolTimeout = 7,
};

FOUNDATION_EXPORT NSError *XSHNeoHostError(
    XSHNeoHostErrorCode code,
    NSString *description
);

FOUNDATION_EXPORT void XSHLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END
