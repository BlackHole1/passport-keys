import Darwin
import Foundation

/// /dev/cu.* 串口的最小封装:原始模式、非阻塞读、串行队列写。
/// fd 只在内部串行队列上读写;回调也在该队列上触发,由调用方切回主线程。
nonisolated final class SerialPort: @unchecked Sendable {
    enum Failure: LocalizedError {
        case open(path: String, code: Int32)
        case configure(code: Int32)

        var errorDescription: String? {
            switch self {
            case .open(let path, let code) where code == EBUSY:
                "\(path) 正被其它程序占用(例如 idf.py monitor)"
            case .open(let path, let code):
                "无法打开 \(path):\(String(cString: strerror(code)))"
            case .configure(let code):
                "串口配置失败:\(String(cString: strerror(code)))"
            }
        }
    }

    let path: String

    private let fd: Int32
    private let queue = DispatchQueue(label: "PassportKeys.SerialPort")
    private let onData: @Sendable (Data) -> Void
    private let onClose: @Sendable (Int32?) -> Void
    private var readSource: DispatchSourceRead?
    private var isClosed = false

    /// - Parameters:
    ///   - onData: 收到数据,在内部队列上调用。
    ///   - onClose: 端口关闭,参数为导致关闭的 errno;主动 `close()` 时为 nil。
    init(
        path: String,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (Int32?) -> Void
    ) throws {
        self.path = path
        self.onData = onData
        self.onClose = onClose

        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw Failure.open(path: path, code: errno)
        }
        do {
            try Self.configure(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        self.fd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        readSource = source
        source.resume()
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard !isClosed else { return }
            let bytes = [UInt8](data)
            var offset = 0
            var retries = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBufferPointer { buffer in
                    Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                }
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                // 设备端接收缓冲写满时返回 EAGAIN,稍等即可;持续失败说明设备已不再读取。
                if code == EAGAIN || code == EINTR, retries < 100 {
                    retries += 1
                    usleep(2_000)
                    continue
                }
                finish(code)
                return
            }
        }
    }

    func close() {
        queue.async { [self] in
            finish(nil)
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !isClosed {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                onData(Data(buffer[0..<count]))
                if count < buffer.count {
                    return
                }
            } else if count == 0 {
                // 非阻塞 tty 读到 0 表示对端挂断:设备被拔出或复位后重新枚举。
                finish(ENXIO)
                return
            } else {
                let code = errno
                if code != EAGAIN, code != EINTR {
                    finish(code)
                }
                return
            }
        }
    }

    private func finish(_ code: Int32?) {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        onClose(code)
    }

    private static func configure(_ fd: Int32) throws {
        // 独占打开,避免 idf.py monitor 等程序同时读取,把协议帧抢走。
        guard ioctl(fd, IOCTL.exclusive) != -1 else {
            throw Failure.configure(code: errno)
        }

        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            throw Failure.configure(code: errno)
        }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        // 关闭 HUPCL:否则 close 时系统会拉低 DTR/RTS,顺序不确定时可能复位芯片。
        options.c_cflag &= ~tcflag_t(HUPCL)
        cfsetspeed(&options, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            throw Failure.configure(code: errno)
        }

        // ESP32-C3 的 USB Serial/JTAG 把 DTR/RTS 当作复位与下载模式控制:DTR=0 且 RTS=1 会复位芯片。
        // macOS 打开端口时两者同时置 1;先清 RTS 再清 DTR,途经 (1,0) 而不是 (0,1),打开端口不会复位设备。
        var rts = TIOCM_RTS
        _ = ioctl(fd, IOCTL.clearModemBits, &rts)
        var dtr = TIOCM_DTR
        _ = ioctl(fd, IOCTL.clearModemBits, &dtr)
    }

    /// <sys/ttycom.h> 的 _IO/_IOW 宏无法导入 Swift,数值按 ioccom.h 展开,已与 C 头文件核对。
    private enum IOCTL {
        static let exclusive: UInt = 0x2000_740D  // TIOCEXCL
        static let clearModemBits: UInt = 0x8004_746B  // TIOCMBIC
    }
}
