import Observation
import ServiceManagement

/// 登录时自动启动。
@Observable
final class LoginItemController {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var lastError: String?

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
