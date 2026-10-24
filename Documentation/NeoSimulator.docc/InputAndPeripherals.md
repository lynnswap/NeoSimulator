# Input and peripherals

Control device input, exchange pasteboards, and connect audio or displays.

## Keyboard and touch

The active device window receives keyboard input. **I/O → Keyboard → Connect
Hardware Keyboard** (Shift-Command-K) is saved per device and defaults to on.
When disconnected, the Mac keyboard does not type into the device, and the
software keyboard appears. **Toggle Software Keyboard** (Command-K) controls
its visibility while the hardware keyboard is connected.

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

SimulatorKit retains touches through focus changes. Finish gestures and lift
pinned fingers before closing a window that will leave its device running;
otherwise the touch remains until the next touch or a device restart. Resizing
preserves a pinned finger's device position, but rotation preserves its window
position, so click that window position to release it. Three-finger and larger
arbitrary gestures are unavailable.

**I/O → Touch Pressure** appears for devices with 3D Touch. **Use Trackpad
Force** needs a Force Touch trackpad. Shallow Press and Deep Press select click
pressure on supported watches. These settings apply across device windows.

Neo does not capture the Mac's pointer and keyboard using Simulator.app's
**I/O → Input** commands. Those facilities require Apple-only entitlements;
see <doc:SimulatorIntegration>.

## Pasteboard

**Edit → Get Pasteboard** replaces the Mac pasteboard with the active device's
contents. **Send Pasteboard** replaces the device's contents with the Mac's.
They preserve all supported types, including text and images, and are available
for iPhone, iPad, and Apple Vision Pro while automatic sync is off. Paste a
received device item while its window is still open: the Mac reads its data
from the device on demand.

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
