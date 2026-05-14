import Foundation
import Observation

@Observable
final class SpeakerLockState {
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

    init() {
        alwaysProtectionEnabled = UserDefaults.standard.object(forKey: DefaultsKey.alwaysProtectionEnabled) as? Bool ?? true
        roamingProtectionEnabled = UserDefaults.standard.object(forKey: DefaultsKey.roamingProtectionEnabled) as? Bool ?? true
        speakerAllowanceUntil = UserDefaults.standard.object(forKey: DefaultsKey.speakerAllowanceUntil) as? Date

        if let rawReason = UserDefaults.standard.string(forKey: DefaultsKey.lastProtectionReason) {
            lastProtectionReason = ProtectionReason(rawValue: rawReason)
        }
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
    }

    func blockSpeakersNow() {
        speakerAllowanceUntil = nil
        lastProtectionReason = .manual
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
}

private enum DefaultsKey {
    static let alwaysProtectionEnabled = "alwaysProtectionEnabled"
    static let roamingProtectionEnabled = "roamingProtectionEnabled"
    static let speakerAllowanceUntil = "speakerAllowanceUntil"
    static let lastProtectionReason = "lastProtectionReason"
}
