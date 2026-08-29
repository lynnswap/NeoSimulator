#import "HostLogging.h"

#import <stdarg.h>
#import <stdio.h>

NSString *const XSHNeoHostErrorDomain = @"dev.lynnswap.NeoSimulator";

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

    fprintf(stderr, "neo-simulator: %s\n", message.UTF8String);
}
