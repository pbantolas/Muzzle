import Foundation
import ServiceManagement

@MainActor
protocol LoginItemControlling {
    var isEnabled: Bool { get }

    func setEnabled(_ isEnabled: Bool) throws
}

@MainActor
struct LoginItemController: LoginItemControlling {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
