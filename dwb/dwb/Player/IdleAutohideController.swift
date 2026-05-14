import Cocoa

/// Reusable AppKit idle tracker for chrome that should reveal on user activity
/// and hide after a quiet period.
final class IdleAutohideController {
    typealias VisibilityHandler = (_ visible: Bool, _ animated: Bool) -> Void
    typealias VisibilityHoldProvider = () -> Bool

    var threshold: TimeInterval {
        didSet {
            threshold = max(0.1, threshold)
            guard oldValue != threshold else { return }
            if isVisible { scheduleHide() }
        }
    }

    var reduceMotion: Bool
    var visibilityHoldProvider: VisibilityHoldProvider?

    private let visibilityHandler: VisibilityHandler
    private var hideTimer: Timer?
    private var suspensionCount = 0
    private var isVisible = true
    private var isEnabled = false

    init(threshold: TimeInterval = 3.0,
         reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
         visibilityHoldProvider: VisibilityHoldProvider? = nil,
         visibilityHandler: @escaping VisibilityHandler) {
        self.threshold = max(0.1, threshold)
        self.reduceMotion = reduceMotion
        self.visibilityHoldProvider = visibilityHoldProvider
        self.visibilityHandler = visibilityHandler
    }

    deinit {
        hideTimer?.invalidate()
    }

    func start(visible: Bool = true) {
        isEnabled = true
        setVisible(visible, animated: false)
        scheduleHide()
    }

    func stop(visible: Bool = true) {
        isEnabled = false
        hideTimer?.invalidate()
        hideTimer = nil
        setVisible(visible, animated: false)
    }

    func noteMouseMoved() {
        revealAndSchedule()
    }

    func noteMouseEntered() {
        revealAndSchedule()
    }

    func noteKeyDown() {
        revealAndSchedule()
    }

    func noteFlagsChanged() {
        revealAndSchedule()
    }

    func beginSuspension(reveal: Bool = true) {
        suspensionCount += 1
        hideTimer?.invalidate()
        hideTimer = nil
        if reveal { setVisible(true, animated: !reduceMotion) }
    }

    func endSuspension() {
        suspensionCount = max(0, suspensionCount - 1)
        scheduleHide()
    }

    func setSuspended(_ suspended: Bool, reveal: Bool = true) {
        if suspended {
            if suspensionCount == 0 {
                beginSuspension(reveal: reveal)
            }
        } else {
            suspensionCount = 0
            scheduleHide()
        }
    }

    private func revealAndSchedule() {
        guard isEnabled else { return }
        setVisible(true, animated: !reduceMotion)
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard isEnabled else { return }
        guard suspensionCount == 0 else { return }
        guard visibilityHoldProvider?() != true else { return }

        hideTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            guard let self = self, self.isEnabled else { return }
            guard self.suspensionCount == 0 else { return }
            guard self.visibilityHoldProvider?() != true else {
                self.scheduleHide()
                return
            }
            self.setVisible(false, animated: !self.reduceMotion)
        }
    }

    private func setVisible(_ visible: Bool, animated: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        visibilityHandler(visible, animated)
    }
}
