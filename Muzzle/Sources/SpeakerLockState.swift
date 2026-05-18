import AppKit
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SpeakerLockState {
    private let logger = Logger(subsystem: "Muzzle", category: "SpeakerLock")
    private let defaults: UserDefaults
    private let audioOutputController: AudioOutputControlling
    private let systemWakeObserver = SystemWakeObserver()
    private let notificationController: ProtectionNotifying
    private let loginItemController: LoginItemControlling
    @ObservationIgnored private var protectionPauseExpiryTask: Task<Void, Never>?

    var alwaysProtectionEnabled: Bool {
        didSet {
            defaults.set(alwaysProtectionEnabled, forKey: DefaultsKey.alwaysProtectionEnabled)
        }
    }

    var wakeProtectionEnabled: Bool {
        didSet {
            defaults.set(wakeProtectionEnabled, forKey: DefaultsKey.wakeProtectionEnabled)
        }
    }

    var startAtLoginEnabled: Bool {
        didSet {
            defaults.set(startAtLoginEnabled, forKey: DefaultsKey.startAtLoginEnabled)
            applyStartAtLoginPreference()
        }
    }

    var protectionPauseUntil: Date? {
        didSet {
            defaults.set(protectionPauseUntil, forKey: DefaultsKey.protectionPauseUntil)
            defaults.removeObject(forKey: LegacyDefaultsKey.speakerAllowanceUntil)
            scheduleProtectionPauseExpiry()
        }
    }

    var lastProtectionReason: ProtectionReason? {
        didSet {
            defaults.set(lastProtectionReason?.rawValue, forKey: DefaultsKey.lastProtectionReason)
        }
    }

    var currentOutput: AudioOutputDevice?
    var lastAudioActionMessage: String?
    private var recentProtectionEvents: [String] = []

    init(
        defaults: UserDefaults = .standard,
        startObservers: Bool = true,
        audioOutputController: AudioOutputControlling? = nil,
        notificationController: ProtectionNotifying? = nil,
        loginItemController: LoginItemControlling? = nil,
        applyLoginItemPreference: Bool? = nil
    ) {
        self.defaults = defaults
        self.audioOutputController = audioOutputController ?? AudioOutputController()
        self.notificationController = notificationController ?? ProtectionNotificationController()
        self.loginItemController = loginItemController ?? LoginItemController()
        let shouldApplyLoginItemPreference = applyLoginItemPreference ?? startObservers
        alwaysProtectionEnabled = defaults.object(forKey: DefaultsKey.alwaysProtectionEnabled) as? Bool ?? true
        wakeProtectionEnabled =
            defaults.object(forKey: DefaultsKey.wakeProtectionEnabled) as? Bool ??
            defaults.object(forKey: DefaultsKey.roamingProtectionEnabled) as? Bool ??
            true
        startAtLoginEnabled = defaults.object(forKey: DefaultsKey.startAtLoginEnabled) as? Bool ?? true
        protectionPauseUntil =
            defaults.object(forKey: DefaultsKey.protectionPauseUntil) as? Date ??
            defaults.object(forKey: LegacyDefaultsKey.speakerAllowanceUntil) as? Date

        if let rawReason = defaults.string(forKey: DefaultsKey.lastProtectionReason) {
            lastProtectionReason = ProtectionReason(rawValue: rawReason)
        }

        guard startObservers else {
            if shouldApplyLoginItemPreference {
                applyStartAtLoginPreference()
            }
            scheduleProtectionPauseExpiry()
            return
        }

        self.audioOutputController.onDefaultOutputChanged = { [weak self] output in
            self?.handleDefaultOutputChanged(output)
        }
        systemWakeObserver.onWake = { [weak self] in
            self?.handleWake()
        }
        self.audioOutputController.startObservingDefaultOutput()
        systemWakeObserver.startObserving()
        applyStartAtLoginPreference()
        refreshCurrentOutput()
        scheduleProtectionPauseExpiry()
    }

    deinit {
        protectionPauseExpiryTask?.cancel()
    }

    var isProtectionPauseActive: Bool {
        guard let protectionPauseUntil else {
            return false
        }

        return protectionPauseUntil > Date()
    }

    var protectionPauseRemainingText: String? {
        guard let protectionPauseUntil, protectionPauseUntil > Date() else {
            return nil
        }

        let remainingSeconds = Int(protectionPauseUntil.timeIntervalSinceNow.rounded(.up))
        let minutes = max(1, Int(ceil(Double(remainingSeconds) / 60.0)))

        return "\(minutes)m left"
    }

    var statusText: String {
        statusMenuTitle
    }

    var statusMenuTitle: String {
        if let protectionPauseRemainingText {
            return "Protection paused - \(protectionPauseRemainingText)"
        }

        if let protectionModeTitle {
            if let currentOutput {
                if currentOutput.isBuiltInSpeaker {
                    if let lastProtectionReason, isReasonRelevant(lastProtectionReason) {
                        return "Protected - \(lastProtectionReason.displayName)"
                    }

                    return "Protected - rules active"
                }

                return "Protected - \(currentOutput.name) connected"
            }

            return "Protected - \(protectionModeTitle)"
        }

        if let currentOutput {
            return "Not protected - \(currentOutput.name) connected"
        }

        return "Not protected - monitoring off"
    }

    var statusMenuIcon: String {
        if isProtectionPauseActive {
            return "waveform.badge.exclamationmark"
        }

        if alwaysProtectionEnabled || wakeProtectionEnabled {
            return "waveform.badge.checkmark"
        }

        return "waveform"
    }

    var menuBarBadgeSystemImage: String? {
        guard alwaysProtectionEnabled || wakeProtectionEnabled else {
            return nil
        }

        if isProtectionPauseActive {
            return "clock.fill"
        }

        return "checkmark.shield.fill"
    }

    private func isReasonRelevant(_ reason: ProtectionReason) -> Bool {
        switch reason {
        case .wake:
            return wakeProtectionEnabled
        case .networkChanged:
            return false
        case .outputChanged:
            return alwaysProtectionEnabled
        case .manual:
            return alwaysProtectionEnabled || wakeProtectionEnabled
        }
    }

    private var protectionModeTitle: String? {
        switch (alwaysProtectionEnabled, wakeProtectionEnabled) {
        case (true, true):
            return "headphones and wake active"
        case (true, false):
            return "headphones active"
        case (false, true):
            return "wake active"
        case (false, false):
            return nil
        }
    }

    func pauseProtection(for duration: TimeInterval) {
        protectionPauseUntil = Date().addingTimeInterval(duration)
        lastProtectionReason = nil
        lastAudioActionMessage = "Protection paused temporarily"
        appendProtectionEvent("protection pause set for \(Int(duration))s")
    }

    func resumeProtectionNow() {
        protectionPauseUntil = nil
        lastAudioActionMessage = "Protection resumed"
        appendProtectionEvent("manual protection pause cleared")
    }

    func handleWakeRisk(reason: ProtectionReason) {
        guard reason == .wake else {
            appendProtectionEvent("ignored non-wake reason: \(reason.rawValue)")
            logger.error("Ignoring non-wake protection reason: \(reason.rawValue)")
            return
        }

        currentOutput = audioOutputController.currentDefaultOutput()
        appendProtectionEvent("wake check started: reason=\(reason.rawValue), output=\(currentOutput?.name ?? "nil")")

        guard wakeProtectionEnabled else {
            lastAudioActionMessage = "Wake protection is off"
            appendProtectionEvent("wake check skipped: disabled")
            return
        }

        guard !isProtectionPauseActive else {
            lastAudioActionMessage = "Protection paused during wake check"
            appendProtectionEvent("wake check skipped: protection pause active until \(protectionPauseUntil?.description ?? "nil")")
            return
        }

        guard let currentOutput else {
            lastAudioActionMessage = "Wake check could not detect current output"
            appendProtectionEvent("wake check skipped: no current output")
            logger.error("Wake protection could not detect current output. reason=\(reason.rawValue)")
            return
        }

        guard currentOutput.isBuiltInSpeaker else {
            lastAudioActionMessage = "Wake check passed; \(currentOutput.name) allowed"
            appendProtectionEvent("wake check passed: \(currentOutput.name) is not built-in speakers")
            return
        }

        blockSpeakers(currentOutput, reason: reason)
    }

    func refreshCurrentOutput() {
        currentOutput = audioOutputController.currentDefaultOutput()

        if let currentOutput {
            lastAudioActionMessage = "Detected \(currentOutput.name)"
            appendProtectionEvent("manual output refresh: \(currentOutput.name), builtInSpeaker=\(currentOutput.isBuiltInSpeaker)")
        } else {
            lastAudioActionMessage = "Could not detect current output"
            appendProtectionEvent("manual output refresh failed")
        }
    }

    func copyDiagnosticsToClipboard() {
        let report = diagnosticsReport()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        appendProtectionEvent("diagnostics copied to clipboard")
    }

    private func handleDefaultOutputChanged(_ output: AudioOutputDevice?) {
        let previousOutput = currentOutput
        currentOutput = output

        guard let output else {
            lastAudioActionMessage = "Output changed, but no output device was detected"
            appendProtectionEvent("default output changed to nil")
            logger.error("Default output changed to nil")
            return
        }

        lastAudioActionMessage = "Output changed to \(output.name)"
        appendProtectionEvent("default output changed: \(previousOutput?.name ?? "nil") -> \(output.name), builtInSpeaker=\(output.isBuiltInSpeaker)")

        guard shouldBlockAfterOutputChange(from: previousOutput, to: output) else {
            appendProtectionEvent("always protection did not block output change")
            return
        }

        blockSpeakers(output, reason: .outputChanged)
        recheckSpeakerBlockAfterOutputSettles()
    }

    private func handleWake() {
        appendProtectionEvent("wake trigger received")
        handleWakeRisk(reason: .wake)
    }

    private func shouldBlockAfterOutputChange(from previousOutput: AudioOutputDevice?, to output: AudioOutputDevice) -> Bool {
        guard alwaysProtectionEnabled else {
            appendProtectionEvent("always protection skipped: disabled")
            return false
        }

        guard !isProtectionPauseActive else {
            lastAudioActionMessage = "Protection paused after output change"
            appendProtectionEvent("always protection skipped: protection pause active")
            return false
        }

        let shouldBlock = output.isBuiltInSpeaker && previousOutput?.isBuiltInSpeaker != true
        appendProtectionEvent("always protection decision: shouldBlock=\(shouldBlock)")
        return shouldBlock
    }

    private func recheckSpeakerBlockAfterOutputSettles() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard self.alwaysProtectionEnabled, !self.isProtectionPauseActive else {
                self.appendProtectionEvent("settled output recheck skipped")
                return
            }

            let refreshedOutput = self.audioOutputController.currentDefaultOutput()
            self.currentOutput = refreshedOutput
            self.appendProtectionEvent("settled output recheck: \(refreshedOutput?.name ?? "nil"), builtInSpeaker=\(refreshedOutput?.isBuiltInSpeaker == true)")

            guard let refreshedOutput, refreshedOutput.isBuiltInSpeaker else {
                return
            }

            self.blockSpeakers(refreshedOutput, reason: .outputChanged)
        }
    }

    private func applyStartAtLoginPreference() {
        guard loginItemController.isEnabled != startAtLoginEnabled else {
            return
        }

        do {
            try loginItemController.setEnabled(startAtLoginEnabled)
            appendProtectionEvent("start at login \(startAtLoginEnabled ? "enabled" : "disabled")")
        } catch {
            lastAudioActionMessage = "Could not update start at login"
            appendProtectionEvent("start at login update failed: \(error.localizedDescription)")
            logger.error("Failed to update start at login. enabled=\(self.startAtLoginEnabled), error=\(error.localizedDescription)")
        }
    }

    private func scheduleProtectionPauseExpiry() {
        protectionPauseExpiryTask?.cancel()
        protectionPauseExpiryTask = nil

        guard let protectionPauseUntil else {
            return
        }

        guard protectionPauseUntil > Date() else {
            expireProtectionPause(expectedPauseUntil: protectionPauseUntil)
            return
        }

        protectionPauseExpiryTask = Task { [weak self, protectionPauseUntil] in
            let delay = max(0, protectionPauseUntil.timeIntervalSinceNow)
            let nanoseconds = UInt64((delay * 1_000_000_000).rounded(.up))

            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.expireProtectionPause(expectedPauseUntil: protectionPauseUntil)
        }
    }

    private func expireProtectionPause(expectedPauseUntil: Date) {
        guard protectionPauseUntil == expectedPauseUntil else {
            appendProtectionEvent("stale protection pause expiry ignored")
            return
        }

        protectionPauseUntil = nil
        lastAudioActionMessage = "Protection pause expired"
        appendProtectionEvent("protection pause expired")

        guard alwaysProtectionEnabled || wakeProtectionEnabled else {
            appendProtectionEvent("expiry recheck skipped: protections disabled")
            return
        }

        let refreshedOutput = audioOutputController.currentDefaultOutput()
        currentOutput = refreshedOutput
        appendProtectionEvent("expiry recheck: \(refreshedOutput?.name ?? "nil"), builtInSpeaker=\(refreshedOutput?.isBuiltInSpeaker == true)")

        guard let refreshedOutput, refreshedOutput.isBuiltInSpeaker else {
            return
        }

        blockSpeakers(refreshedOutput, reason: .manual)
    }

    private func blockSpeakers(_ output: AudioOutputDevice, reason: ProtectionReason) {
        lastProtectionReason = reason
        let shouldNotify = audioOutputController.hasPotentiallyAudibleOutput(output)
        appendProtectionEvent("blocking speakers: reason=\(reason.rawValue), output=\(output.name)")

        if audioOutputController.setMuted(true, for: output) {
            lastAudioActionMessage = "Muted \(output.name)"
            appendProtectionEvent("block succeeded by mute: \(output.name)")
            if shouldNotify {
                notificationController.notifySpeakersBlocked(reason: reason)
            } else {
                appendProtectionEvent("notification skipped: output already blocked")
            }
            return
        }

        if audioOutputController.setVolume(0, for: output) {
            lastAudioActionMessage = "Set \(output.name) volume to 0"
            appendProtectionEvent("block succeeded by volume 0: \(output.name)")
            if shouldNotify {
                notificationController.notifySpeakersBlocked(reason: reason)
            } else {
                appendProtectionEvent("notification skipped: output already blocked")
            }
            return
        }

        lastAudioActionMessage = "Could not block \(output.name)"
        appendProtectionEvent("block failed: \(output.name)")
        logger.error("Failed to block speakers. reason=\(reason.rawValue), output=\(output.name)")
    }

    private func diagnosticsReport() -> String {
        let protectionPauseStatus: String
        if let protectionPauseUntil {
            if isProtectionPauseActive {
                protectionPauseStatus = "ACTIVE until \(Self.diagnosticsTimestamp(protectionPauseUntil)) (\(protectionPauseRemainingText ?? "less than 1m left"))"
            } else {
                protectionPauseStatus = "expired at \(Self.diagnosticsTimestamp(protectionPauseUntil))"
            }
        } else {
            protectionPauseStatus = "none"
        }

        let protectionDiagnosis = diagnosticsProtectionDiagnosis(protectionPauseStatus: protectionPauseStatus)
        let outputLines: [String]
        if let currentOutput {
            outputLines = [
                "Output name: \(currentOutput.name)",
                "Output id: \(currentOutput.id)",
                "Output uid: \(currentOutput.uid)",
                "Output transport: \(currentOutput.transportType.map(String.init) ?? "nil")",
                "Output dataSourceID: \(currentOutput.dataSourceID.map(String.init) ?? "nil")",
                "Output terminals: \(currentOutput.outputTerminalTypes.map(String.init).joined(separator: ","))",
                "Output builtInSpeaker: \(currentOutput.isBuiltInSpeaker)",
                "Output detection: \(currentOutput.builtInSpeakerDetectionReason)",
            ]
        } else {
            outputLines = ["Output: nil"]
        }

        return """
        Muzzle Diagnostics
        Generated: \(Self.diagnosticsTimestamp(Date()))
        Timezone: \(TimeZone.current.identifier) (\(Self.timeZoneOffsetText))

        Protection Diagnosis
        \(protectionDiagnosis)

        App State
        Always protection: \(alwaysProtectionEnabled)
        Wake protection: \(wakeProtectionEnabled)
        Start at login: \(startAtLoginEnabled)
        Protection pause: \(protectionPauseStatus)
        Protection pause active: \(isProtectionPauseActive)
        Last protection reason: \(lastProtectionReason?.rawValue ?? "nil")
        Last audio action: \(lastAudioActionMessage ?? "nil")
        Status: \(statusText)

        Audio
        \(outputLines.joined(separator: "\n"))

        Recent Protection Events
        \(recentProtectionEvents.isEmpty ? "none" : recentProtectionEvents.joined(separator: "\n"))
        """
    }

    private func diagnosticsProtectionDiagnosis(protectionPauseStatus: String) -> String {
        var lines: [String] = []

        if !alwaysProtectionEnabled && !wakeProtectionEnabled {
            lines.append("Protections are disabled.")
        } else if isProtectionPauseActive {
            lines.append("Protection pause is ACTIVE. Built-in speaker blocks are intentionally suppressed.")
            lines.append("Protection pause: \(protectionPauseStatus)")
        } else {
            lines.append("No active protection pause. Built-in speakers should be blocked on matching protection triggers.")
        }

        if let currentOutput {
            lines.append("Current output is \(currentOutput.isBuiltInSpeaker ? "built-in speakers" : "not built-in speakers"): \(currentOutput.name).")
        } else {
            lines.append("Current output is unknown.")
        }

        if let lastProtectionEvent = recentProtectionEvents.last {
            lines.append("Last protection event: \(lastProtectionEvent)")
        } else {
            lines.append("Last protection event: none")
        }

        return lines.joined(separator: "\n")
    }

    private func appendProtectionEvent(_ message: String) {
        recentProtectionEvents.append("\(Self.timestamp()): \(message)")
        if recentProtectionEvents.count > 60 {
            recentProtectionEvents.removeFirst(recentProtectionEvents.count - 60)
        }
    }

    private static func timestamp() -> String {
        diagnosticsTimeFormatter.string(from: Date())
    }

    private static func diagnosticsTimestamp(_ date: Date) -> String {
        diagnosticsDateTimeFormatter.string(from: date)
    }

    private static var timeZoneOffsetText: String {
        let seconds = TimeZone.current.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let absoluteSeconds = abs(seconds)
        let hours = absoluteSeconds / 3600
        let minutes = (absoluteSeconds % 3600) / 60
        return String(format: "UTC%@%02d:%02d", sign, hours, minutes)
    }

    private static let diagnosticsTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let diagnosticsDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZ"
        return formatter
    }()
}

enum ProtectionReason: String {
    case outputChanged
    case wake
    case networkChanged
    case manual

    var displayName: String {
        switch self {
        case .outputChanged:
            "headphones disconnected"
        case .wake:
            "Mac woke up"
        case .networkChanged:
            "network changed"
        case .manual:
            "manual action"
        }
    }

    var isWakeRisk: Bool {
        switch self {
        case .wake:
            true
        case .outputChanged, .networkChanged, .manual:
            false
        }
    }
}

private enum DefaultsKey {
    static let alwaysProtectionEnabled = "alwaysProtectionEnabled"
    static let wakeProtectionEnabled = "wakeProtectionEnabled"
    static let roamingProtectionEnabled = "roamingProtectionEnabled"
    static let startAtLoginEnabled = "startAtLoginEnabled"
    static let protectionPauseUntil = "protectionPauseUntil"
    static let lastProtectionReason = "lastProtectionReason"
}

private enum LegacyDefaultsKey {
    static let speakerAllowanceUntil = "speakerAllowanceUntil"
}
