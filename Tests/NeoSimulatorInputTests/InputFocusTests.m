#import <AppKit/AppKit.h>

#import "DeviceWindowController.h"
#import "PrivateRuntime.h"
#import "SwiftABI.h"

@interface XSHDeviceWindowController (InputFocusTests)
@property (nonatomic) NSView *inputView;
@end

@interface RecordingInputView : NSView
@property (nonatomic) NSMutableArray<NSEvent *> *modifierEvents;
@end

@implementation RecordingInputView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _modifierEvents = [NSMutableArray array];
    }
    return self;
}

- (void)flagsChanged:(NSEvent *)event {
    [self.modifierEvents addObject:event];
}
@end

@interface RefusingResponder : NSResponder
@end

@implementation RefusingResponder
- (BOOL)resignFirstResponder {
    return NO;
}
@end

@interface RecordingButtonController : XSHDeviceWindowController
@property (nonatomic) NSMutableArray<NSNumber *> *sentButtons;
@end

@implementation RecordingButtonController
- (instancetype)initWithWindow:(NSWindow *)window {
    self = [super initWithWindow:window];
    if (self != nil) {
        _sentButtons = [NSMutableArray array];
    }
    return self;
}

- (NSError *)sendButton:(uint32_t)button name:(NSString *)name {
    (void)name;
    [self.sentButtons addObject:@(button)];
    return nil;
}
@end

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(EXIT_FAILURE);
    }
}

static NSWindow *MakeWindow(NSView *view) {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 800.0)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.releasedWhenClosed = NO;
    window.contentView = view;
    return window;
}

static void TestFocusAndModifierReconciliation(void) {
    RecordingInputView *input = [[RecordingInputView alloc] initWithFrame:NSZeroRect];
    NSWindow *window = MakeWindow(input);
    XSHDeviceWindowController *controller = [[XSHDeviceWindowController alloc]
        initWithWindow:window];
    controller.inputView = input;
    NSNotification *becameKey = [NSNotification
        notificationWithName:NSWindowDidBecomeKeyNotification
                      object:window];

    [controller windowDidBecomeKey:becameKey];
    Require(window.firstResponder == input, @"activation must focus the input owner before a click");
    Require(input.modifierEvents.count == 1, @"activation must reconcile modifiers once");
    NSEvent *initial = input.modifierEvents.lastObject;
    Require(initial.type == NSEventTypeFlagsChanged, @"reconciliation must use a modifier event");
    Require(initial.windowNumber == window.windowNumber, @"reconciliation must target the owning window");
    Require(initial.modifierFlags == NSEvent.modifierFlags, @"reconciliation must use current keyboard state");

    [window makeFirstResponder:window];
    [controller windowDidBecomeKey:becameKey];
    Require(window.firstResponder == input, @"returning to the window must restore input focus");
    Require(input.modifierEvents.count == 2, @"returning must reconcile releases received elsewhere");

    [controller invalidate];
    [controller windowDidBecomeKey:becameKey];
    Require(input.modifierEvents.count == 2, @"an invalidated session must ignore delayed activation");
    puts("PASS: input focus, modifier reconciliation, and delayed activation");
}

static void TestRefusedFocusDoesNotForwardInput(void) {
    RecordingInputView *input = [[RecordingInputView alloc] initWithFrame:NSZeroRect];
    NSWindow *window = MakeWindow(input);
    XSHDeviceWindowController *controller = [[XSHDeviceWindowController alloc]
        initWithWindow:window];
    controller.inputView = input;
    RefusingResponder *responder = [RefusingResponder new];
    [window makeFirstResponder:responder];
    Require(window.firstResponder == responder, @"test responder must own focus");

    [controller windowDidBecomeKey:[NSNotification
        notificationWithName:NSWindowDidBecomeKeyNotification
                      object:window]];
    Require(window.firstResponder == responder, @"the current responder may refuse to resign");
    Require(input.modifierEvents.count == 0, @"failed focus must not deliver input to another owner");
    [controller invalidate];
    puts("PASS: refused focus preserves the current input owner");
}

