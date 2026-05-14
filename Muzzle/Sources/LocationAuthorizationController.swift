import CoreLocation
import Foundation

final class LocationAuthorizationController: NSObject, CLLocationManagerDelegate {
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
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

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
