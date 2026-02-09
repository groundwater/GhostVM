import AppKit
import GhostVMKit
import UniformTypeIdentifiers

protocol IconChooserPanelDelegate: AnyObject {
    func iconChooserPanel(_ panel: IconChooserPanel, didSelectMode mode: String?, icon: NSImage?)
}

/// NSPopover-based panel for choosing a VM icon from the toolbar.
final class IconChooserPanel: NSObject, NSPopoverDelegate {

    weak var delegate: IconChooserPanelDelegate?
    var onClose: (() -> Void)?

    private var popover: NSPopover?
    private var contentVC: IconChooserContentViewController?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge, bundleURL: URL) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self

        let vc = IconChooserContentViewController(bundleURL: bundleURL)
        vc.onSelect = { [weak self] mode, icon in
            guard let self = self else { return }
            self.delegate?.iconChooserPanel(self, didSelectMode: mode, icon: icon)
        }

        popover.contentViewController = vc
        popover.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
        self.popover = popover
        self.contentVC = vc
    }

    func close() {
        popover?.close()
    }

    var isShown: Bool {
        popover?.isShown ?? false
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        contentVC = nil
        onClose?()
    }
}

// MARK: - Tile Button

/// A square button with rounded-rect background that supports a selection border.
private final class TileButton: NSButton {
    var isSelectedTile: Bool = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let radius: CGFloat = 8

        // Background
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        bgPath.fill()

        // Selection border
        if isSelectedTile {
            let borderPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            borderPath.lineWidth = 2.5
            NSColor.controlAccentColor.setStroke()
            borderPath.stroke()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: frame.width, height: frame.height)
    }
}

// MARK: - Content View Controller

private final class IconChooserContentViewController: NSViewController {

    var onSelect: ((_ mode: String?, _ icon: NSImage?) -> Void)?

    private let bundleURL: URL
    private var currentMode: String?
    private var customIcon: NSImage?

    private var modeButtons: [TileButton] = []  // [Generic, App, Stack, Custom]
    private var customImageView: NSImageView?    // updatable reference inside Custom button
    private var customSymbolView: NSImageView?   // the plus.square fallback
    private var customLabel: NSTextField?         // the "Custom" label

    private static let presetIcons: [(name: String, resource: String)] = [
        ("Hipster", "icon-hipster"),
        ("Nerd", "icon-nerd"),
        ("80s Bro", "icon-80s-bro"),
        ("Terminal", "icon-terminal"),
        ("Quill", "icon-quill"),
        ("Typewriter", "icon-typewriter"),
        ("Kernel", "icon-kernel"),
        ("Banana", "icon-banana"),
        ("Papaya", "icon-papaya"),
        ("Daemon", "icon-daemon"),
    ]

    private static func loadPresetIcon(named resource: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    private let tileSize: CGFloat = 60

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        loadIconState()

        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active

        // Title
        let titleLabel = NSTextField(labelWithString: "VM Icon")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Mode buttons row
        let modesStack = NSStackView()
        modesStack.orientation = .horizontal
        modesStack.spacing = 8
        modesStack.translatesAutoresizingMaskIntoConstraints = false

        let modes: [(title: String, symbol: String, tag: Int)] = [
            ("Generic", "desktopcomputer", 0),
            ("App", "app", 1),
            ("Stack", "sparkles.rectangle.stack", 2),
        ]

        for (title, symbol, tag) in modes {
            let button = makeModeButton(title: title, symbolName: symbol, tag: tag)
            modeButtons.append(button)
            modesStack.addArrangedSubview(button)
        }

        let customButton = makeCustomButton()
        modeButtons.append(customButton)
        modesStack.addArrangedSubview(customButton)

        updateHighlightForCurrentState()
        container.addSubview(modesStack)

        // Preset grid
        let presetsView = makePresetsGrid()
        presetsView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(presetsView)

        let padding: CGFloat = 16

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            modesStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            modesStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            presetsView.topAnchor.constraint(equalTo: modesStack.bottomAnchor, constant: 12),
            presetsView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            presetsView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),

