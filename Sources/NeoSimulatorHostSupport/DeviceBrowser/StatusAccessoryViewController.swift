import AppKit

/// Presents the status and retry action supplied by the pane that owns this accessory.
@MainActor
package final class StatusAccessoryViewController: NSSplitViewItemAccessoryViewController {
    private let issue = NSTextField(wrappingLabelWithString: "")
    private let issueStack = NSStackView()
    private let activity = NSTextField(labelWithString: "")
    private let activityStack = NSStackView()
    private let progress = NSProgressIndicator()
    private let retry: () -> Void

    package init(retry: @escaping () -> Void) {
        self.retry = retry
        super.init(nibName: nil, bundle: nil)
        automaticallyAppliesContentInsets = false
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override package func loadView() {
        issue.font = .systemFont(ofSize: 11)
        issue.textColor = .secondaryLabelColor
        issue.setContentCompressionResistancePriority(.required, for: .vertical)
        let retryButton = NSButton(
            title: String(localized: "Try Again"), target: self, action: #selector(retryOperation))
        retryButton.controlSize = .small
        issueStack.orientation = .vertical
        issueStack.alignment = .leading
        issueStack.spacing = 6
        issueStack.addArrangedSubview(issue)
        issueStack.addArrangedSubview(retryButton)
        progress.style = .spinning
        progress.controlSize = .small
        activity.font = .systemFont(ofSize: 11)
        activity.textColor = .secondaryLabelColor
        activity.lineBreakMode = .byTruncatingTail
        activityStack.spacing = 6
        activityStack.addArrangedSubview(progress)
        activityStack.addArrangedSubview(activity)
        let content = NSStackView(views: [activityStack, issueStack])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        issue.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
        activityStack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
        content.frame.size = NSSize(width: 320, height: 80)
        view = content
    }

    package func update(issue: String?, activity: String? = nil) {
        loadViewIfNeeded()
        self.issue.stringValue = issue ?? ""
        self.issue.toolTip = issue
        issueStack.isHidden = issue == nil
        self.activity.stringValue = activity ?? ""
        activityStack.isHidden = activity == nil
        if activity != nil { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        isHidden = issue == nil && activity == nil
    }

    @objc private func retryOperation() { retry() }
}
