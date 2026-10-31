# Input and peripherals

Control device input, exchange pasteboards, and connect audio or displays.

## Simulator keyboard and touch

The active device window receives keyboard input. **I/O → Keyboard → Connect
Hardware Keyboard** (Shift-Command-K) is saved per device and defaults to on.
When disconnected, the Mac keyboard does not type into the device, and the
software keyboard appears. **Toggle Software Keyboard** (Command-K) controls
its visibility while the hardware keyboard is connected.

Simulators in the default device set, other than iPhone and iPad simulators
with 3D Touch, receive each Mac keyboard as its own hardware keyboard with that
keyboard's properties, as in Device Hub, so the device uses its layout, such as
JIS. In other device sets, which CoreDevice does not list, iPhone and iPad
simulators without 3D Touch receive keyboards the same way through the guest's
own HID services. iPhone and iPad simulators with 3D Touch, other simulators in
other device sets, and Apple Vision Pro receive keys through SimulatorKit,
which the device reads with a US layout.

Choose **Capture Keyboard** above the device screen or in **I/O → Keyboard**
to send Mac shortcuts to the device. Click the button again or hold Escape for
one second to release the keyboard. Capture ends when the screen loses focus,
its presentation moves, or NeoSimulator becomes inactive. macOS must allow
NeoSimulator in **System Settings → Privacy & Security → Accessibility**;
NeoSimulator reports an error if it cannot create the keyboard event tap.

**Use the Same Keyboard Language as macOS** defaults to on. It applies the Mac's
input-source language when a device connects or the Mac input source changes;
turning it on takes effect at the next such event.

| Gesture over the screen | Action |
| --- | --- |
| Hold Option | Show two fingers mirrored around the initial pointer position |
| Option-drag | Pinch or rotate around their center |
| Hold Option-Shift and move | Reposition the gesture center |
| Option-Shift-drag | Move both fingers together |
| While dragging, press Control and release the mouse | Pin the first finger |

To release a pinned finger, release Control, click its position, then release
the mouse. Releasing Control alone does not lift it. Release the mouse before
Option during a two-finger gesture; the reverse order leaves the fingers down
until the next click.

Once an iPhone or iPad simulator without 3D Touch receives native keyboard or
trackpad input, its guest stops accepting SimulatorKit's touches and buttons.
Its touches and button presses then go to the guest's native touchscreen and
buttons, as in Device Hub, and SimulatorKit still interprets the pointer and
the gestures above.

iPhone and iPad simulators with 3D Touch keep SimulatorKit's keyboard, touches,
and buttons, so their touches keep their pressure. NeoSimulator does not send
them native keyboard or trackpad input, which would stop their guest from
accepting those touches and buttons. This does not restore a guest that has
already stopped accepting them, for example after another app or an earlier
NeoSimulator version started its native input.

SimulatorKit retains touches through focus changes. Finish gestures and lift
pinned fingers before closing a window that will leave its device running;
otherwise the touch remains until the next touch or a device restart. Resizing
preserves a pinned finger's device position, but rotation preserves its window
position, so click that window position to release it. Three-finger and larger
arbitrary gestures are unavailable.

In the active device window, two-finger scrolling and pinches on a Mac trackpad
over the screen reach iPhone and iPad simulators without 3D Touch, and other
simulators in the default device set, as trackpad gestures, as in Device Hub.
Each gesture happens where the pointer is on the device screen, including after
you pan or zoom the canvas. **Connect Hardware Keyboard** does not affect them.
Option-scrolling pans the canvas instead of scrolling the device. Trackpad
gestures are unavailable on iPhone and iPad simulators with 3D Touch, on
devices with a Digital Crown or Digital Dial, where scrolling turns the crown
or dial, and on Apple Vision Pro, other simulators in other device sets, and
external displays.

**I/O → Touch Pressure** appears for devices with 3D Touch. **Use Trackpad
Force** needs a Force Touch trackpad. Shallow Press and Deep Press select click
pressure on supported watches. These settings apply across device windows.

