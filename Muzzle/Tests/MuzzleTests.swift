import CoreAudio
import CoreLocation
import Foundation
import Network
import Testing
@testable import Muzzle

struct AudioOutputDeviceTests {
    @Test
    func builtInSpeakerMatchesSpeakerTerminal() {
        let device = AudioOutputDevice(
            id: 1,
            name: "MacBook Pro Speakers",
            uid: "built-in-speakers",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            dataSourceID: nil,
            outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker]
        )

        #expect(device.isBuiltInSpeaker)
        #expect(device.builtInSpeakerDetectionReason == "built-in transport with speaker output terminal")
    }

    @Test
    func builtInHeadphonesDoNotMatchSpeakerRule() {
        let device = AudioOutputDevice(
            id: 2,
            name: "MacBook Pro Headphone Jack",
            uid: "built-in-headphones",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            dataSourceID: nil,
            outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones]
        )

        #expect(!device.isBuiltInSpeaker)
        #expect(device.builtInSpeakerDetectionReason == "built-in transport, but output terminal is headphones")
    }

    @Test
    func builtInSpeakerFallsBackToNameWhenTerminalMetadataIsMissing() {
        let device = AudioOutputDevice(
            id: 3,
            name: "Internal Speaker",
            uid: "fallback-device",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            dataSourceID: nil,
            outputTerminalTypes: []
        )

        #expect(device.isBuiltInSpeaker)
        #expect(device.builtInSpeakerDetectionReason == "built-in transport with speaker text fallback")
    }

    @Test
    func externalAudioDeviceIsNotTreatedAsBuiltInSpeaker() {
        let device = AudioOutputDevice(
            id: 4,
            name: "USB DAC",
            uid: "usb-dac",
            transportType: kAudioDeviceTransportTypeUSB,
            dataSourceID: nil,
            outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker]
        )

        #expect(!device.isBuiltInSpeaker)
        #expect(device.builtInSpeakerDetectionReason.contains("not built-in"))
    }
}

struct NetworkEnvironmentModelTests {
    @Test
    func wifiIdentityFlagsAssociationAndReadableIdentity() {
        let identity = WiFiIdentity(
            interfaceName: "en0",
            ssid: "Office Wi-Fi",
            bssid: nil,
            isPowerOn: true
        )

        #expect(identity.isAssociated)
        #expect(identity.hasReadableIdentity)
    }

    @Test
    func wifiIdentityWithoutSsidOrBssidIsUnreadable() {
        let identity = WiFiIdentity(
            interfaceName: "en0",
            ssid: nil,
            bssid: nil,
            isPowerOn: true
        )

        #expect(!identity.isAssociated)
        #expect(!identity.hasReadableIdentity)
    }

    @Test
    func snapshotReportsReadableWifiIdentity() {
        let snapshot = NetworkEnvironmentSnapshot(
            wifiIdentity: WiFiIdentity(interfaceName: "en0", ssid: nil, bssid: "00:11:22:33:44:55", isPowerOn: true),
            materialPath: NetworkPathMaterial(
                status: .satisfied,
                usesWiFi: true,
                usesWiredEthernet: false,
                usesLoopback: false,
                isExpensive: false,
                isConstrained: false
            )
        )

        #expect(snapshot.hasReadableWiFiIdentity)
    }

    @Test
    func debugStateBuildsHumanReadableSummaries() {
        let snapshot = NetworkEnvironmentSnapshot(
            wifiIdentity: WiFiIdentity(
                interfaceName: "en0",
                ssid: "CoffeeShop",
                bssid: "00:11:22:33:44:55",
                isPowerOn: true
            ),
            materialPath: NetworkPathMaterial(
                status: .satisfied,
                usesWiFi: true,
                usesWiredEthernet: true,
                usesLoopback: false,
                isExpensive: true,
                isConstrained: true
            )
        )
        let state = NetworkEnvironmentDebugState(
            snapshot: snapshot,
            lastTrigger: .ssidChanged(previous: "Home", current: "CoffeeShop"),
            locationAuthorizationStatus: .authorizedAlways,
            recentEvents: []
        )

        #expect(state.wifiSummary == "Wi-Fi: en0, on, associated")
        #expect(state.wifiIdentitySummary == "SSID: CoffeeShop, BSSID: 00:11:22:33:44:55")
        #expect(state.pathSummary == "Path: satisfied, Wi-Fi, Ethernet, expensive, constrained")
        #expect(state.triggerSummary == "Network trigger: SSID changed Home -> CoffeeShop")
        #expect(state.locationAuthorizationSummary == "Location: authorized always")
    }

    @Test
    func debugStateUsesFallbackTextWhenInformationIsMissing() {
        let state = NetworkEnvironmentDebugState(
            snapshot: nil,
            lastTrigger: nil,
            locationAuthorizationStatus: .notDetermined,
            recentEvents: []
        )

        #expect(state.wifiSummary == "Wi-Fi: no interface")
        #expect(state.wifiIdentitySummary == "Wi-Fi identity: unavailable")
        #expect(state.pathSummary == "Network path: unknown")
        #expect(state.triggerSummary == "Network trigger: none")
    }
}

struct ProtectionReasonTests {
    @Test
    func roamingRiskReasonsAreLimitedToWakeAndNetworkChange() {
        #expect(ProtectionReason.wake.isRoamingRisk)
        #expect(ProtectionReason.networkChanged.isRoamingRisk)
        #expect(!ProtectionReason.outputChanged.isRoamingRisk)
        #expect(!ProtectionReason.manual.isRoamingRisk)
    }

