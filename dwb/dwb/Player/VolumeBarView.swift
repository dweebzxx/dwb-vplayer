import Cocoa

/// Interactive vertical volume bar overlay shown on the right side of the player.
/// Appears transiently when volume changes (scroll, buttons, or direct interaction).
/// Supports click-to-set and drag-to-adjust.  Normal range (0–100) rendered in white;
/// extended software gain (101–150) rendered in orange with a visible divider at 100.
final class VolumeBarView: NSView {

    // MARK: - Geometry constants
    // These define the track within the view.  View size is set by PlayerWindowController.
    // Suite-standard volume HUD geometry — keep in sync with dwb skim VolumeBarView.
    private let trackX: CGFloat     = 38    // left edge of the bar track
    private let trackY: CGFloat     = 22    // bottom of the bar track (vol = 0)
    private let trackW: CGFloat     = 8     // bar width
    private let trackH: CGFloat     = 140   // bar height (vol = 150 at top)
    private let labelX: CGFloat     = 4     // left edge of tick labels
    private let labelW: CGFloat     = 30    // width of tick labels

    // Derived: y-coordinate of the vol=100 boundary within the view
    private var dividerY: CGFloat { trackY + trackH * 100.0 / 150.0 }

    // MARK: - Layers
    private let trackBgLayer     = CALayer()
    private let normalFillLayer  = CALayer()
    private let extFillLayer     = CALayer()
    private let dividerLineLayer = CALayer()

    // MARK: - Labels (visible only while bar is exposed)
    private let valueLabel = VolumeBarView.valueLabel()
    private let label0   = VolumeBarView.tickLabel("0")
    private let label100 = VolumeBarView.tickLabel("100")
    private let label150 = VolumeBarView.tickLabel("150")

    // MARK: - State
    private(set) var currentVolume: Int32 = 100
    private var isDragging  = false
    private var hideTimer: Timer?

    /// Called when the user adjusts volume by clicking or dragging the bar.
    var onVolumeChanged: ((Int32) -> Void)?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupBackground()
        setupTrackLayers()
        setupLabels()
        alphaValue = 0
        isHidden   = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layer setup

    private func setupBackground() {
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        root.cornerRadius = 9
        root.masksToBounds = true
        // Suite-standard 1.0px hairline on HUD surfaces (matches transport chrome).
        root.borderWidth = 1.0
        root.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    private func setupTrackLayers() {
        guard let root = layer else { return }

        trackBgLayer.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        trackBgLayer.cornerRadius = 3
        root.addSublayer(trackBgLayer)

        normalFillLayer.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
        normalFillLayer.cornerRadius = 3
        root.addSublayer(normalFillLayer)

        extFillLayer.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.88).cgColor
        extFillLayer.cornerRadius = 3
        root.addSublayer(extFillLayer)

        // Horizontal divider line at the vol=100 boundary, visible when extended gain is active
        dividerLineLayer.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.65).cgColor
        dividerLineLayer.isHidden = true
        root.addSublayer(dividerLineLayer)
    }

    private func setupLabels() {
        for label in [valueLabel, label0, label100, label150] {
            addSubview(label)
        }
    }

    private static func valueLabel() -> NSTextField {
        let f = NSTextField(labelWithString: "100")
        f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        f.textColor = NSColor.white.withAlphaComponent(0.85)
        f.drawsBackground = false
        f.isBordered = false
        f.alignment = .center
        return f
    }

    private static func tickLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 9, weight: .regular)
        f.textColor = NSColor.white.withAlphaComponent(0.60)
        f.drawsBackground = false
        f.isBordered = false
        f.alignment = .right
        return f
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let safeWidth = (bounds.width.isFinite && bounds.width >= 0) ? bounds.width : 0

        // Track background
        trackBgLayer.frame = NSRect(x: trackX, y: trackY, width: trackW, height: trackH)

        // Tick labels
        let labelH: CGFloat = 11
        valueLabel.frame = NSRect(x: 0, y: trackY + trackH + 8, width: safeWidth, height: 14)
        label0.frame   = NSRect(x: labelX, y: trackY - 2,               width: labelW, height: labelH)
        label100.frame = NSRect(x: labelX, y: dividerY - 2,             width: labelW, height: labelH)
        label150.frame = NSRect(x: labelX, y: trackY + trackH - 2,      width: labelW, height: labelH)

        // Divider line
        dividerLineLayer.frame = NSRect(x: trackX - 2, y: dividerY,
                                        width: trackW + 4, height: 1)

        updateFillLayers()
    }

    // MARK: - Fill update (no animation – called frequently during drag)

    private func updateFillLayers() {
        let vol = CGFloat(max(0, min(150, currentVolume)))
        let normalH = trackH * min(vol, 100) / 150
        let extH    = trackH * max(0, vol - 100) / 150

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        normalFillLayer.frame = NSRect(x: trackX, y: trackY,
                                       width: trackW, height: normalH)
        extFillLayer.frame    = NSRect(x: trackX, y: trackY + normalH,
                                       width: trackW, height: extH)
        dividerLineLayer.isHidden = vol <= 100
        valueLabel.stringValue = String(Int(vol))
        valueLabel.textColor = vol > 100
            ? NSColor.systemOrange.withAlphaComponent(0.92)
            : NSColor.white.withAlphaComponent(0.85)
        label100.textColor = vol > 100
            ? NSColor.systemOrange
            : NSColor.white.withAlphaComponent(0.60)
        CATransaction.commit()
    }

    // MARK: - Public API

    /// Show the bar for `volume`, fade in if hidden, then schedule auto-hide.
    /// Safe to call during drag (bar stays visible until mouseUp).
    func show(volume: Int32) {
        currentVolume = volume
        updateFillLayers()

        guard !isDragging else { return }

        if isHidden || alphaValue < 0.05 {
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self.animator().alphaValue = 1.0
            }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            guard let self = self, !self.isDragging else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                self.animator().alphaValue = 0
            } completionHandler: {
                self.isHidden   = true
                self.alphaValue = 0
            }
        }
    }

    // MARK: - Mouse interaction

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }  // don't steal keyboard focus

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        hideTimer?.invalidate()
        isHidden   = false
        alphaValue = 1.0
        applyMouseVolume(event)
    }

    override func mouseDragged(with event: NSEvent) {
        applyMouseVolume(event)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        scheduleHide()
    }

    private func applyMouseVolume(_ event: NSEvent) {
        let pt  = convert(event.locationInWindow, from: nil)
        let vol = volumeForY(pt.y)
        currentVolume = vol
        updateFillLayers()
        onVolumeChanged?(vol)
    }

    private func volumeForY(_ y: CGFloat) -> Int32 {
        let frac = (y - trackY) / trackH
        return Int32(max(0, min(150, Int(frac * 150 + 0.5))))
    }
}
