#import "HostLogging.h"

#import <stdarg.h>
#import <stdio.h>

NSString *const XSHLegacyHostErrorDomain = @"dev.lynnswap.XcodeSimulatorLegacyHost";

NSError *XSHLegacyHostError(
    XSHLegacyHostErrorCode code,
    NSString *description
) {
    return [NSError errorWithDomain:XSHLegacyHostErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

void XSHLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    fprintf(stderr, "xcode-simulator-legacy-host: %s\n", message.UTF8String);
}
