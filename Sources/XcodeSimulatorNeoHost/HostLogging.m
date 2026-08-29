#import "HostLogging.h"

#import <stdarg.h>
#import <stdio.h>

NSString *const XSHNeoHostErrorDomain = @"dev.lynnswap.XcodeSimulatorNeoHost";

NSError *XSHNeoHostError(
    XSHNeoHostErrorCode code,
    NSString *description
) {
    return [NSError errorWithDomain:XSHNeoHostErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

void XSHLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    fprintf(stderr, "xcode-simulator-neo-host: %s\n", message.UTF8String);
}