    @Test
    func displayNamesMatchUserFacingStatus() {
        #expect(ProtectionReason.outputChanged.displayName == "headphones disconnected")
        #expect(ProtectionReason.wake.displayName == "Mac woke up")
        #expect(ProtectionReason.networkChanged.displayName == "Wi-Fi changed")
        #expect(ProtectionReason.manual.displayName == "manual action")
    }
}

struct ProtectionNotificationTests {
    @Test
    func notificationCopyMatchesProtectionReasons() {
        #expect(
            ProtectionNotificationController.notificationBody(
                reason: .outputChanged
            ) == "Built-in speakers were muted because your headphones disconnected."
        )
        #expect(
            ProtectionNotificationController.notificationBody(
                reason: .networkChanged
            ) == "Built-in speakers were muted because your location appears to have changed."
        )
        #expect(
            ProtectionNotificationController.notificationBody(
                reason: .wake
            ) == "Built-in speakers were muted after your Mac woke up."
        )
        #expect(
            ProtectionNotificationController.notificationBody(
                reason: .manual
            ) == "Built-in speakers were muted because protection resumed."
        )
    }
}

@MainActor
struct SpeakerLockStateTests {
    @Test
    func pauseProtectionClearsAtExpiry() async throws {
        let fixture = try makeDefaults()
        defer { fixture.tearDown() }
        let defaults = fixture.defaults
        let state = SpeakerLockState(defaults: defaults, startObservers: false)

        state.pauseProtection(for: 0.05)

        #expect(state.isProtectionPauseActive)

        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(state.protectionPauseUntil == nil)
        #expect(!state.isProtectionPauseActive)
    }

    @Test
    func startupSchedulesExistingFuturePauseExpiry() async throws {
        let fixture = try makeDefaults()
        defer { fixture.tearDown() }
        let defaults = fixture.defaults
        let pauseUntil = Date().addingTimeInterval(0.05)
        defaults.set(pauseUntil, forKey: "protectionPauseUntil")

        let state = SpeakerLockState(defaults: defaults, startObservers: false)

        #expect(state.protectionPauseUntil == pauseUntil)
        #expect(state.isProtectionPauseActive)

        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(state.protectionPauseUntil == nil)
        #expect(!state.isProtectionPauseActive)
    }

    @Test
    func replacingPauseCancelsEarlierExpiry() async throws {
        let fixture = try makeDefaults()
        defer { fixture.tearDown() }
        let defaults = fixture.defaults
        let state = SpeakerLockState(defaults: defaults, startObservers: false)

        state.pauseProtection(for: 0.05)
        state.pauseProtection(for: 60)

        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(state.protectionPauseUntil != nil)
        #expect(state.isProtectionPauseActive)
    }

    @Test
    func startAtLoginDefaultsOnAndRegistersLoginItem() throws {
        let fixture = try makeDefaults()
        defer { fixture.tearDown() }
        let loginItemController = FakeLoginItemController(isEnabled: false)

        let state = SpeakerLockState(
            defaults: fixture.defaults,
            startObservers: false,
            loginItemController: loginItemController,
            applyLoginItemPreference: true
        )

        #expect(state.startAtLoginEnabled)
        #expect(loginItemController.isEnabled)
        #expect(loginItemController.setRequests == [true])
    }

    @Test
    func startAtLoginTogglePersistsAndUnregistersLoginItem() throws {
        let fixture = try makeDefaults()
        defer { fixture.tearDown() }
        fixture.defaults.set(true, forKey: "startAtLoginEnabled")
        let loginItemController = FakeLoginItemController(isEnabled: true)
        let state = SpeakerLockState(
            defaults: fixture.defaults,
            startObservers: false,
            loginItemController: loginItemController,
            applyLoginItemPreference: true
        )

        state.startAtLoginEnabled = false

        #expect(!fixture.defaults.bool(forKey: "startAtLoginEnabled"))
        #expect(!loginItemController.isEnabled)
        #expect(loginItemController.setRequests == [false])
    }

    private func makeDefaults() throws -> DefaultsFixture {
        let suiteName = "MuzzleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "alwaysProtectionEnabled")
        defaults.set(false, forKey: "roamingProtectionEnabled")
        return DefaultsFixture(defaults: defaults, suiteName: suiteName)
    }

    private struct DefaultsFixture {
        let defaults: UserDefaults
        let suiteName: String

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private final class FakeLoginItemController: LoginItemControlling {
        var isEnabled: Bool
        var setRequests: [Bool] = []

        init(isEnabled: Bool) {
            self.isEnabled = isEnabled
        }

        func setEnabled(_ isEnabled: Bool) throws {
            setRequests.append(isEnabled)
            self.isEnabled = isEnabled
        }
    }
}

struct AuthorizationStatusTests {
    @Test
    func authorizationStatusDebugNamesAreStable() {
        #expect(CLAuthorizationStatus.notDetermined.debugDisplayName == "not determined")
        #expect(CLAuthorizationStatus.restricted.debugDisplayName == "restricted")
        #expect(CLAuthorizationStatus.denied.debugDisplayName == "denied")
        #expect(CLAuthorizationStatus.authorizedAlways.debugDisplayName == "authorized always")
    }
}
