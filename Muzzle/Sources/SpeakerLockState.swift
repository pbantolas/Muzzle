import AppKit
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SpeakerLockState {
    private let logger = Logger(subsystem: "Muzzle", category: "SpeakerLock")
    private let defaults: UserDefaults
    private let audioOutputController = AudioOutputController()
    private let networkEnvironmentObserver = NetworkEnvironmentObserver()
    private let systemWakeObserver = SystemWakeObserver()
    private let loginItemController: LoginItemControlling
    @ObservationIgnored private var protectionPauseExpiryTask: Task<Void, Never>?

    var alwaysProtectionEnabled: Bool {
        didSet {
            defaults.set(alwaysProtectionEnabled, forKey: DefaultsKey.alwaysProtectionEnabled)
        }
    }

    var roamingProtectionEnabled: Bool {
        didSet {
            defaults.set(roamingProtectionEnabled, forKey: DefaultsKey.roamingProtectionEnabled)
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
    var networkDebugState = NetworkEnvironmentDebugState(
        snapshot: nil,
        lastTrigger: nil,
        locationAuthorizationStatus: .notDetermined,
        recentEvents: []
    )
    private var recentProtectionEvents: [String] = []

    init(
        defaults: UserDefaults = .standard,
        startObservers: Bool = true,
        loginItemController: LoginItemControlling? = nil,
        applyLoginItemPreference: Bool? = nil
    ) {
        self.defaults = defaults
        self.loginItemController = loginItemController ?? LoginItemController()
        let shouldApplyLoginItemPreference = applyLoginItemPreference ?? startObservers
        alwaysProtectionEnabled = defaults.object(forKey: DefaultsKey.alwaysProtectionEnabled) as? Bool ?? true
        roamingProtectionEnabled = defaults.object(forKey: DefaultsKey.roamingProtectionEnabled) as? Bool ?? true
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

        audioOutputController.onDefaultOutputChanged = { [weak self] output in
            self?.handleDefaultOutputChanged(output)
        }
        networkEnvironmentObserver.onNetworkEnvironmentChanged = { [weak self] change in
            self?.handleNetworkEnvironmentChanged(change)
        }
        networkEnvironmentObserver.onDebugStateChanged = { [weak self] debugState in
            self?.networkDebugState = debugState
        }
        systemWakeObserver.onWake = { [weak self] in
            self?.handleWake()
        }
        audioOutputController.startObservingDefaultOutput()
        networkEnvironmentObserver.startObserving()
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

        if alwaysProtectionEnabled || roamingProtectionEnabled {
            return "waveform.badge.checkmark"
        }

        return "waveform"
    }

    var networkInfoSummary: String {
        guard let wifiIdentity = networkDebugState.snapshot?.wifiIdentity else {
            return "No Wi-Fi details"
        }

        if let ssid = wifiIdentity.ssid {
            return "Wi-Fi: \(ssid)"
        }

        if let interfaceName = wifiIdentity.interfaceName {
            return "Wi-Fi: \(interfaceName)"
        }

        return "Wi-Fi available"
    }

    var menuBarBadgeSystemImage: String? {
        guard alwaysProtectionEnabled || roamingProtectionEnabled else {
            return nil
        }

        if isProtectionPauseActive {
            return "clock.fill"
        }

        return "checkmark.shield.fill"
    }

    private func isReasonRelevant(_ reason: ProtectionReason) -> Bool {
        switch reason {
        case .wake, .networkChanged:
            return roamingProtectionEnabled
        case .outputChanged:
            return alwaysProtectionEnabled
        case .manual:
            return alwaysProtectionEnabled || roamingProtectionEnabled
        }
    }

    private var protectionModeTitle: String? {
        switch (alwaysProtectionEnabled, roamingProtectionEnabled) {
        case (true, true):
            return "headphones and location active"
        case (true, false):
            return "headphones active"
        case (false, true):
            return "location active"
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

    func handleRoamingRisk(reason: ProtectionReason) {
        guard reason.isRoamingRisk else {
            appendProtectionEvent("ignored non-roaming reason: \(reason.rawValue)")
            logger.error("Ignoring non-roaming protection reason: \(reason.rawValue)")
            return
        }

        currentOutput = audioOutputController.currentDefaultOutput()
        appendProtectionEvent("roaming check started: reason=\(reason.rawValue), output=\(currentOutput?.name ?? "nil")")

        guard roamingProtectionEnabled else {
            lastAudioActionMessage = "Roaming protection is off"
            appendProtectionEvent("roaming check skipped: disabled")
            return
        }

        guard !isProtectionPauseActive else {
            lastAudioActionMessage = "Protection paused during roaming check"
            appendProtectionEvent("roaming check skipped: protection pause active until \(protectionPauseUntil?.description ?? "nil")")
            return
        }

        guard let currentOutput else {
            lastAudioActionMessage = "Roaming check could not detect current output"
            appendProtectionEvent("roaming check skipped: no current output")
            logger.error("Roaming Protection could not detect current output. reason=\(reason.rawValue)")
            return
        }

        guard currentOutput.isBuiltInSpeaker else {
            lastAudioActionMessage = "Roaming check passed; \(currentOutput.name) allowed"
            appendProtectionEvent("roaming check passed: \(currentOutput.name) is not built-in speakers")
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

    private func handleNetworkEnvironmentChanged(_ change: NetworkEnvironmentChange) {
        appendProtectionEvent("network environment trigger received: \(change.trigger.debugDisplayName)")
        handleRoamingRisk(reason: .networkChanged)
    }

    private func handleWake() {
        appendProtectionEvent("wake trigger received")
        handleRoamingRisk(reason: .wake)
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

        guard alwaysProtectionEnabled || roamingProtectionEnabled else {
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
        appendProtectionEvent("blocking speakers: reason=\(reason.rawValue), output=\(output.name)")

        if audioOutputController.setMuted(true, for: output) {
            lastAudioActionMessage = "Muted \(output.name)"
            appendProtectionEvent("block succeeded by mute: \(output.name)")
            return
        }

        if audioOutputController.setVolume(0, for: output) {
            lastAudioActionMessage = "Set \(output.name) volume to 0"
            appendProtectionEvent("block succeeded by volume 0: \(output.name)")
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
        Roaming protection: \(roamingProtectionEnabled)
        Start at login: \(startAtLoginEnabled)
        Protection pause: \(protectionPauseStatus)
        Protection pause active: \(isProtectionPauseActive)
        Last protection reason: \(lastProtectionReason?.rawValue ?? "nil")
        Last audio action: \(lastAudioActionMessage ?? "nil")
        Status: \(statusText)

        Audio
        \(outputLines.joined(separator: "\n"))

        Network Debug
        \(networkDebugState.wifiSummary)
        \(networkDebugState.wifiIdentitySummary)
        \(networkDebugState.locationAuthorizationSummary)
        \(networkDebugState.pathSummary)
        \(networkDebugState.triggerSummary)

        Recent Protection Events
        \(recentProtectionEvents.isEmpty ? "none" : recentProtectionEvents.joined(separator: "\n"))

        Recent Network Events
        \(networkDebugState.recentEvents.isEmpty ? "none" : networkDebugState.recentEvents.joined(separator: "\n"))
        """
    }

    private func diagnosticsProtectionDiagnosis(protectionPauseStatus: String) -> String {
        var lines: [String] = []

        if !alwaysProtectionEnabled && !roamingProtectionEnabled {
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

        if let lastNetworkEvent = networkDebugState.recentEvents.last {
            lines.append("Last network event: \(lastNetworkEvent)")
        } else {
            lines.append("Last network event: none")
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
            "Wi-Fi changed"
        case .manual:
            "manual action"
        }
    }

    var isRoamingRisk: Bool {
        switch self {
        case .wake, .networkChanged:
            true
        case .outputChanged, .manual:
            false
        }
    }
}

private enum DefaultsKey {
    static let alwaysProtectionEnabled = "alwaysProtectionEnabled"
    static let roamingProtectionEnabled = "roamingProtectionEnabled"
    static let startAtLoginEnabled = "startAtLoginEnabled"
    static let protectionPauseUntil = "protectionPauseUntil"
    static let lastProtectionReason = "lastProtectionReason"
}

private enum LegacyDefaultsKey {
    static let speakerAllowanceUntil = "speakerAllowanceUntil"
}
