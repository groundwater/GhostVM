import AppKit

/// Overlay view for displaying VM state information (starting, suspending, error states)
final class StatusOverlay: NSView {

    enum OverlayState {
        case hidden
        case starting
        case suspending
        case error(message: String)
        case info(message: String)
    }

    private let spinner: NSProgressIndicator
    private let messageLabel: NSTextField
    private let dismissButton: NSButton

    private var currentState: OverlayState = .hidden

    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        spinner = NSProgressIndicator()
        messageLabel = NSTextField(labelWithString: "")
        dismissButton = NSButton(title: "OK", target: nil, action: nil)

        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        spinner = NSProgressIndicator()
        messageLabel = NSTextField(labelWithString: "")
        dismissButton = NSButton(title: "OK", target: nil, action: nil)

        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        isHidden = true

        // Container for centering content
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        // Spinner
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(spinner)

        // Message label
        messageLabel.font = .systemFont(ofSize: 18, weight: .medium)
        messageLabel.textColor = .white
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = 400
        container.addSubview(messageLabel)

        // Dismiss button (hidden by default)
        dismissButton.bezelStyle = .rounded
        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.isHidden = true
        container.addSubview(dismissButton)

        // Layout
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            container.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -80),

            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: container.topAnchor),

            messageLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            messageLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            dismissButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
            dismissButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            dismissButton.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    func setState(_ state: OverlayState) {
        currentState = state

        switch state {
        case .hidden:
            hide()
        case .starting:
            show(message: "Starting...", showSpinner: true, showDismiss: false)
        case .suspending:
            show(message: "Suspending...", showSpinner: true, showDismiss: false)
        case .error(let message):
            show(message: message, showSpinner: false, showDismiss: true)
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        case .info(let message):
            show(message: message, showSpinner: false, showDismiss: true)
        }
    }

    private func show(message: String, showSpinner: Bool, showDismiss: Bool) {
        messageLabel.stringValue = message

        if showSpinner {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }

        dismissButton.isHidden = !showDismiss

        isHidden = false
        alphaValue = 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 1
        }
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.isHidden = true
            self?.spinner.stopAnimation(nil)
        }
    }

    @objc private func dismissTapped() {
        hide()
        onDismiss?()
    }
}
