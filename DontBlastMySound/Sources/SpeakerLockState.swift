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
        locationAuthorizationStatus: .notDetermined
    )

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
        if let allowanceRemainingText {
            return "Speakers allowed, \(allowanceRemainingText)"
        }

        if let lastProtectionReason {
            return "Speakers blocked by \(lastProtectionReason.displayName)"
        }

        if let currentOutput {
            return "\(currentOutput.name) \(currentOutput.isBuiltInSpeaker ? "detected as built-in speakers" : "allowed")"
        }

        if alwaysProtectionEnabled || roamingProtectionEnabled {
            return "Protection idle"
        }

        return "Protection off"
    }

    var menuBarSystemImage: String {
        if isSpeakerAllowanceActive {
            return "speaker.wave.2"
        }

        if alwaysProtectionEnabled || roamingProtectionEnabled {
            return "speaker.slash"
        }

        return "speaker"
    }

    func allowSpeakers(for duration: TimeInterval) {
        speakerAllowanceUntil = Date().addingTimeInterval(duration)
        lastProtectionReason = nil
        lastAudioActionMessage = "Built-in speakers allowed temporarily"
        logger.info("Temporary speaker allowance set for \(duration) seconds")
    }

    func blockSpeakersNow() {
        speakerAllowanceUntil = nil
        guard let currentOutput else {
            lastAudioActionMessage = "No current output device detected"
            logger.error("Manual block requested, but no output device is known")
            return
        }

        guard currentOutput.isBuiltInSpeaker else {
            lastAudioActionMessage = "\(currentOutput.name) is not detected as built-in speakers"
            logger.info("Manual block skipped because current output is not built-in speakers: \(currentOutput.name, privacy: .public)")
            return
        }

        blockSpeakers(currentOutput, reason: .manual)
    }

    func handleRoamingRisk(reason: ProtectionReason) {
        guard reason.isRoamingRisk else {
            logger.error("Ignoring non-roaming protection reason: \(reason.rawValue, privacy: .public)")
            return
        }

        currentOutput = audioOutputController.currentDefaultOutput()

        guard roamingProtectionEnabled else {
            lastAudioActionMessage = "Roaming protection is off"
            logger.info("Roaming Protection skipped because it is disabled. reason=\(reason.rawValue, privacy: .public)")
            return
        }

        guard !isSpeakerAllowanceActive else {
            lastAudioActionMessage = "Speakers allowed during roaming check"
            logger.info("Roaming Protection skipped because speaker allowance is active. reason=\(reason.rawValue, privacy: .public)")
            return
        }

        guard let currentOutput else {
            lastAudioActionMessage = "Roaming check could not detect current output"
            logger.error("Roaming Protection could not detect current output. reason=\(reason.rawValue, privacy: .public)")
            return
        }

        guard currentOutput.isBuiltInSpeaker else {
            lastAudioActionMessage = "Roaming check passed; \(currentOutput.name) allowed"
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
        } else {
            lastAudioActionMessage = "Could not detect current output"
        }
    }

    private func handleDefaultOutputChanged(_ output: AudioOutputDevice?) {
        let previousOutput = currentOutput
        currentOutput = output

        guard let output else {
            lastAudioActionMessage = "Output changed, but no output device was detected"
            logger.error("Default output changed to nil")
            return
        }

        lastAudioActionMessage = "Output changed to \(output.name)"
        logger.info(
            "Default output changed from \(previousOutput?.name ?? "none", privacy: .public) to \(output.name, privacy: .public). builtInSpeaker=\(output.isBuiltInSpeaker)"
        )

        guard shouldBlockAfterOutputChange(from: previousOutput, to: output) else {
            return
        }

        blockSpeakers(output, reason: .outputChanged)
        recheckSpeakerBlockAfterOutputSettles()
    }

    private func handleNetworkEnvironmentChanged(_ change: NetworkEnvironmentChange) {
        logger.info("Network environment trigger: \(String(describing: change.trigger), privacy: .public)")
        handleRoamingRisk(reason: .networkChanged)
    }

    private func handleWake() {
        logger.info("Wake trigger received")
        handleRoamingRisk(reason: .wake)
    }

    private func shouldBlockAfterOutputChange(from previousOutput: AudioOutputDevice?, to output: AudioOutputDevice) -> Bool {
        guard alwaysProtectionEnabled else {
            return false
        }

        guard !isSpeakerAllowanceActive else {
            lastAudioActionMessage = "Speakers allowed after output change"
            logger.info("Always Protection skipped because speaker allowance is active")
            return false
        }

        return output.isBuiltInSpeaker && previousOutput?.isBuiltInSpeaker != true
    }

    private func recheckSpeakerBlockAfterOutputSettles() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard self.alwaysProtectionEnabled, !self.isSpeakerAllowanceActive else {
                return
            }

            let refreshedOutput = self.audioOutputController.currentDefaultOutput()
            self.currentOutput = refreshedOutput

            guard let refreshedOutput, refreshedOutput.isBuiltInSpeaker else {
                return
            }

            self.blockSpeakers(refreshedOutput, reason: .outputChanged)
        }
    }

    private func blockSpeakers(_ output: AudioOutputDevice, reason: ProtectionReason) {
        lastProtectionReason = reason

        if audioOutputController.setMuted(true, for: output) {
            lastAudioActionMessage = "Muted \(output.name)"
            logger.info("Blocked speakers by mute. reason=\(reason.rawValue, privacy: .public), output=\(output.name, privacy: .public)")
            return
        }

        if audioOutputController.setVolume(0, for: output) {
            lastAudioActionMessage = "Set \(output.name) volume to 0"
            logger.info("Blocked speakers by setting volume to 0. reason=\(reason.rawValue, privacy: .public), output=\(output.name, privacy: .public)")
            return
        }

        lastAudioActionMessage = "Could not block \(output.name)"
        logger.error("Failed to block speakers. reason=\(reason.rawValue, privacy: .public), output=\(output.name, privacy: .public)")
    }
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
