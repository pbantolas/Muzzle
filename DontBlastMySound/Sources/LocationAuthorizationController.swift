import CoreLocation
import Foundation
import OSLog

final class LocationAuthorizationController: NSObject, CLLocationManagerDelegate {
    private let logger = Logger(subsystem: "DontBlastMySound", category: "LocationAuthorization")
    private let manager = CLLocationManager()

    var onAuthorizationChanged: (@MainActor (CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func requestAuthorizationIfNeeded() {
        guard manager.authorizationStatus == .notDetermined else {
            return
        }

        logger.info("Requesting Location authorization for Wi-Fi SSID access")
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        logger.info("Location authorization changed: \(status.debugDisplayName, privacy: .public)")

        Task { @MainActor in
            onAuthorizationChanged?(status)
        }
    }
}

extension CLAuthorizationStatus {
    var debugDisplayName: String {
        switch self {
        case .notDetermined:
            "not determined"
        case .restricted:
            "restricted"
        case .denied:
            "denied"
        case .authorizedAlways:
            "authorized always"
        case .authorizedWhenInUse:
            "authorized when in use"
        @unknown default:
            "unknown"
        }
    }
}
