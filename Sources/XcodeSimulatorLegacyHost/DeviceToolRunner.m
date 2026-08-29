#import "DeviceToolRunner.h"

#import "HostLogging.h"

#import <signal.h>

static NSString *const XSHSimctlPath =
    @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl";
static NSString *const XSHDevicectlPath =
    @"/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl";
static const NSUInteger XSHMaximumDiagnosticOutputLength = 4096;
static const NSTimeInterval XSHDeviceToolTimeout = 30.0;
static const NSTimeInterval XSHDeviceToolTerminationGracePeriod = 2.0;

@interface XSHDeviceToolRunner ()
@property (nonatomic) NSString *developerDirectory;
@property (nonatomic) NSString *deviceIdentifier;
@property (nonatomic, nullable) NSTask *task;
@property (nonatomic, nullable) NSData *standardOutputData;
@property (nonatomic, nullable) NSData *standardErrorData;
@property (nonatomic, nullable) NSError *launchError;
@property (nonatomic, copy, nullable) NSString *operationName;
@property (nonatomic, copy, nullable) XSHDeviceToolCompletion completion;
@property (nonatomic) BOOL cancellationRequested;
@property (nonatomic) BOOL timedOut;
@property (nonatomic, nullable) dispatch_source_t timeoutSource;
@end

@implementation XSHDeviceToolRunner

- (nullable instancetype)initWithXcodeURL:(NSURL *)xcodeURL
                         deviceIdentifier:(NSString *)deviceIdentifier
                                    error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    NSString *developerDirectory = [xcodeURL.path
        stringByAppendingPathComponent:@"Contents/Developer"];
    NSUUID *deviceUUID = [[NSUUID alloc] initWithUUIDString:deviceIdentifier];
    if (developerDirectory.length == 0 || deviceUUID == nil) {
        if (error != NULL) {
            *error = XSHLegacyHostError(
                XSHLegacyHostErrorInvalidInstallation,
                @"could not configure the selected developer directory and simulator UDID"
            );
        }
        return nil;
    }

    for (NSString *toolPath in @[XSHSimctlPath, XSHDevicectlPath]) {
        if (![NSFileManager.defaultManager isExecutableFileAtPath:toolPath]) {
            if (error != NULL) {
                *error = XSHLegacyHostError(
                    XSHLegacyHostErrorInvalidInstallation,
                    [NSString stringWithFormat:@"required Apple device tool is unavailable: %@",
                                               toolPath]
                );
            }
            return nil;
        }
    }

    _developerDirectory = developerDirectory;
    _deviceIdentifier = deviceUUID.UUIDString;
    return self;
}

- (BOOL)isRunning {
    return self.task != nil;
}

- (void)captureScreenshotAtURL:(NSURL *)outputURL
                     completion:(XSHDeviceToolCompletion)completion {
    [self runExecutableAtPath:XSHSimctlPath
                    arguments:@[
                        @"io",
                        self.deviceIdentifier,
                        @"screenshot",
                        @"--type=png",
                        @"--mask=alpha",
                        outputURL.path,
                    ]
                 operationName:@"Save Screen"
                    completion:completion];
}

- (void)rotate:(XSHDeviceRotationDirection)direction
     completion:(XSHDeviceToolCompletion)completion {
    NSString *directionArgument = direction == XSHDeviceRotationDirectionLeft
        ? @"left"
        : @"right";
    [self runExecutableAtPath:XSHDevicectlPath
                    arguments:@[
                        @"device",
                        @"orientation",
                        @"rotate",
                        @"--device",
                        self.deviceIdentifier,
                        directionArgument,
                        @"--quiet",
                    ]
                 operationName:direction == XSHDeviceRotationDirectionLeft
                    ? @"Rotate Left"
                    : @"Rotate Right"
                    completion:completion];
}

- (void)runExecutableAtPath:(NSString *)executablePath
                  arguments:(NSArray<NSString *> *)arguments
               operationName:(NSString *)operationName
                  completion:(XSHDeviceToolCompletion)completion {
    NSAssert(NSThread.isMainThread, @"device tools must be started on the main thread");

    if (self.task != nil) {
        completion(XSHLegacyHostError(
            XSHLegacyHostErrorToolOperation,
            @"another device operation is already in progress"
        ));
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    NSPipe *standardOutputPipe = [NSPipe pipe];
    NSPipe *standardErrorPipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:executablePath];
    task.arguments = arguments;
    NSMutableDictionary<NSString *, NSString *> *environment =
        NSProcessInfo.processInfo.environment.mutableCopy;
    environment[@"DEVELOPER_DIR"] = self.developerDirectory;
    task.environment = environment;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = standardOutputPipe;
    task.standardError = standardErrorPipe;

    self.task = task;
    self.standardOutputData = nil;
    self.standardErrorData = nil;
    self.launchError = nil;
    self.operationName = operationName;
    self.completion = completion;
    self.cancellationRequested = NO;
    self.timedOut = NO;

    dispatch_group_t completionGroup = dispatch_group_create();
    dispatch_queue_t drainQueue = dispatch_get_global_queue(
        QOS_CLASS_UTILITY,
        0
    );
    dispatch_group_async(completionGroup, drainQueue, ^{
        NSError *readError = nil;
        NSData *data = [standardOutputPipe.fileHandleForReading
            readDataToEndOfFileAndReturnError:&readError];
        @synchronized (self) {
            self.standardOutputData = data;
        }
        if (readError != nil) {
            XSHLog(@"could not drain %@ stdout: %@",
                   operationName,
                   readError.localizedDescription);
        }
    });
    dispatch_group_async(completionGroup, drainQueue, ^{
        NSError *readError = nil;
        NSData *data = [standardErrorPipe.fileHandleForReading
            readDataToEndOfFileAndReturnError:&readError];
        @synchronized (self) {
            self.standardErrorData = data;
        }
        if (readError != nil) {
            XSHLog(@"could not drain %@ stderr: %@",
                   operationName,
                   readError.localizedDescription);
        }
    });

    dispatch_group_enter(completionGroup);
    task.terminationHandler = ^(NSTask *finishedTask) {
        (void)finishedTask;
        dispatch_group_leave(completionGroup);
    };

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        self.launchError = launchError;
        task.terminationHandler = nil;
        [standardOutputPipe.fileHandleForWriting closeFile];
        [standardErrorPipe.fileHandleForWriting closeFile];
        dispatch_group_leave(completionGroup);
    } else {
        [self startTimeoutForTask:task];
    }

    dispatch_group_notify(completionGroup, dispatch_get_main_queue(), ^{
        [self finishTask:task];
    });
}

