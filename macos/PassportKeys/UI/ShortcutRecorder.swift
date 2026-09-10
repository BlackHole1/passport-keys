import Carbon.HIToolbox
import SwiftUI

/// 点击后监听本 app 收到的键盘事件,把下一次按键(含修饰键)录成 KeyCombo。
/// 录制期间吞掉事件,⌘Q、⌘W 之类不会误触发菜单命令。
struct ShortcutRecorder: View {
    let combo: KeyCombo?
    @Binding var isRecording: Bool
    let onRecord: (KeyCombo) -> Void

    @State private var liveModifiers: KeyCombo.Modifiers = []
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(title)
                .foregroundStyle(isRecording ? Color.accentColor : (combo == nil ? Color.secondary : Color.primary))
                .frame(minWidth: 150)
        }
        .onChange(of: isRecording, initial: true) { _, recording in
            if recording {
                installMonitor()
            } else {
                removeMonitor()
            }
        }
        .onDisappear {
            removeMonitor()
        }
    }

    private var title: String {
        if isRecording {
            return liveModifiers.isEmpty ? "请按下快捷键…" : liveModifiers.symbols + " …"
        }
        return combo?.displayString ?? "未设置"
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        liveModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        liveModifiers = []
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            liveModifiers = KeyCombo.Modifiers(event.modifierFlags)
            return nil
        case .keyDown:
            let modifiers = KeyCombo.Modifiers(event.modifierFlags)
            if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
                isRecording = false
                return nil
            }
            onRecord(KeyCombo(keyCode: event.keyCode, modifiers: modifiers))
            isRecording = false
            return nil
        default:
            return event
        }
    }
}

/// 常用按键菜单,用于设置录制不到的系统保留组合。
struct PresetMenu: View {
    let onSelect: (KeyCombo) -> Void

    var body: some View {
        Menu {
            ForEach(KeyCombo.presetGroups) { group in
                Section(group.title) {
                    ForEach(group.presets) { preset in
                        Button("\(preset.title)  \(preset.combo.displayString)") {
                            onSelect(preset.combo)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("常用按键")
    }
}
