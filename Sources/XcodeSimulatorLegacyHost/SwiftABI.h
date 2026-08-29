#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// SimulatorKit exposes these operations only through Swift dispatch thunks.
// Keep the ABI bridge isolated here so runtime symbol validation and the
// Xcode-version boundary remain explicit.
FOUNDATION_EXPORT void XSHSwiftCallVoidMethod(void *function, id object);
FOUNDATION_EXPORT void XSHSwiftCallBoolMethod(
    void *function,
    id object,
    BOOL value
);
FOUNDATION_EXPORT CGFloat XSHSwiftCallCGFloatGetter(void *function, id object);
FOUNDATION_EXPORT void XSHSwiftCallCGSizeMethod(
    void *function,
    id object,
    CGSize size
);
FOUNDATION_EXPORT void XSHSwiftDisconnect(void *function, id object);

NS_ASSUME_NONNULL_END
