import CoreWLAN
import CoreLocation
import Foundation
import Network
import OSLog

struct WiFiIdentity: Equatable {
    let interfaceName: String?
    let ssid: String?
    let bssid: String?
    let isPowerOn: Bool

    var isAssociated: Bool {
        ssid != nil
    }

    var hasReadableIdentity: Bool {
        ssid != nil || bssid != nil
    }
}

struct NetworkEnvironmentDebugState: Equatable {
    let snapshot: NetworkEnvironmentSnapshot?
    let lastTrigger: NetworkEnvironmentTrigger?
    let locationAuthorizationStatus: CLAuthorizationStatus

    var wifiSummary: String {
        guard let wifiIdentity = snapshot?.wifiIdentity else {
            return "Wi-Fi: no interface"
        }

        let interfaceName = wifiIdentity.interfaceName ?? "unknown interface"
        let powerText = wifiIdentity.isPowerOn ? "on" : "off"
        let associationText = wifiIdentity.isAssociated ? "associated" : "not associated"

        return "Wi-Fi: \(interfaceName), \(powerText), \(associationText)"
    }

    var wifiIdentitySummary: String {
        guard let wifiIdentity = snapshot?.wifiIdentity else {
            return "Wi-Fi identity: unavailable"
        }

        let ssid = wifiIdentity.ssid ?? "unreadable"
        let bssid = wifiIdentity.bssid ?? "unreadable"

        return "SSID: \(ssid), BSSID: \(bssid)"
    }

    var pathSummary: String {
        guard let materialPath = snapshot?.materialPath else {
            return "Network path: unknown"
        }

        var interfaces: [String] = []
        if materialPath.usesWiFi {
            interfaces.append("Wi-Fi")
        }
        if materialPath.usesWiredEthernet {
            interfaces.append("Ethernet")
        }
        if materialPath.usesLoopback {
            interfaces.append("Loopback")
        }

        let interfaceText = interfaces.isEmpty ? "no tracked interface" : interfaces.joined(separator: ", ")
        var flags: [String] = []
        if materialPath.isExpensive {
            flags.append("expensive")
        }
        if materialPath.isConstrained {
            flags.append("constrained")
        }

        let flagText = flags.isEmpty ? "" : ", \(flags.joined(separator: ", "))"
        return "Path: \(materialPath.status.debugDisplayName), \(interfaceText)\(flagText)"
    }

    var triggerSummary: String {
        guard let lastTrigger else {
            return "Network trigger: none"
        }

        return "Network trigger: \(lastTrigger.debugDisplayName)"
    }

    var locationAuthorizationSummary: String {
        "Location: \(locationAuthorizationStatus.debugDisplayName)"
    }
}

struct NetworkEnvironmentChange: Equatable {
    let previous: NetworkEnvironmentSnapshot
    let current: NetworkEnvironmentSnapshot
    let trigger: NetworkEnvironmentTrigger
}

struct NetworkEnvironmentSnapshot: Equatable {
    let wifiIdentity: WiFiIdentity?
    let materialPath: NetworkPathMaterial

    var hasReadableWiFiIdentity: Bool {
        wifiIdentity?.hasReadableIdentity == true
    }
}

struct NetworkPathMaterial: Equatable {
    let status: NWPath.Status
    let usesWiFi: Bool
    let usesWiredEthernet: Bool
    let usesLoopback: Bool
    let isExpensive: Bool
    let isConstrained: Bool
}

enum NetworkEnvironmentTrigger: Equatable {
    case ssidChanged(previous: String?, current: String?)
    case wifiAssociationChanged(previous: Bool, current: Bool)
    case materialPathChanged

    var debugDisplayName: String {
        switch self {
        case let .ssidChanged(previous, current):
            "SSID changed \(previous ?? "none") -> \(current ?? "none")"
        case let .wifiAssociationChanged(previous, current):
            "Wi-Fi association \(previous ? "on" : "off") -> \(current ? "on" : "off")"
        case .materialPathChanged:
            "material path changed"
        }
    }
}

