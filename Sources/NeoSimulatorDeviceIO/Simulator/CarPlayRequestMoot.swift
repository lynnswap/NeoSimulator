import Foundation

/// A CarPlay request that was not sent because the device restarted after it
/// was decided for the device's earlier boot.
package struct CarPlayRequestMoot: Error {}
