#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const XSHLegacyHostErrorDomain;

typedef NS_ENUM(NSInteger, XSHLegacyHostErrorCode) {
    XSHLegacyHostErrorInvalidArguments = 1,
    XSHLegacyHostErrorInvalidInstallation = 2,
    XSHLegacyHostErrorPrivateRuntime = 3,
    XSHLegacyHostErrorDeviceHubConflict = 4,
    XSHLegacyHostErrorDeviceConnection = 5,
};

FOUNDATION_EXPORT NSError *XSHLegacyHostError(
    XSHLegacyHostErrorCode code,
    NSString *description
);

FOUNDATION_EXPORT void XSHLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END