final class NetworkEnvironmentObserver {
    private let logger = Logger(subsystem: "DontBlastMySound", category: "NetworkEnvironment")
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "DontBlastMySound.NetworkEnvironmentObserver")
    private let wifiClient = CWWiFiClient.shared()
    private let locationAuthorizationController = LocationAuthorizationController()

    private var lastSnapshot: NetworkEnvironmentSnapshot?
    private var lastTrigger: NetworkEnvironmentTrigger?
    private var latestPath: NWPath?
    private var pendingDebounceTask: Task<Void, Never>?
    private var isObserving = false

    var onNetworkEnvironmentChanged: (@MainActor (NetworkEnvironmentChange) -> Void)?
    var onDebugStateChanged: (@MainActor (NetworkEnvironmentDebugState) -> Void)?

    deinit {
        stopObserving()
    }

    func startObserving() {
        guard !isObserving else {
            return
        }

        locationAuthorizationController.onAuthorizationChanged = { [weak self] _ in
            self?.refreshCurrentSnapshotForDebug()
        }
        locationAuthorizationController.requestAuthorizationIfNeeded()

        monitor.pathUpdateHandler = { [weak self] path in
            self?.latestPath = path
            self?.scheduleEnvironmentCheck(for: path)
        }
        monitor.start(queue: queue)
        isObserving = true
        logger.info("Started observing network path changes")
    }

    func stopObserving() {
        guard isObserving else {
            return
        }

        pendingDebounceTask?.cancel()
        pendingDebounceTask = nil
        monitor.cancel()
        isObserving = false
        logger.info("Stopped observing network path changes")
    }

    private func scheduleEnvironmentCheck(for path: NWPath) {
        pendingDebounceTask?.cancel()
        pendingDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))

            guard !Task.isCancelled else {
                return
            }

            self?.handleEnvironmentCheck(for: path)
        }
    }

    private func handleEnvironmentCheck(for path: NWPath) {
        let currentSnapshot = snapshot(for: path)

        guard let previousSnapshot = lastSnapshot else {
            lastSnapshot = currentSnapshot
            notifyDebugStateChanged()
            logger.info("Captured initial network environment snapshot")
            return
        }

        lastSnapshot = currentSnapshot
        notifyDebugStateChanged()

        guard let trigger = trigger(from: previousSnapshot, to: currentSnapshot) else {
            logger.info("Network path changed without a roaming trigger")
            return
        }

        lastTrigger = trigger
        notifyDebugStateChanged()
        logger.info("Network environment changed. trigger=\(String(describing: trigger), privacy: .public)")

        let change = NetworkEnvironmentChange(
            previous: previousSnapshot,
            current: currentSnapshot,
            trigger: trigger
        )

        Task { @MainActor in
            onNetworkEnvironmentChanged?(change)
        }
    }

    private func refreshCurrentSnapshotForDebug() {
        guard let latestPath else {
            notifyDebugStateChanged()
            return
        }

        lastSnapshot = snapshot(for: latestPath)
        notifyDebugStateChanged()
    }

    private func snapshot(for path: NWPath) -> NetworkEnvironmentSnapshot {
        NetworkEnvironmentSnapshot(
            wifiIdentity: currentWiFiIdentity(),
            materialPath: NetworkPathMaterial(
                status: path.status,
                usesWiFi: path.usesInterfaceType(.wifi),
                usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
                usesLoopback: path.usesInterfaceType(.loopback),
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
        )
    }

    private func currentWiFiIdentity() -> WiFiIdentity? {
        guard let interface = wifiClient.interface() else {
            return nil
        }

        return WiFiIdentity(
            interfaceName: interface.interfaceName,
            ssid: interface.ssid(),
            bssid: interface.bssid(),
            isPowerOn: interface.powerOn()
        )
    }

    private func trigger(
        from previous: NetworkEnvironmentSnapshot,
        to current: NetworkEnvironmentSnapshot
    ) -> NetworkEnvironmentTrigger? {
        if let previousWiFi = previous.wifiIdentity, let currentWiFi = current.wifiIdentity {
            if previousWiFi.ssid != currentWiFi.ssid {
                return .ssidChanged(previous: previousWiFi.ssid, current: currentWiFi.ssid)
            }

            if previousWiFi.isAssociated != currentWiFi.isAssociated {
                return .wifiAssociationChanged(
                    previous: previousWiFi.isAssociated,
                    current: currentWiFi.isAssociated
                )
            }

            if previousWiFi.hasReadableIdentity || currentWiFi.hasReadableIdentity {
                return nil
            }
        }

        if previous.hasReadableWiFiIdentity || current.hasReadableWiFiIdentity {
            return .wifiAssociationChanged(
                previous: previous.wifiIdentity?.isAssociated == true,
                current: current.wifiIdentity?.isAssociated == true
            )
        }

        guard previous.materialPath != current.materialPath else {
            return nil
        }

        return .materialPathChanged
    }

    private func notifyDebugStateChanged() {
        let debugState = NetworkEnvironmentDebugState(
            snapshot: lastSnapshot,
            lastTrigger: lastTrigger,
            locationAuthorizationStatus: locationAuthorizationController.authorizationStatus
        )

        Task { @MainActor in
            onDebugStateChanged?(debugState)
        }
    }
}

private extension NWPath.Status {
    var debugDisplayName: String {
        switch self {
        case .satisfied:
            "satisfied"
        case .unsatisfied:
            "unsatisfied"
        case .requiresConnection:
            "requires connection"
        @unknown default:
            "unknown"
        }
    }
}