            container.widthAnchor.constraint(equalToConstant: 4 * tileSize + 3 * 8 + 2 * padding),
        ])

        self.view = container
    }

    // MARK: - State

    private func loadIconState() {
        let layout = VMFileLayout(bundleURL: bundleURL)
        let store = VMConfigStore(layout: layout)
        if let config = try? store.load() {
            currentMode = config.iconMode
        }
        let iconURL = layout.customIconURL
        if FileManager.default.fileExists(atPath: iconURL.path) {
            customIcon = NSImage(contentsOf: iconURL)
        }
    }

    private func updateHighlightForCurrentState() {
        let selectedTag: Int
        switch currentMode {
        case "app": selectedTag = 1
        case "stack": selectedTag = 2
        case nil where customIcon != nil: selectedTag = 3
        default: selectedTag = 0
        }
        for button in modeButtons {
            button.isSelectedTile = (button.tag == selectedTag)
        }
    }

    private func selectButton(tag: Int) {
        for button in modeButtons {
            button.isSelectedTile = (button.tag == tag)
        }
    }

    // MARK: - Custom Button Image Update

    private func updateCustomButtonImage(_ icon: NSImage) {
        // Hide symbol + label, show icon image
        customSymbolView?.isHidden = true
        customLabel?.isHidden = true

        if let imageView = customImageView {
            imageView.image = icon
            imageView.isHidden = false
        } else {
            // First time — create the image view in the custom button
            guard modeButtons.count > 3 else { return }
            let button = modeButtons[3]

            let imageView = NSImageView()
            imageView.image = icon
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 8
            imageView.layer?.masksToBounds = true

            button.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: tileSize - 8),
                imageView.heightAnchor.constraint(equalToConstant: tileSize - 8),
            ])
            customImageView = imageView
        }
    }

    // MARK: - Mode Buttons

    private func makeModeButton(title: String, symbolName: String, tag: Int) -> TileButton {
        let button = TileButton(frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize))
        button.isBordered = false
        button.title = ""
        button.tag = tag
        button.target = self
        button.action = #selector(modeButtonClicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 28),
            imageView.heightAnchor.constraint(equalToConstant: 28),
        ])

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(label)

        button.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: tileSize),
            button.heightAnchor.constraint(equalToConstant: tileSize),
        ])

        return button
    }

    private func makeCustomButton() -> TileButton {
        let button = TileButton(frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize))
        button.isBordered = false
        button.title = ""
        button.tag = 3
        button.target = self
        button.action = #selector(modeButtonClicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false

        if let icon = customIcon {
            let imageView = NSImageView()
            imageView.image = icon
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 8
            imageView.layer?.masksToBounds = true
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: tileSize - 8),
                imageView.heightAnchor.constraint(equalToConstant: tileSize - 8),
            ])
            button.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            customImageView = imageView
        } else {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.spacing = 2
            stack.alignment = .centerX
            stack.translatesAutoresizingMaskIntoConstraints = false

            let symbolView = NSImageView()
            symbolView.image = NSImage(systemSymbolName: "plus.square", accessibilityDescription: "Custom")?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
            symbolView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                symbolView.widthAnchor.constraint(equalToConstant: 28),
                symbolView.heightAnchor.constraint(equalToConstant: 28),
            ])
            customSymbolView = symbolView

            let label = NSTextField(labelWithString: "Custom")
            label.font = .systemFont(ofSize: 9)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            customLabel = label

            stack.addArrangedSubview(symbolView)
            stack.addArrangedSubview(label)

            button.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: tileSize),
            button.heightAnchor.constraint(equalToConstant: tileSize),
        ])

        return button
    }

    @objc private func modeButtonClicked(_ sender: NSButton) {
        selectButton(tag: sender.tag)

        switch sender.tag {
        case 0: onSelect?(nil, nil)
        case 1: onSelect?("app", nil)
        case 2: onSelect?("stack", nil)
        case 3:
            if let icon = customIcon {
                onSelect?(nil, icon)
            }
        default: break
        }
    }

    // MARK: - Presets Grid

    private func makePresetsGrid() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 8
        grid.alignment = .leading

        let columns = 4

        var allItems: [(name: String, resource: String)] = Self.presetIcons
        allItems.append(("Upload", ""))

        var row: NSStackView?
        for (index, item) in allItems.enumerated() {
            if index % columns == 0 {
                row = NSStackView()
                row!.orientation = .horizontal
                row!.spacing = 8
                grid.addArrangedSubview(row!)
            }

            let button = TileButton(frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize))
            button.isBordered = false
            button.title = ""
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: tileSize),
                button.heightAnchor.constraint(equalToConstant: tileSize),
            ])

            if item.resource.isEmpty {
                // Upload button
                button.target = self
                button.action = #selector(uploadClicked)

                let stack = NSStackView()
                stack.orientation = .vertical
                stack.spacing = 2
                stack.alignment = .centerX
                stack.translatesAutoresizingMaskIntoConstraints = false

                let imageView = NSImageView()
                imageView.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Upload")?
                    .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
                imageView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: 24),
                    imageView.heightAnchor.constraint(equalToConstant: 24),
                ])

                let label = NSTextField(labelWithString: "Upload")
                label.font = .systemFont(ofSize: 9)
                label.textColor = .secondaryLabelColor
                label.alignment = .center

                stack.addArrangedSubview(imageView)
                stack.addArrangedSubview(label)

                button.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                ])
            } else {
                // Preset icon button
                button.target = self
                button.action = #selector(presetClicked(_:))
                button.tag = index
                button.toolTip = item.name

                if let img = Self.loadPresetIcon(named: item.resource) {
                    let imageView = NSImageView()
                    imageView.image = img
                    imageView.imageScaling = .scaleProportionallyUpOrDown
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    imageView.wantsLayer = true
                    imageView.layer?.cornerRadius = (tileSize - 4) * 185.4 / 1024
                    imageView.layer?.masksToBounds = true
                    NSLayoutConstraint.activate([
                        imageView.widthAnchor.constraint(equalToConstant: tileSize - 4),
                        imageView.heightAnchor.constraint(equalToConstant: tileSize - 4),
                    ])

                    button.addSubview(imageView)
                    NSLayoutConstraint.activate([
                        imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                        imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    ])
                }
            }

            row?.addArrangedSubview(button)
        }

        return grid
    }

    @objc private func presetClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index < Self.presetIcons.count else { return }
        let preset = Self.presetIcons[index]
        guard let img = Self.loadPresetIcon(named: preset.resource) else { return }

        customIcon = img
        selectButton(tag: 3)
        updateCustomButtonImage(img)
        onSelect?(nil, img)
    }

    @objc private func uploadClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.png, UTType.jpeg, UTType.tiff, UTType.heic]
        panel.message = "Choose an icon image for this VM"

        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }

        customIcon = image
        selectButton(tag: 3)
        updateCustomButtonImage(image)
        onSelect?(nil, image)
    }
}
