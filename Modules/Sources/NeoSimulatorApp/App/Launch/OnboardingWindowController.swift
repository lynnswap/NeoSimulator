import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class OnboardingState {
    var isRequesting = false
    var errorMessage: String?
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let state = OnboardingState()
    private let requestAccess: (NSWindow?) async throws -> Void
    private var continuation: CheckedContinuation<Void, any Error>?
    private var requestTask: Task<Void, Never>?

    init(requestAccess: @escaping (NSWindow?) async throws -> Void) {
        self.requestAccess = requestAccess
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        let host = NSHostingController(rootView: OnboardingView(state: state, allowAccess: { [weak self] in
            self?.allowAccess()
        }))
        host.sizingOptions = []
        window.contentViewController = host
        window.title = String(localized: "Set Up NeoSimulator", table: "Onboarding", bundle: #bundle)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.setContentSize(NSSize(width: 600, height: 400))
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                showWindow(nil)
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
        try Task.checkCancellation()
    }

    func allowAccess() {
        guard requestTask == nil else { return }
        state.errorMessage = nil
        state.isRequesting = true
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.state.isRequesting = false
                self.requestTask = nil
            }
            do {
                try await self.requestAccess(self.window)
                try Task.checkCancellation()
                let continuation = self.continuation
                self.continuation = nil
                continuation?.resume()
                self.close()
            } catch is CancellationError {
                // Keep the explanation available when the file picker is cancelled.
            } catch {
                self.state.errorMessage = error.localizedDescription
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        requestTask?.cancel()
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

private struct OnboardingView: View {
    let state: OnboardingState
    let allowAccess: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Set Up NeoSimulator", tableName: "Onboarding", bundle: #bundle)
                    .font(.title)
                    .fontWeight(.semibold)
                OnboardingDescription(errorMessage: state.errorMessage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scenePadding()
        }
        .safeAreaBar(edge: .bottom) {
            OnboardingAccessButton(isRequesting: state.isRequesting, allowAccess: allowAccess)
                .frame(maxWidth: .infinity)
                .scenePadding()
        }
        .accessibilityIdentifier("neosimulator.onboarding")
    }
}

private struct OnboardingDescription: View {
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NeoSimulator updates Device Hub settings so simulators open in NeoSimulator.", tableName: "Onboarding", bundle: #bundle)
            Text("Allow access to the Device Hub settings folder to make this change.", tableName: "Onboarding", bundle: #bundle)
            Text("Click the button below to open the folder picker. Keep the displayed “Preferences” folder open and click “Allow Access”.", tableName: "Onboarding", bundle: #bundle)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct OnboardingAccessButton: View {
    let isRequesting: Bool
    let allowAccess: () -> Void

    var body: some View {
        Button(action: allowAccess) {
            HStack {
                Text("Allow Access…", tableName: "Onboarding", bundle: #bundle)
                if isRequesting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonSizing(.flexible)
        .buttonBorderShape(.capsule)
        .buttonStyle(.glassProminent)
        .disabled(isRequesting)
        .animation(.easeInOut(duration:0.22), value: isRequesting)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("neosimulator.allow-device-hub-access")
    }
}

#Preview("Onboarding") {
    OnboardingView(state: OnboardingState(), allowAccess: {})
        .frame(width: 600, height: 400)
}
