import AppKit
import NeoSimulatorKit
import NeoSimulatorManager
import NeoSimulatorUI

/// The Device menu's saved logins. Choosing one signs in to the web authentication session that the frontmost app of
/// the active device shows.
///
/// The menu lists every app's logins. The sign-in itself refuses a login whose app is not the one in front, which the
/// menu cannot know before the device is asked.
@MainActor
final class SignInMenu: NSMenu, NSMenuDelegate {
    private let logins: LoginStore

    init(logins: LoginStore) {
        self.logins = logins
        super.init(title: "Sign In with Saved Login")
        delegate = self
        autoenablesItems = false
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        let canSignIn = DeviceWindowController.keyDeviceWindow?.session.canPerformCommands == true
        var application: String?
        // The store keeps the logins by app and then by label.
        for login in logins.logins {
            if login.applicationIdentifier != application {
                application = login.applicationIdentifier
                addItem(.sectionHeader(title: login.applicationIdentifier))
            }
            let item = NSMenuItem(title: login.label, action: #selector(signIn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = login.id
            item.isEnabled = canSignIn
            addItem(item)
        }
        if items.isEmpty {
            let item = NSMenuItem(title: logins.issue ?? "No Saved Logins", action: nil, keyEquivalent: "")
            item.isEnabled = false
            addItem(item)
        }
    }

    @objc private func signIn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SavedLogin.ID,
            let controller = DeviceWindowController.keyDeviceWindow
        else { return }
        Task { [logins] in
            do {
                try await logins.signIn(with: id, on: controller.session)
            } catch {
                controller.present(error)
            }
        }
    }
}
