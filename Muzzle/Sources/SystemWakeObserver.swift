import AppKit
import Foundation

final class SystemWakeObserver {
    private var wakeObserver: NSObjectProtocol?

    var onWake: (@MainActor () -> Void)?

    deinit {
        stopObserving()
    }

    func startObserving() {
        guard wakeObserver == nil else {
            return
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    func stopObserving() {
        guard let wakeObserver else {
            return
        }

        NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        self.wakeObserver = nil
    }

    private func handleWake() {
        Task { @MainActor in
            onWake?()
        }
    }
}
