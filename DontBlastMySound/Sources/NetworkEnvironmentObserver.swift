import CoreWLAN
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
}

final class NetworkEnvironmentObserver {
    private let logger = Logger(subsystem: "DontBlastMySound", category: "NetworkEnvironment")
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "DontBlastMySound.NetworkEnvironmentObserver")
    private let wifiClient = CWWiFiClient.shared()

    private var lastSnapshot: NetworkEnvironmentSnapshot?
    private var pendingDebounceTask: Task<Void, Never>?
    private var isObserving = false

    var onNetworkEnvironmentChanged: (@MainActor (NetworkEnvironmentChange) -> Void)?

    deinit {
        stopObserving()
    }

    func startObserving() {
        guard !isObserving else {
            return
        }

        monitor.pathUpdateHandler = { [weak self] path in
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
            logger.info("Captured initial network environment snapshot")
            return
        }

        lastSnapshot = currentSnapshot

        guard let trigger = trigger(from: previousSnapshot, to: currentSnapshot) else {
            logger.info("Network path changed without a roaming trigger")
            return
        }

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
}
