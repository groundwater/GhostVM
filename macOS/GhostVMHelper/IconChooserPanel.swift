import AppKit
import GhostVMKit
import UniformTypeIdentifiers

// MARK: - Tile Button

/// A square button with rounded-rect background that supports a selection border and drag-and-drop.
private final class TileButton: NSButton {
    var isSelectedTile: Bool = false { didSet { needsDisplay = true } }
    var isImageWell: Bool = false { didSet { needsDisplay = true } }
    var isDragHighlighted: Bool = false { didSet { needsDisplay = true } }
    var slotIndex: Int = -1
    var onDrop: ((_ slotIndex: Int, _ image: NSImage) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let radius: CGFloat = 8

        // Background
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        bgPath.fill()

        // Dashed border for empty image wells
        if isImageWell {
            let dashPath = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
            dashPath.lineWidth = 1.5
            let dashPattern: [CGFloat] = [4, 3]
            dashPath.setLineDash(dashPattern, count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            dashPath.stroke()
        }

        // Drag highlight border
        if isDragHighlighted {
            let hlPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            hlPath.lineWidth = 2.5
            NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
            hlPath.stroke()
        }

        // Selection border
        if isSelectedTile {
            let borderPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            borderPath.lineWidth = 2.5
            NSColor.controlAccentColor.setStroke()
            borderPath.stroke()
        }
    }

    func registerForImageDrag() {
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard imageFromDrag(sender) != nil else { return [] }
        isDragHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragHighlighted = false
        guard let image = imageFromDrag(sender) else { return false }
        onDrop?(slotIndex, image)
        return true
    }

    private func imageFromDrag(_ sender: NSDraggingInfo) -> NSImage? {
        let pb = sender.draggingPasteboard

        // Try file URL first
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]) as? [URL], let url = urls.first {
            return NSImage(contentsOf: url)
        }

        // Try inline image data
        if let image = NSImage(pasteboard: pb) {
            return image
        }

        return nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: frame.width, height: frame.height)
    }
}

// MARK: - Content View Controller

final class IconChooserContentViewController: NSViewController, PopoverContent {

    var onSelect: ((_ mode: String?, _ icon: NSImage?) -> Void)?

    let dismissBehavior: PopoverDismissBehavior = .transient
    let preferredToolbarAnchor: NSToolbarItem.Identifier? = NSToolbarItem.Identifier("iconChooser")

    private let bundleURL: URL
    private var currentMode: String?
    private var customIcon: NSImage?

