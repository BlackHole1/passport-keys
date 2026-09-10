import Foundation
import Testing
@testable import PassportKeys

struct PassportProtocolTests {
    @Test func decodesButtonPress() {
        let message = PassportProtocol.decode(line: #"{"t":"btn","k":"up","e":"press","seq":7,"boot":"a1b2c3d4"}"#)
        #expect(message == .button(ButtonPress(button: .up, event: "press", seq: 7, bootID: "a1b2c3d4")))
    }

    @Test func decodesHello() {
        let message = PassportProtocol.decode(line: #"{"t":"hello","fw":"passport-keys","proto":1,"ver":"1.0.0","boot":"0000beef"}"#)
        #expect(message == .hello(DeviceHello(firmware: "passport-keys", protocolVersion: 1, firmwareVersion: "1.0.0", bootID: "0000beef")))
    }

    @Test func decodesBatteryAndDropsInvalidReadings() {
        #expect(PassportProtocol.decode(line: #"{"t":"bat","soc":87,"mv":4012}"#) == .battery(BatteryReport(percent: 87, millivolts: 4012)))
        #expect(PassportProtocol.decode(line: #"{"t":"bat","soc":-1,"mv":-1}"#) == .battery(BatteryReport(percent: nil, millivolts: nil)))
    }

    @Test func findsFrameAfterLogPrefix() {
        #expect(PassportProtocol.decode(line: "\u{1B}[0;32mI (1532) pk_app: {\"t\":\"pong\"}") == .pong)
        #expect(PassportProtocol.decode(line: #"{"t":"ack","cmd":"labels"}"#) == .ack("labels"))
    }

    @Test(arguments: [
        "I (318) main_task: Calling app_main()",
        "",
        #"{"t":"btn","k":"left","e":"press","seq":1,"boot":"x"}"#,
        #"{"t":"btn","k":"up","e":"press"}"#,
        #"{"t":"hello","ver":"1.0.0"}"#,
        #"{"t":"unknown"}"#,
        #"{"t":"btn","k":"up""#,
    ])
    func ignoresNonProtocolLines(line: String) {
        #expect(PassportProtocol.decode(line: line) == nil)
    }

    @Test func encodesCommands() {
        #expect(String(decoding: PassportProtocol.encode(.hello), as: UTF8.self) == "{\"cmd\":\"hello\"}\n")
        #expect(String(decoding: PassportProtocol.encode(.ping), as: UTF8.self) == "{\"cmd\":\"ping\"}\n")
        #expect(String(decoding: PassportProtocol.encode(.bye), as: UTF8.self) == "{\"cmd\":\"bye\"}\n")

        let labels = DeviceLabels(up: "Cmd+A", down: "Down", ok: #"Say "hi"/"#)
        #expect(String(decoding: PassportProtocol.encode(.labels(labels)), as: UTF8.self)
            == #"{"cmd":"labels","down":"Down","ok":"Say \"hi\"/","up":"Cmd+A"}"# + "\n")
    }
}

struct LineBufferTests {
    @Test func joinsChunksAndStripsCarriageReturn() {
        var buffer = LineBuffer()
        let first = buffer.append(Data(#"{"t":"#.utf8))
        let second = buffer.append(Data("\"pong\"}\r\nnext".utf8))
        let third = buffer.append(Data("\n\r\n\n".utf8))
        #expect(first.isEmpty)
        #expect(second == [#"{"t":"pong"}"#])
        #expect(third == ["next"])
    }

    @Test func discardsOverlongLineUntilNewline() {
        var buffer = LineBuffer(maxLineBytes: 8)
        let first = buffer.append(Data("0123456789abc".utf8))
        let second = buffer.append(Data("def\nok\n".utf8))
        #expect(first.isEmpty)
        #expect(second == ["ok"])
    }
}

struct RecentEventFilterTests {
    @Test func rejectsDuplicatesWithinSameBoot() {
        var filter = RecentEventFilter(capacity: 2)
        let first = ButtonPress(button: .ok, event: "press", seq: 1, bootID: "a")
        let results = [
            filter.accept(first),
            filter.accept(first),
            filter.accept(ButtonPress(button: .ok, event: "press", seq: 1, bootID: "b")),
            filter.accept(ButtonPress(button: .ok, event: "press", seq: 2, bootID: "b")),
            // 容量为 2,最早的 a:1 已被淘汰,再次出现时视为新事件。
            filter.accept(first),
        ]
        #expect(results == [true, false, true, true, true])
    }
}