- (void)startTimeoutForTask:(NSTask *)task {
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        dispatch_get_main_queue()
    );
    dispatch_source_set_timer(
        source,
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(XSHDeviceToolTimeout * NSEC_PER_SEC)
        ),
        DISPATCH_TIME_FOREVER,
        0
    );
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.task != task || !task.running) {
            return;
        }
        strongSelf.timedOut = YES;
        [strongSelf requestTerminationOfTask:task];
    });
    self.timeoutSource = source;
    dispatch_resume(source);
}

- (void)requestTerminationOfTask:(NSTask *)task {
    if (task.running) {
        [task terminate];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(XSHDeviceToolTerminationGracePeriod * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf.task == task && task.running) {
                kill(task.processIdentifier, SIGKILL);
            }
        }
    );
}

- (void)finishTask:(NSTask *)finishedTask {
    NSAssert(NSThread.isMainThread, @"device tool completion must run on the main thread");
    if (finishedTask != self.task) {
        return;
    }

    NSError *error = nil;
    if (self.timedOut) {
        error = XSHLegacyHostError(
            XSHLegacyHostErrorToolTimeout,
            [NSString stringWithFormat:@"%@ timed out after %.0f seconds",
                                       self.operationName,
                                       XSHDeviceToolTimeout]
        );
    } else if (self.cancellationRequested) {
        error = [NSError errorWithDomain:NSCocoaErrorDomain
                                    code:NSUserCancelledError
                                userInfo:nil];
    } else if (self.launchError != nil) {
        error = XSHLegacyHostError(
            XSHLegacyHostErrorToolOperation,
            [NSString stringWithFormat:@"could not start %@: %@",
                                       self.operationName,
                                       self.launchError.localizedDescription]
        );
    } else if (finishedTask.terminationReason != NSTaskTerminationReasonExit ||
               finishedTask.terminationStatus != 0) {
        NSString *diagnostic = [self diagnosticOutput];
        NSString *description = diagnostic.length == 0
            ? [NSString stringWithFormat:@"%@ failed with status %d",
                                                 self.operationName,
                                                 finishedTask.terminationStatus]
            : [NSString stringWithFormat:@"%@ failed: %@",
                                                 self.operationName,
                                                 diagnostic];
        error = XSHLegacyHostError(XSHLegacyHostErrorToolOperation, description);
    }

    XSHDeviceToolCompletion completion = self.completion;
    if (self.timeoutSource != nil) {
        dispatch_source_cancel(self.timeoutSource);
        self.timeoutSource = nil;
    }
    finishedTask.terminationHandler = nil;
    self.task = nil;
    self.standardOutputData = nil;
    self.standardErrorData = nil;
    self.launchError = nil;
    self.operationName = nil;
    self.completion = nil;
    self.cancellationRequested = NO;
    self.timedOut = NO;
    completion(error);
}

- (NSString *)diagnosticOutput {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    @synchronized (self) {
        for (NSData *data in @[self.standardErrorData ?: NSData.data,
                               self.standardOutputData ?: NSData.data]) {
            NSString *value = [[NSString alloc] initWithData:data
                                                    encoding:NSUTF8StringEncoding];
            value = [value stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (value.length > XSHMaximumDiagnosticOutputLength) {
                value = [value substringFromIndex:
                    value.length - XSHMaximumDiagnosticOutputLength];
            }
            if (value.length > 0) {
                [parts addObject:value];
            }
        }
    }
    return [parts componentsJoinedByString:@"\n"];
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"device tools must be cancelled on the main thread");
    NSTask *task = self.task;
    if (task == nil) {
        return;
    }

    self.cancellationRequested = YES;
    [self requestTerminationOfTask:task];
}

- (void)dealloc {
    if (_timeoutSource != nil) {
        dispatch_source_cancel(_timeoutSource);
    }
    NSTask *task = _task;
    if (task.running) {
        [task terminate];
    }
}

@end