    private var modeButtons: [TileButton] = []  // [Generic, Glass, App, Stack]
    private var presetButtons: [TileButton] = []
    private var slotImages: [Int: NSImage] = [:]

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
            ("Glass", "rectangle.on.rectangle.square", 4),
            ("App", "app", 1),
            ("Stack", "sparkles.rectangle.stack", 2),
        ]

        for (title, symbol, tag) in modes {
            let button = makeModeButton(title: title, symbolName: symbol, tag: tag)
            modeButtons.append(button)
            modesStack.addArrangedSubview(button)
        }

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

        // Load persisted slot images
        for index in 0..<12 {
            let url = layout.slotIconURL(index: index)
            if FileManager.default.fileExists(atPath: url.path),
               let img = NSImage(contentsOf: url) {
                slotImages[index] = img
            }
        }
    }

    private func updateHighlightForCurrentState() {
        let selectedTag: Int
        switch currentMode {
        case "app": selectedTag = 1
        case "stack": selectedTag = 2
        case "glass": selectedTag = 4
        case nil where customIcon != nil: selectedTag = -1  // custom icon set, no mode button highlighted
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
        // Deselect all preset tiles when a mode button is selected
        for button in presetButtons {
            button.isSelectedTile = false
        }
    }

    private func selectPreset(index: Int) {
        // Deselect all mode buttons
        for button in modeButtons {
            button.isSelectedTile = false
        }
        // Highlight only the clicked preset tile
        for button in presetButtons {
            button.isSelectedTile = (button.slotIndex == index)
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

    @objc private func modeButtonClicked(_ sender: NSButton) {
        selectButton(tag: sender.tag)

        switch sender.tag {
        case 0: onSelect?(nil, nil)
        case 1: onSelect?("app", nil)
        case 2: onSelect?("stack", nil)
        case 4: onSelect?("glass", nil)
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
        let totalSlots = 12  // 10 presets + 2 blank image wells

        presetButtons = []

        var row: NSStackView?
        for index in 0..<totalSlots {
            if index % columns == 0 {
                row = NSStackView()
                row!.orientation = .horizontal
                row!.spacing = 8
                grid.addArrangedSubview(row!)
            }

            let button = TileButton(frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize))
            button.isBordered = false
            button.title = ""
            button.slotIndex = index
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            button.registerForImageDrag()
            button.onDrop = { [weak self] slotIndex, image in
                self?.handleDrop(slotIndex: slotIndex, image: image)
            }
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: tileSize),
                button.heightAnchor.constraint(equalToConstant: tileSize),
            ])

            if let slotImg = slotImages[index] {
                // Slot has a persisted custom image (overrides preset or fills well)
                button.action = #selector(presetClicked(_:))
                button.tag = index
                button.toolTip = index < Self.presetIcons.count ? Self.presetIcons[index].name : "Custom icon"
                addImageView(to: button, image: slotImg)
            } else if index < Self.presetIcons.count {
                // Preset icon button
                let preset = Self.presetIcons[index]
                button.action = #selector(presetClicked(_:))
                button.tag = index
                button.toolTip = preset.name

                if let img = Self.loadPresetIcon(named: preset.resource) {
                    addImageView(to: button, image: img)
                }
            } else {
                // Blank image well
                button.isImageWell = true
                button.action = #selector(imageWellClicked(_:))
                button.tag = index
                button.toolTip = "Drop or click to add icon"

                addPlusIndicator(to: button)
            }

            presetButtons.append(button)
            row?.addArrangedSubview(button)
        }

        return grid
    }

    private func addImageView(to button: TileButton, image: NSImage) {
        // Remove existing subviews
        button.subviews.forEach { $0.removeFromSuperview() }

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = (tileSize - 4) * 185.4 / 1024
        imageView.layer?.masksToBounds = true
        // Prevent NSImageView from intercepting drag events meant for the button
        imageView.unregisterDraggedTypes()
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

    private func addPlusIndicator(to button: TileButton) {
        let plusImage = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add icon")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .light))
        let imageView = NSImageView()
        imageView.image = plusImage
        imageView.contentTintColor = .tertiaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
    }

    @objc private func presetClicked(_ sender: NSButton) {
        let index = sender.tag

        // If this slot has a custom dropped/uploaded image, use that
        if let customImg = slotImages[index] {
            customIcon = customImg
            selectPreset(index: index)
            onSelect?(nil, customImg)
            return
        }

        guard index < Self.presetIcons.count else { return }
        let preset = Self.presetIcons[index]
        guard let img = Self.loadPresetIcon(named: preset.resource) else { return }

        customIcon = img
        selectPreset(index: index)
        onSelect?(nil, img)
    }

    @objc private func imageWellClicked(_ sender: NSButton) {
        let slotIndex = sender.tag

        // If this slot already has a custom image, select it
        if let customImg = slotImages[slotIndex] {
            customIcon = customImg
            selectPreset(index: slotIndex)
            onSelect?(nil, customImg)
            return
        }

        // Otherwise open file picker
        openImagePicker(forSlot: slotIndex)
    }

    private func openImagePicker(forSlot slotIndex: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.png, UTType.jpeg, UTType.tiff, UTType.heic]
        panel.message = "Choose an icon image for this VM"

        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }

        applyImage(image, toSlot: slotIndex)
    }

    private func handleDrop(slotIndex: Int, image: NSImage) {
        applyImage(image, toSlot: slotIndex)
    }

    private func applyImage(_ image: NSImage, toSlot slotIndex: Int) {
        slotImages[slotIndex] = image
        customIcon = image

        // Update tile visuals
        if slotIndex < presetButtons.count {
            let button = presetButtons[slotIndex]
            button.isImageWell = false
            addImageView(to: button, image: image)
            // Reassign action to presetClicked since it now has an image
            button.action = #selector(presetClicked(_:))
        }

        // Persist slot image to disk
        let layout = VMFileLayout(bundleURL: bundleURL)
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: layout.slotIconURL(index: slotIndex))
        }

        selectPreset(index: slotIndex)
        onSelect?(nil, image)
    }
}
