import Foundation

/// 把字节流按 `\n` 切成行。串口读取和 BLE 通知都可能把一行拆成多段。
nonisolated struct LineBuffer: Sendable {
    private let maxLineBytes: Int
    private var buffer: [UInt8] = []
    /// 当前行已超长,丢弃到下一个换行为止。
    private var discarding = false

    init(maxLineBytes: Int = 1024) {
        self.maxLineBytes = maxLineBytes
    }

    mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                if !discarding {
                    if buffer.last == 0x0D {
                        buffer.removeLast()
                    }
                    if !buffer.isEmpty {
                        lines.append(String(decoding: buffer, as: UTF8.self))
                    }
                }
                buffer.removeAll(keepingCapacity: true)
                discarding = false
            } else if discarding {
                continue
            } else if buffer.count >= maxLineBytes {
                buffer.removeAll(keepingCapacity: true)
                discarding = true
            } else {
                buffer.append(byte)
            }
        }
        return lines
    }

    mutating func reset() {
        buffer.removeAll()
        discarding = false
    }
}
