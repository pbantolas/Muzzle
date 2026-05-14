import AppKit
import Foundation
import OSLog

final class SystemWakeObserver {
    private let logger = Logger(subsystem: "DontBlastMySound", category: "SystemWake")
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

        logger.info("Started observing wake notifications")
    }

    func stopObserving() {
        guard let wakeObserver else {
            return
        }

        NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        self.wakeObserver = nil
        logger.info("Stopped observing wake notifications")
    }

    private func handleWake() {
        logger.info("System wake detected")

        Task { @MainActor in
            onWake?()
        }
    }
}
