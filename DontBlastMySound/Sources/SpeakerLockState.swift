import AppKit
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SpeakerLockState {
    private let logger = Logger(subsystem: "DontBlastMySound", category: "SpeakerLock")
    private let audioOutputController = AudioOutputController()
    private let networkEnvironmentObserver = NetworkEnvironmentObserver()
    private let systemWakeObserver = SystemWakeObserver()

    var alwaysProtectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alwaysProtectionEnabled, forKey: DefaultsKey.alwaysProtectionEnabled)
        }
    }

    var roamingProtectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(roamingProtectionEnabled, forKey: DefaultsKey.roamingProtectionEnabled)
        }
    }

    var speakerAllowanceUntil: Date? {
        didSet {
            UserDefaults.standard.set(speakerAllowanceUntil, forKey: DefaultsKey.speakerAllowanceUntil)
        }
    }

    var lastProtectionReason: ProtectionReason? {
        didSet {
            UserDefaults.standard.set(lastProtectionReason?.rawValue, forKey: DefaultsKey.lastProtectionReason)
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

    init() {
        alwaysProtectionEnabled = UserDefaults.standard.object(forKey: DefaultsKey.alwaysProtectionEnabled) as? Bool ?? true
        roamingProtectionEnabled = UserDefaults.standard.object(forKey: DefaultsKey.roamingProtectionEnabled) as? Bool ?? true
        speakerAllowanceUntil = UserDefaults.standard.object(forKey: DefaultsKey.speakerAllowanceUntil) as? Date

        if let rawReason = UserDefaults.standard.string(forKey: DefaultsKey.lastProtectionReason) {
            lastProtectionReason = ProtectionReason(rawValue: rawReason)
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
        refreshCurrentOutput()
    }

    var isSpeakerAllowanceActive: Bool {
        guard let speakerAllowanceUntil else {
            return false
        }

        return speakerAllowanceUntil > Date()
    }

    var allowanceRemainingText: String? {
        guard let speakerAllowanceUntil, speakerAllowanceUntil > Date() else {
            return nil
        }

        let remainingSeconds = Int(speakerAllowanceUntil.timeIntervalSinceNow.rounded(.up))
        let minutes = max(1, Int(ceil(Double(remainingSeconds) / 60.0)))

        return "\(minutes)m left"
    }

    var statusText: String {
        statusMenuTitle
    }

    var statusMenuTitle: String {
        if let allowanceRemainingText {
            return "Allowed - built-in speakers for \(allowanceRemainingText)"
        }

        if let currentOutput {
            if currentOutput.isBuiltInSpeaker {
                if let lastProtectionReason {
                    return "Blocked - \(currentOutput.name) by \(lastProtectionReason.displayName)"
                }

                if alwaysProtectionEnabled || roamingProtectionEnabled {
                    return "Attention Needed - \(currentOutput.name) active"
                }

                return "Unprotected - \(currentOutput.name) active"
            }

            if alwaysProtectionEnabled || roamingProtectionEnabled {
                return "Protected - \(currentOutput.name) connected"
            }

            return "Monitoring Off - \(currentOutput.name) connected"
        }

        if alwaysProtectionEnabled || roamingProtectionEnabled {
            return "Protected - waiting for audio output"
        }

        return "Monitoring Off - waiting for audio output"
    }

    var statusMenuIcon: String {
        if isSpeakerAllowanceActive {
            return "speaker.wave.2.fill"
        }

        if currentOutput?.isBuiltInSpeaker == true {
            if lastProtectionReason != nil {
                return "speaker.slash.fill"
            }

            return (alwaysProtectionEnabled || roamingProtectionEnabled) ? "exclamationmark.shield.fill" : "speaker.fill"
        }

        if alwaysProtectionEnabled || roamingProtectionEnabled {
            return "checkmark.shield.fill"
        }

        return "speaker"
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
        if isSpeakerAllowanceActive {
            return "exclamationmark.fill"
        }
        if currentOutput?.isBuiltInSpeaker == true {
            if lastProtectionReason != nil {
                return "lock.fill"
            }
            if alwaysProtectionEnabled || roamingProtectionEnabled {
                return "exclamationmark.fill"
            }
            return nil
        }
        if alwaysProtectionEnabled || roamingProtectionEnabled {
            return "checkmark"
        }
        return nil
    }

    func allowSpeakers(for duration: TimeInterval) {
        speakerAllowanceUntil = Date().addingTimeInterval(duration)
        lastProtectionReason = nil
        lastAudioActionMessage = "Built-in speakers allowed temporarily"
        appendProtectionEvent("temporary speaker allowance set for \(Int(duration))s")
        logger.info("Temporary speaker allowance set for \(duration) seconds")
    }

    func blockSpeakersNow() {
        speakerAllowanceUntil = nil
        appendProtectionEvent("manual block requested")
        guard let currentOutput else {
            lastAudioActionMessage = "No current output device detected"
            appendProtectionEvent("manual block skipped: no current output")
            logger.error("Manual block requested, but no output device is known")
            return
        }

        guard currentOutput.isBuiltInSpeaker else {
            lastAudioActionMessage = "\(currentOutput.name) is not detected as built-in speakers"
            appendProtectionEvent("manual block skipped: \(currentOutput.name) is not built-in speakers")
            logger.info("Manual block skipped because current output is not built-in speakers: \(currentOutput.name, privacy: .public)")
            return
        }

        blockSpeakers(currentOutput, reason: .manual)
    }

    func handleRoamingRisk(reason: ProtectionReason) {
        guard reason.isRoamingRisk else {
            appendProtectionEvent("ignored non-roaming reason: \(reason.rawValue)")
            logger.error("Ignoring non-roaming protection reason: \(reason.rawValue, privacy: .public)")
            return
        }

        currentOutput = audioOutputController.currentDefaultOutput()
        appendProtectionEvent("roaming check started: reason=\(reason.rawValue), output=\(currentOutput?.name ?? "nil")")

        guard roamingProtectionEnabled else {
            lastAudioActionMessage = "Roaming protection is off"
            appendProtectionEvent("roaming check skipped: disabled")
            logger.info("Roaming Protection skipped because it is disabled. reason=\(reason.rawValue, privacy: .public)")
            return
        }

        guard !isSpeakerAllowanceActive else {
            lastAudioActionMessage = "Speakers allowed during roaming check"
            appendProtectionEvent("roaming check skipped: allowance active until \(speakerAllowanceUntil?.description ?? "nil")")
            logger.info("Roaming Protection skipped because speaker allowance is active. reason=\(reason.rawValue, privacy: .public)")
            return
        }

        guard let currentOutput else {
            lastAudioActionMessage = "Roaming check could not detect current output"
            appendProtectionEvent("roaming check skipped: no current output")
            logger.error("Roaming Protection could not detect current output. reason=\(reason.rawValue, privacy: .public)")
            return
        }

        guard currentOutput.isBuiltInSpeaker else {
            lastAudioActionMessage = "Roaming check passed; \(currentOutput.name) allowed"
            appendProtectionEvent("roaming check passed: \(currentOutput.name) is not built-in speakers")
            logger.info(
                "Roaming Protection skipped because current output is not built-in speakers. reason=\(reason.rawValue, privacy: .public), output=\(currentOutput.name, privacy: .public)"
            )
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
        logger.info(
            "Default output changed from \(previousOutput?.name ?? "none", privacy: .public) to \(output.name, privacy: .public). builtInSpeaker=\(output.isBuiltInSpeaker)"
        )

        guard shouldBlockAfterOutputChange(from: previousOutput, to: output) else {
            appendProtectionEvent("always protection did not block output change")
            return
        }

        blockSpeakers(output, reason: .outputChanged)
        recheckSpeakerBlockAfterOutputSettles()
    }

    private func handleNetworkEnvironmentChanged(_ change: NetworkEnvironmentChange) {
        appendProtectionEvent("network environment trigger received: \(change.trigger.debugDisplayName)")
        logger.info("Network environment trigger: \(String(describing: change.trigger), privacy: .public)")
        handleRoamingRisk(reason: .networkChanged)
    }

    private func handleWake() {
        appendProtectionEvent("wake trigger received")
        logger.info("Wake trigger received")
        handleRoamingRisk(reason: .wake)
    }

    private func shouldBlockAfterOutputChange(from previousOutput: AudioOutputDevice?, to output: AudioOutputDevice) -> Bool {
        guard alwaysProtectionEnabled else {
            appendProtectionEvent("always protection skipped: disabled")
            return false
        }

        guard !isSpeakerAllowanceActive else {
            lastAudioActionMessage = "Speakers allowed after output change"
            appendProtectionEvent("always protection skipped: allowance active")
            logger.info("Always Protection skipped because speaker allowance is active")
            return false
        }

        let shouldBlock = output.isBuiltInSpeaker && previousOutput?.isBuiltInSpeaker != true
        appendProtectionEvent("always protection decision: shouldBlock=\(shouldBlock)")
        return shouldBlock
    }

    private func recheckSpeakerBlockAfterOutputSettles() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard self.alwaysProtectionEnabled, !self.isSpeakerAllowanceActive else {
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

    private func blockSpeakers(_ output: AudioOutputDevice, reason: ProtectionReason) {
        lastProtectionReason = reason
        appendProtectionEvent("blocking speakers: reason=\(reason.rawValue), output=\(output.name)")

        if audioOutputController.setMuted(true, for: output) {
            lastAudioActionMessage = "Muted \(output.name)"
            appendProtectionEvent("block succeeded by mute: \(output.name)")
            logger.info("Blocked speakers by mute. reason=\(reason.rawValue, privacy: .public), output=\(output.name, privacy: .public)")
            return
        }

        if audioOutputController.setVolume(0, for: output) {
            lastAudioActionMessage = "Set \(output.name) volume to 0"
            appendProtectionEvent("block succeeded by volume 0: \(output.name)")
            logger.info("Blocked speakers by setting volume to 0. reason=\(reason.rawValue, privacy: .public), output=\(output.name, privacy: .public)")
            return
        }

        lastAudioActionMessage = "Could not block \(output.name)"
        appendProtectionEvent("block failed: \(output.name)")
        logger.error("Failed to block speakers. reason=\(reason.rawValue, privacy: .public), output=\(output.name, privacy: .public)")
    }

    private func diagnosticsReport() -> String {
        let allowanceStatus: String
        if let speakerAllowanceUntil {
            if isSpeakerAllowanceActive {
                allowanceStatus = "ACTIVE until \(Self.diagnosticsTimestamp(speakerAllowanceUntil)) (\(allowanceRemainingText ?? "less than 1m left"))"
            } else {
                allowanceStatus = "expired at \(Self.diagnosticsTimestamp(speakerAllowanceUntil))"
            }
        } else {
            allowanceStatus = "none"
        }

        let protectionDiagnosis = diagnosticsProtectionDiagnosis(allowanceStatus: allowanceStatus)
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
        DontBlastMySound Diagnostics
        Generated: \(Self.diagnosticsTimestamp(Date()))
        Timezone: \(TimeZone.current.identifier) (\(Self.timeZoneOffsetText))

        Protection Diagnosis
        \(protectionDiagnosis)

        App State
        Always protection: \(alwaysProtectionEnabled)
        Roaming protection: \(roamingProtectionEnabled)
        Speaker allowance: \(allowanceStatus)
        Speaker allowance active: \(isSpeakerAllowanceActive)
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

    private func diagnosticsProtectionDiagnosis(allowanceStatus: String) -> String {
        var lines: [String] = []

        if !alwaysProtectionEnabled && !roamingProtectionEnabled {
            lines.append("Protections are disabled.")
        } else if isSpeakerAllowanceActive {
            lines.append("Temporary speaker allowance is ACTIVE. Built-in speaker blocks are intentionally suppressed.")
            lines.append("Allowance: \(allowanceStatus)")
        } else {
            lines.append("No active speaker allowance. Built-in speakers should be blocked on matching protection triggers.")
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
            "output change"
        case .wake:
            "wake"
        case .networkChanged:
            "network change"
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
    static let speakerAllowanceUntil = "speakerAllowanceUntil"
    static let lastProtectionReason = "lastProtectionReason"
}
