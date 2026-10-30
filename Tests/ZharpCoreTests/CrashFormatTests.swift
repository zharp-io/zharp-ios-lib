import XCTest
@testable import ZharpCore

final class CrashFormatTests: XCTestCase {
    private let app = BinaryImage(loadAddress: 0x1_0000_0000, uuid: "11111111-2222-3333-4444-555555555555",
                                  path: "/private/var/containers/Bundle/Application/X/My App.app/MyApp")
    private let platform = BinaryImage(loadAddress: 0x1_8000_0000, uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                                       path: "/usr/lib/system/libsystem_platform.dylib")
    private let uikit = BinaryImage(loadAddress: 0x1_9000_0000, uuid: "",
                                    path: "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore")

    /// What the signal handler writes (see SignalHandler.swift).
    private func report(signal: Int32, pc: UInt64, frames: [UInt64]) -> String {
        var text = "zharp-crash 1\nsignal \(signal)\ntime 1700000000\npc 0x\(String(pc, radix: 16))\nframes\n"
        for frame in frames { text += "0x\(String(frame, radix: 16))\n" }
        text += "images\n"
        for image in [app, platform, uikit] { text += CrashFormat.imageLine(image) + "\n" }
        return text
    }

    func testImageLinesRoundTrip() {
        for image in [app, platform, uikit] {
            let line = CrashFormat.imageLine(image)
            XCTAssertEqual(CrashFormat.parseImageLine(Substring(line)), image, line)
        }
        XCTAssertEqual(CrashFormat.imageLine(uikit), "0x190000000 - /System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore")
    }

    func testParseSignalReport() throws {
        let text = report(signal: SIGSEGV, pc: 0x1_0000_2000, frames: [0x1_0000_9000, 0x1_8000_0100, 0x1_0000_3000])
        let parsed = try XCTUnwrap(CrashFormat.parseSignalReport(text))
        XCTAssertEqual(parsed.signal, SIGSEGV)
        XCTAssertEqual(parsed.time, 1_700_000_000)
        XCTAssertEqual(parsed.pc, 0x1_0000_2000)
        XCTAssertEqual(parsed.frames, [0x1_0000_9000, 0x1_8000_0100, 0x1_0000_3000])
        XCTAssertEqual(parsed.images, [app, platform, uikit])
    }

    func testRejectsOtherFiles() {
        XCTAssertNil(CrashFormat.parseSignalReport(""))
        XCTAssertNil(CrashFormat.parseSignalReport("{\"type\":\"x\"}"))
        XCTAssertNil(CrashFormat.parseSignalReport("zharp-crash 1\ntime 5\n"), "no signal")
    }

    func testCutShortReportStillParses() throws {
        // The process can die mid-write; what was written is still useful.
        let text = "zharp-crash 1\nsignal 5\ntime 1700000000\npc 0x100002000\nframes\n0x100009000\n0x1000"
        let parsed = try XCTUnwrap(CrashFormat.parseSignalReport(text))
        XCTAssertEqual(parsed.signal, 5)
        XCTAssertEqual(parsed.frames, [0x1_0000_9000, 0x1000])
        XCTAssertEqual(parsed.images, [])
    }

    func testDescribeSignalCrash() throws {
        // backtrace() inside the handler: [handler, _sigtramp, caller of the faulting function…]
        let text = report(signal: SIGSEGV, pc: 0x1_0000_2000,
                          frames: [0x1_0000_9000, 0x1_8000_0100, 0x1_0000_3000, 0x1_9000_0040])
        let error = CrashFormat.describe(try XCTUnwrap(CrashFormat.parseSignalReport(text)))
        XCTAssertEqual(error.type, "EXC_BAD_ACCESS")
        XCTAssertTrue(error.message.hasPrefix("SIGSEGV"), error.message)

        let lines = error.stacktrace.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "EXC_BAD_ACCESS: \(error.message)")
        XCTAssertEqual(lines[1], CrashFormat.frameLine(index: 0, address: 0x1_0000_2000, image: app))
        XCTAssertEqual(lines[2], CrashFormat.frameLine(index: 1, address: 0x1_0000_3000, image: app))
        XCTAssertEqual(lines[3], CrashFormat.frameLine(index: 2, address: 0x1_9000_0040, image: uikit))
        XCTAssertEqual(lines[4], "")
        XCTAssertEqual(lines[5], "Binary Images:")
        XCTAssertEqual(Array(lines[6...]), [CrashFormat.imageLine(app), CrashFormat.imageLine(uikit)])
    }

    func testSwiftRuntimeErrorsAreBreakpoints() {
        XCTAssertEqual(CrashFormat.exceptionType(signal: SIGTRAP), "EXC_BREAKPOINT")
        XCTAssertTrue(CrashFormat.signalMessage(SIGTRAP).contains("force-unwrapping nil"))
        XCTAssertEqual(CrashFormat.exceptionType(signal: SIGABRT), "SIGABRT")
        XCTAssertEqual(CrashFormat.exceptionType(signal: SIGBUS), "EXC_BAD_ACCESS")
        XCTAssertEqual(CrashFormat.exceptionType(signal: SIGILL), "EXC_BAD_INSTRUCTION")
    }

    func testUnknownAddresses() {
        XCTAssertNil(CrashFormat.image(containing: 0x10, in: [app]))
        XCTAssertNil(CrashFormat.image(containing: 0x1_0000_0000 + (1 << 31), in: [app]), "too far past the image")
        XCTAssertEqual(CrashFormat.frameLine(index: 0, address: 0x10, image: nil),
                       "0   ???                              0x0000000000000010")
    }

    func testExceptionStacktrace() {
        let symbols = [
            "0   CoreFoundation                      0x0000000180a1b2c3 __exceptionPreprocess + 164",
            "1   libobjc.A.dylib                     0x0000000180a00000 objc_exception_throw + 60",
            "2   MyApp                               0x0000000100002000 MyApp + 8192",
        ]
        let text = CrashFormat.exceptionStacktrace(type: "NSInvalidArgumentException",
                                                   message: "-[NSNull length]: unrecognized selector",
                                                   symbols: symbols,
                                                   addresses: [0x1_0000_2000],
                                                   images: [app, uikit])
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "NSInvalidArgumentException: -[NSNull length]: unrecognized selector")
        XCTAssertEqual(Array(lines[1...3]), symbols)
        XCTAssertEqual(lines[5], "Binary Images:")
        XCTAssertEqual(lines[6], CrashFormat.imageLine(app))
        XCTAssertEqual(lines.count, 7)
    }

    func testExceptionReportRoundTripsThroughJSON() throws {
        let report = ExceptionCrashReport(type: "T", message: "m", stacktrace: "T: m\n0 x", time: 1_700_000_000.5)
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(ExceptionCrashReport.self, from: data), report)
    }
}