Keyboard capture uses a macOS accessibility event tap. Simulator.app's
**I/O → Input** facilities, including pointer capture, remain unavailable;
those facilities require Apple-only entitlements. See <doc:SimulatorIntegration>.

## Physical-device and VM input

Input controls depend on the device's screen connection. Native screen-sharing
views handle keyboard and pointer events with their own controls.

For other remote screens, click or drag to send a single touch when the device
supports touch input. On devices without touch support, a left click sends
pointer input when available. Right clicks, other mouse buttons, and pointer
movement require pointer support. Keyboard input is available when the device
supports it. NeoSimulator releases held inputs when the window loses focus.

Simulator's Option and Control gestures described above apply only to simulator
windows.

## Simulator pasteboard

**Edit → Get Pasteboard** replaces the Mac pasteboard with the active device's
contents. **Send Pasteboard** replaces the device's contents with the Mac's.
They preserve all supported types, including text and images, and are available
for iPhone, iPad, and Apple Vision Pro while automatic sync is off. With some
simulators, the Mac reads a received item's data from the device when you paste
it, so keep the device's window open until you paste.

**Automatically Sync Pasteboard** is off by default. When enabled, copies on
the Mac go to every connected device window, and copies inside a device go to
the Mac and the other devices. This includes passwords or other private text.
A device connecting while sync is on receives the Mac pasteboard. Turning sync
on sends nothing until the next copy. The setting is remembered.

## Audio

**I/O → Audio Input** and **Audio Output** select Mac devices for all simulator
windows. **System** follows the Mac's default device. Neo remembers recent
choices and uses the most recent available device when a simulator connects or
Mac audio devices change, so a disconnected headset is selected again when it
returns. It also reapplies the selected route if another tool changes it.

Audio menus appear only on devices with audio routing support, including
compatible parallel testing devices. A route that a device rejects produces an
error in its window.

## External displays and CarPlay

**I/O → External Displays** connects a supported device to a display from
640×480 through 3840×2160, or to CarPlay. **Disabled** disconnects it. The display
gets its own window; closing that window also disconnects it. Choices are saved
per device and restored on connection. An externally enabled display, including
one set with `simctl`, also opens a window.

An iOS app must present an external-display scene before ordinary content
appears. iOS does not mirror the main screen. The menu reflects the current
mode, and unsupported sizes explain why they are unavailable:

- Modes use 60 Hz because iOS otherwise falls back to its 720×480 mode.
- 640×480 is disabled where the guest substitutes 720×480.
- 4K is disabled on Stage Manager iPads before iPadOS 27, where later mode
  changes or disconnection can crash SpringBoard.

CarPlay uses an 800×480 touch display at scale 2. Clicks become CarPlay touches.
It needs a CarPlay-capable external display mode, which iPhone's iOS 27.0
runtime does not provide. Choosing another size, Disabled, or closing either
window ends CarPlay. Its options panel is unavailable.

## Watch, TV, and Vision controls

| Platform | Controls |
| --- | --- |
| Apple Watch | Lock, Side Button, Digital Crown scrolling over the screen, Double Tap, Wrist Flick on watchOS 12+, and Simulate Fall where supported. Always On follows the watch backlight. |
| Apple TV | **Window → Show Apple TV Remote** (Shift-Command-R). Hold a button to keep it pressed. Click the touch surface for Select; hold Option over it for touch input. |
| Apple Vision Pro | The renderer's `XROS.simdeviceui` overlay, camera modes, Reset Camera, Re-Center Open Apps, Simulated Scenes, immersion, gaze target, FaceTime simulation, and Optic ID. |

Vision's Capture Pointer and Capture Keyboard buttons do not capture Mac input.
Set Immersion To requires guest permission to change immersion. Simulated Scenes
is disabled until the guest reports its scene, which may not happen if it was
already booted when the window opened. Re-Center Open Apps is visible for all
devices but acts only on Vision.
