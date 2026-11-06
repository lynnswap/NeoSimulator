/// A CoreSimulator `SimDevice`, which higher layers can carry without being able to message it: a target reads `object`
/// only by importing this module. It has no getter and no closure of its own, since nearly every SimDevice message waits on
/// one of CoreSimulator's queues. Only a device's worker or a display's own main-bound plan sends one.
package struct SimDeviceHandle: @unchecked Sendable {
    package let object: AnyObject

    package init(unchecked object: AnyObject) { self.object = object }
}
