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
    let recentEvents: [String]

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

final class NetworkEnvironmentObserver: NSObject, CWEventDelegate {
    private let logger = Logger(subsystem: "Muzzle", category: "NetworkEnvironment")
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "Muzzle.NetworkEnvironmentObserver")
    private let wifiClient = CWWiFiClient.shared()
    private let locationAuthorizationController = LocationAuthorizationController()
    private static let queueKey = DispatchSpecificKey<Void>()
    private let monitoredWiFiEvents: [CWEventType] = [
        .ssidDidChange,
        .bssidDidChange,
        .linkDidChange,
        .powerDidChange,
    ]

    private var lastSnapshot: NetworkEnvironmentSnapshot?
    private var lastTrigger: NetworkEnvironmentTrigger?
    private var latestPath: NWPath?
    private var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    private var recentEvents: [String] = []
    private var pendingDebounceWorkItem: DispatchWorkItem?
    private var debounceGeneration = 0
    private var registeredWiFiEvents: [CWEventType] = []
    private var isObserving = false

    @MainActor var onNetworkEnvironmentChanged: (@MainActor (NetworkEnvironmentChange) -> Void)?
    @MainActor var onDebugStateChanged: (@MainActor (NetworkEnvironmentDebugState) -> Void)?

    override init() {
        super.init()
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        stopObserving()
    }

    func startObserving() {
        let initialAuthorizationStatus = locationAuthorizationController.authorizationStatus
        locationAuthorizationController.onAuthorizationChanged = { [weak self] status in
            self?.queue.async {
                self?.handleLocationAuthorizationChanged(status)
            }
        }
        locationAuthorizationController.requestAuthorizationIfNeeded()

        runOnQueue {
            self.startObservingOnQueue(initialAuthorizationStatus: initialAuthorizationStatus)
        }
    }

    func stopObserving() {
        locationAuthorizationController.onAuthorizationChanged = nil

        runOnQueueSynchronously {
            self.stopObservingOnQueue()
        }
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        enqueueWiFiIdentityCheck(event: "SSID changed", interfaceName: interfaceName)
    }

    func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        enqueueWiFiIdentityCheck(event: "BSSID changed", interfaceName: interfaceName)
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        enqueueWiFiIdentityCheck(event: "link changed", interfaceName: interfaceName)
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        enqueueWiFiIdentityCheck(event: "power changed", interfaceName: interfaceName)
    }

    func clientConnectionInterrupted() {
        queue.async {
            guard self.isObserving else {
                return
            }

            self.appendDiagnosticEvent("CoreWLAN connection interrupted")
            self.scheduleEnvironmentCheck(reason: "CoreWLAN connection interrupted")
        }
    }

    func clientConnectionInvalidated() {
        queue.async {
            guard self.isObserving else {
                return
            }

            self.appendDiagnosticEvent("CoreWLAN connection invalidated")
            self.scheduleEnvironmentCheck(reason: "CoreWLAN connection invalidated")
        }
    }

    private func startObservingOnQueue(initialAuthorizationStatus: CLAuthorizationStatus) {
        guard !isObserving else {
            return
        }

        locationAuthorizationStatus = initialAuthorizationStatus

        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: queue)
        startMonitoringWiFiEvents()
        isObserving = true
        appendDiagnosticEvent("started observing network path and Wi-Fi identity changes")
    }

    private func stopObservingOnQueue() {
        guard isObserving else {
            return
        }

        pendingDebounceWorkItem?.cancel()
        pendingDebounceWorkItem = nil
        debounceGeneration += 1
        stopMonitoringWiFiEvents()
        monitor.cancel()
        monitor.pathUpdateHandler = nil
        isObserving = false
        appendDiagnosticEvent("stopped observing network path and Wi-Fi identity changes")
    }

    private func handlePathUpdate(_ path: NWPath) {
        guard isObserving else {
            return
        }

        latestPath = path
        appendDiagnosticEvent("path update: \(NetworkPathMaterial(path: path).debugSummary)")
        scheduleEnvironmentCheck(reason: "path update")
    }

    private func handleLocationAuthorizationChanged(_ status: CLAuthorizationStatus) {
        guard isObserving else {
            return
        }

        locationAuthorizationStatus = status
        appendDiagnosticEvent("location authorization changed")
        refreshCurrentSnapshotForDebug()
    }

    private func enqueueWiFiIdentityCheck(event: String, interfaceName: String) {
        queue.async {
            guard self.isObserving else {
                return
            }

            self.appendDiagnosticEvent("CoreWLAN \(event) on \(interfaceName)")
            self.scheduleEnvironmentCheck(reason: "CoreWLAN \(event)")
        }
    }

    private func scheduleEnvironmentCheck(reason: String) {
        pendingDebounceWorkItem?.cancel()
        debounceGeneration += 1
        let generation = debounceGeneration

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isObserving, self.debounceGeneration == generation else {
                return
            }

            self.pendingDebounceWorkItem = nil
            self.handleEnvironmentCheck(reason: reason)
        }

        pendingDebounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .seconds(1), execute: workItem)
    }

    private func handleEnvironmentCheck(reason: String) {
        let path = latestPath ?? monitor.currentPath
        let currentSnapshot = snapshot(for: path)

        guard let previousSnapshot = lastSnapshot else {
            lastSnapshot = currentSnapshot
            appendDiagnosticEvent("captured initial snapshot after \(reason): \(currentSnapshot.debugSummary)")
            notifyDebugStateChanged()
            return
        }

        lastSnapshot = currentSnapshot
        appendDiagnosticEvent("checked snapshot after \(reason): \(currentSnapshot.debugSummary)")
        notifyDebugStateChanged()

        guard let trigger = trigger(from: previousSnapshot, to: currentSnapshot) else {
            appendDiagnosticEvent("no network environment trigger")
            return
        }

        lastTrigger = trigger
        appendDiagnosticEvent("network environment trigger: \(trigger.debugDisplayName)")
        notifyDebugStateChanged()

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
        let path = latestPath ?? monitor.currentPath
        lastSnapshot = snapshot(for: path)
        notifyDebugStateChanged()
    }

    private func snapshot(for path: NWPath) -> NetworkEnvironmentSnapshot {
        NetworkEnvironmentSnapshot(
            wifiIdentity: currentWiFiIdentity(),
            materialPath: NetworkPathMaterial(path: path)
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

    private func appendDiagnosticEvent(_ message: String) {
        recentEvents.append("\(Self.timestamp()): \(message)")
        if recentEvents.count > 40 {
            recentEvents.removeFirst(recentEvents.count - 40)
        }
    }

    private func notifyDebugStateChanged() {
        let debugState = NetworkEnvironmentDebugState(
            snapshot: lastSnapshot,
            lastTrigger: lastTrigger,
            locationAuthorizationStatus: locationAuthorizationStatus,
            recentEvents: recentEvents
        )

        Task { @MainActor in
            onDebugStateChanged?(debugState)
        }
    }

    private func startMonitoringWiFiEvents() {
        wifiClient.delegate = self

        for event in monitoredWiFiEvents {
            do {
                try wifiClient.startMonitoringEvent(with: event)
                registeredWiFiEvents.append(event)
                appendDiagnosticEvent("started CoreWLAN \(event.debugDisplayName) monitoring")
            } catch {
                appendDiagnosticEvent("failed CoreWLAN \(event.debugDisplayName) monitoring: \(error.localizedDescription)")
                logger.error(
                    "Failed to start CoreWLAN \(event.debugDisplayName, privacy: .public) monitoring: \(error.localizedDescription)"
                )
            }
        }
    }

    private func stopMonitoringWiFiEvents() {
        for event in registeredWiFiEvents {
            do {
                try wifiClient.stopMonitoringEvent(with: event)
            } catch {
                logger.error(
                    "Failed to stop CoreWLAN \(event.debugDisplayName, privacy: .public) monitoring: \(error.localizedDescription)"
                )
            }
        }

        registeredWiFiEvents.removeAll()

        if wifiClient.delegate === self {
            wifiClient.delegate = nil
        }
    }

    private func runOnQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    private func runOnQueueSynchronously(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private static func timestamp() -> String {
        diagnosticsTimeFormatter.string(from: Date())
    }

    private static let diagnosticsTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

extension NetworkPathMaterial {
    init(path: NWPath) {
        self.init(
            status: path.status,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
            usesLoopback: path.usesInterfaceType(.loopback),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    var debugSummary: String {
        var interfaces: [String] = []
        if usesWiFi {
            interfaces.append("wifi")
        }
        if usesWiredEthernet {
            interfaces.append("ethernet")
        }
        if usesLoopback {
            interfaces.append("loopback")
        }

        var flags: [String] = []
        if isExpensive {
            flags.append("expensive")
        }
        if isConstrained {
            flags.append("constrained")
        }

        let interfaceText = interfaces.isEmpty ? "none" : interfaces.joined(separator: ",")
        let flagText = flags.isEmpty ? "none" : flags.joined(separator: ",")
        return "status=\(status.debugDisplayName), interfaces=\(interfaceText), flags=\(flagText)"
    }
}

extension NetworkEnvironmentSnapshot {
    var debugSummary: String {
        let wifiText: String
        if let wifiIdentity {
            wifiText = "interface=\(wifiIdentity.interfaceName ?? "unknown"), power=\(wifiIdentity.isPowerOn), associated=\(wifiIdentity.isAssociated), ssid=\(wifiIdentity.ssid ?? "nil"), bssid=\(wifiIdentity.bssid ?? "nil")"
        } else {
            wifiText = "no wifi interface"
        }

        return "\(wifiText); \(materialPath.debugSummary)"
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

private extension CWEventType {
    var debugDisplayName: String {
        switch self {
        case .powerDidChange:
            "power"
        case .ssidDidChange:
            "SSID"
        case .bssidDidChange:
            "BSSID"
        case .linkDidChange:
            "link"
        default:
            "event \(rawValue)"
        }
    }
}
