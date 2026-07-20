import AppKit

/// App-wide user preferences, backed by UserDefaults. One home for the keys so
/// callers don't scatter raw strings.
enum PlateSettings {
    private static let hdrDisplayKey = "PlateHDRDisplayEnabled"

    /// Whether HDR photos (gain-map / PQ / HLG) render on the EDR surface.
    /// Default on. Exposed in Settings because HDR decode is inherently slower
    /// than the SDR pipeline on very large files — some users prefer speed.
    static var hdrDisplayEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hdrDisplayKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hdrDisplayKey) }
    }
}

/// Minimal Settings window (App ▸ Settings…, ⌘,). A single Display section for
/// now; grows sections as settings accrue. Same editorial-dark chrome as the
/// welcome window.
final class SettingsWindowController: NSWindowController {

    init() {
        let initial = NSRect(x: 0, y: 0, width: 460, height: 208)
        let window = NSWindow(
            contentRect: initial,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = PlateColor.primary
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.contentViewController = SettingsViewController()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class SettingsViewController: NSViewController {

    private let hdrCheckbox = NSButton(checkboxWithTitle: "Render HDR photos in HDR",
                                       target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 208))
        root.wantsLayer = true
        root.layer?.backgroundColor = PlateColor.primary.cgColor
        view = root

        // Section header — mono caps, matching the sidebar's group labels.
        let section = NSTextField(labelWithString: "DISPLAY")
        section.font = PlateFont.mono(10, weight: .medium)
        section.textColor = PlateColor.textSubtle
        let sectionAttr = NSMutableAttributedString(string: "DISPLAY")
        sectionAttr.addAttributes([
            .font: PlateFont.mono(10, weight: .medium),
            .foregroundColor: PlateColor.textSubtle,
            .kern: 1.4,
        ], range: NSRange(location: 0, length: sectionAttr.length))
        section.attributedStringValue = sectionAttr

        hdrCheckbox.target = self
        hdrCheckbox.action = #selector(toggleHDR)
        hdrCheckbox.state = PlateSettings.hdrDisplayEnabled ? .on : .off
        hdrCheckbox.font = PlateFont.body(13)

        // The honest trade-off, so the choice is informed: EDR highlights
        // vs. noticeably slower switching on big files.
        let note = NSTextField(wrappingLabelWithString:
            "HDR photos light up extra highlight detail on displays with extended dynamic range. " +
            "Decoding them takes longer than standard photos, so switching between large images " +
            "is slower while this is on. Takes effect from the next photo you open.")
        note.font = PlateFont.body(11)
        note.textColor = PlateColor.textMuted
        note.preferredMaxLayoutWidth = 396

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = PlateColor.hairline.cgColor

        for sub in [section, hairline, hdrCheckbox, note] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            section.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            section.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),

            hairline.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 8),
            hairline.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            hairline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            hdrCheckbox.topAnchor.constraint(equalTo: hairline.bottomAnchor, constant: 16),
            hdrCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            hdrCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -32),

            note.topAnchor.constraint(equalTo: hdrCheckbox.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 52),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            note.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
        ])
    }

    @objc private func toggleHDR() {
        PlateSettings.hdrDisplayEnabled = (hdrCheckbox.state == .on)
    }
}
