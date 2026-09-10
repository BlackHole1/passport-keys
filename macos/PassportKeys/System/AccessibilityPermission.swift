import AppKit
import ApplicationServices
import Observation

/// 辅助功能授权状态。合成键盘事件必须获得该授权。
@Observable
final class AccessibilityPermission {
    private(set) var isTrusted = AXIsProcessTrusted()

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// 未授权时弹出系统提示。键名即 kAXTrustedCheckOptionPrompt,用字面量避免引用非并发安全的全局变量。
    func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        startMonitoring()
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startMonitoring()
    }

    /// 系统不会广播授权变化,只能轮询;拿到授权后停止。
    func startMonitoring() {
        guard pollTask == nil, !isTrusted else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.refresh() {
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    @discardableResult
    func refresh() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        return trusted
    }
}
