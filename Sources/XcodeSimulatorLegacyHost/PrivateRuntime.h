#import <Foundation/Foundation.h>

#import "PrivateInterfaces.h"

NS_ASSUME_NONNULL_BEGIN

@interface XSHPrivateRuntime : NSObject

@property (nonatomic, readonly) NSURL *xcodeURL;
@property (nonatomic, readonly) Class serviceContextClass;
@property (nonatomic, readonly) Class deviceScreenClass;
@property (nonatomic, readonly) Class displayFactoryClass;
@property (nonatomic, readonly) Class legacyHIDClientClass;
@property (nonatomic, readonly) XSHIndigoHIDMessageForButtonFunction messageForButton;
@property (nonatomic, readonly) void *disconnectDisplayFunction;
@property (nonatomic, readonly) void *beginResizeFunction;
@property (nonatomic, readonly) void *resizeToFunction;
@property (nonatomic, readonly) void *endResizeFunction;

- (nullable instancetype)initWithXcodeURL:(NSURL *)xcodeURL
                                    error:(NSError **)error;

- (BOOL)validateLoadedImagesWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