static void TestButtonCommandsRestoreInputFocus(void) {
    NSDictionary<NSString *, NSNumber *> *commands = @{
        NSStringFromSelector(@selector(homeButtonPressed:)): @(XSHHomeButton),
        NSStringFromSelector(@selector(toggleSoftwareKeyboard:)): @(XSHSoftwareKeyboardButton),
        NSStringFromSelector(@selector(lockButtonPressed:)): @(XSHLockButton),
    };
    for (NSString *actionName in commands) {
        RecordingInputView *input = [[RecordingInputView alloc] initWithFrame:NSZeroRect];
        NSWindow *window = MakeWindow(input);
        RecordingButtonController *controller = [[RecordingButtonController alloc]
            initWithWindow:window];
        controller.inputView = input;
        SEL action = NSSelectorFromString(actionName);

        [window makeFirstResponder:window];
        Require([NSApp sendAction:action to:controller from:nil], @"button action must be dispatched");
        Require([controller.sentButtons.lastObject isEqual:commands[actionName]], @"button action must preserve its HID command");
        Require(window.firstResponder == input, @"button action must restore digitizer focus without another activation");
        Require(input.modifierEvents.count == 1, @"button action must reconcile the current modifiers");

        NSEvent *option = [NSEvent keyEventWithType:NSEventTypeFlagsChanged
                                         location:NSMakePoint(200.0, 400.0)
                                    modifierFlags:NSEventModifierFlagOption
                                        timestamp:NSProcessInfo.processInfo.systemUptime
                                     windowNumber:window.windowNumber
                                          context:nil
                                       characters:@""
                      charactersIgnoringModifiers:@""
                                        isARepeat:NO
                                          keyCode:58];
        [window sendEvent:option];
        Require(input.modifierEvents.lastObject == option, @"the next Option press must reach the digitizer");
        NSUInteger eventCount = input.modifierEvents.count;

        RefusingResponder *responder = [RefusingResponder new];
        [window makeFirstResponder:responder];
        [NSApp sendAction:action to:controller from:nil];
        Require(window.firstResponder == responder, @"button action must respect refused focus");
        Require(input.modifierEvents.count == eventCount, @"refused focus must not reconcile another input owner");

        [controller invalidate];
        [NSApp sendAction:action to:controller from:nil];
        Require(input.modifierEvents.count == eventCount, @"a delayed button action must not refocus an invalidated session");
    }
    puts("PASS: Home, Software Keyboard, and Lock preserve modifier input");
}

static void TestNativeDigitizerGetter(XSHPrivateRuntime *runtime) {
    Class displayClass = NSClassFromString(@"SimulatorKit.SimDisplayView");
    Require(displayClass != Nil, @"selected SimulatorKit must provide SimDisplayView");
    NSView *display = [[displayClass alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 800.0)];
    NSView *input = XSHSwiftCallObjectGetter(runtime.digitizerViewGetterFunction, display);
    Require(input != nil && [input isDescendantOf:display], @"the getter must return the display's input view");
    Require(input.nextResponder == display, @"unhandled input must continue to the existing display responder");
    CFIndex initialRetainCount = CFGetRetainCount((__bridge CFTypeRef)input);
    @autoreleasepool {
        for (NSUInteger index = 0; index < 100; index++) {
            NSView *sameInput = XSHSwiftCallObjectGetter(runtime.digitizerViewGetterFunction, display);
            Require(sameInput == input, @"the getter must preserve the native input view identity");
        }
    }
    Require(CFGetRetainCount((__bridge CFTypeRef)input) == initialRetainCount,
            @"repeated Swift getter calls must balance their retained results");
    XSHSwiftDisconnect(runtime.disconnectDisplayFunction, display);
    puts("PASS: native digitizer identity, responder chain, and getter ownership");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: InputFocusTests /absolute/path/to/Xcode.app\n");
            return EXIT_FAILURE;
        }
        [NSApplication sharedApplication];
        NSError *error = nil;
        XSHPrivateRuntime *runtime = [[XSHPrivateRuntime alloc]
            initWithXcodeURL:[NSURL fileURLWithPath:@(argv[1])]
                       error:&error];
        Require(runtime != nil, error.localizedDescription ?: @"private runtime validation failed");
        TestFocusAndModifierReconciliation();
        TestRefusedFocusDoesNotForwardInput();
        TestButtonCommandsRestoreInputFocus();
        TestNativeDigitizerGetter(runtime);
    }
    return EXIT_SUCCESS;
}
