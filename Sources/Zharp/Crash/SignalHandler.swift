import Foundation
import ZharpCore

#if canImport(Darwin)
import Darwin

// Everything the signal handler touches is prepared in `SignalHandler.install` and kept in plain
// C memory: inside a signal handler there must be no allocation, no locks, no Objective-C and no
// Swift runtime work beyond reading these globals. The globals have constant initial values, so
// Swift initialises them statically (no lazy `swift_once` on first access).

private var gReportPath: UnsafeMutablePointer<CChar>? = nil
private var gImageList: UnsafeMutablePointer<CChar>? = nil
private var gImageListLength: Int = 0
private var gFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>? = nil
private var gScratch: UnsafeMutablePointer<UInt8>? = nil
private var gPreviousActions: UnsafeMutablePointer<sigaction>? = nil
private var gHandling: Int32 = 0
private var gExceptionWritten: Int32 = 0

private let kMaxFrames: Int32 = 128
private let kScratchSize = 32
private let kSignalCount = 6

/// The signals handled, in the order of `gPreviousActions`.
private func signalIndex(_ sig: Int32) -> Int? {
    switch sig {
    case SIGABRT: return 0
    case SIGBUS: return 1
    case SIGFPE: return 2
    case SIGILL: return 3
    case SIGSEGV: return 4
    case SIGTRAP: return 5
    default: return nil
    }
}

enum SignalHandler {
    private static var installed = false

    static func install(reportPath: String, imageList: String) {
        guard !installed else { return }
        installed = true

        gReportPath = strdup(reportPath)
        gImageList = strdup(imageList)
        gImageListLength = imageList.utf8.count
        gFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(kMaxFrames))
        gFrames?.initialize(repeating: nil, count: Int(kMaxFrames))
        gScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: kScratchSize)
        gScratch?.initialize(repeating: 0, count: kScratchSize)
        let previous = UnsafeMutablePointer<sigaction>.allocate(capacity: kSignalCount)
        previous.initialize(repeating: sigaction(), count: kSignalCount)
        gPreviousActions = previous

        installAlternateStack()

        for sig in [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP] {
            guard let index = signalIndex(sig) else { continue }
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = zharpSignalHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            action.sa_mask = sigset_t()
            sigaction(sig, &action, previous + index)
        }
    }

    /// The uncaught-exception handler has written a better report; the SIGABRT that follows it
    /// must not overwrite it.
    static func markExceptionWritten() {
        gExceptionWritten = 1
    }

    /// A separate stack for the handler, so a stack overflow on the main thread can still be
    /// reported. (It applies to the thread that calls `Zharp.start`.)
    private static func installAlternateStack() {
        let size = Int(SIGSTKSZ) * 2
        guard let memory = malloc(size) else { return }
        var stack = stack_t()
        stack.ss_sp = memory
        stack.ss_size = size
        stack.ss_flags = 0
        if sigaltstack(&stack, nil) != 0 { free(memory) }
    }
}

private func zharpSignalHandler(_ sig: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ context: UnsafeMutableRawPointer?) {
    if gHandling == 0 {
        gHandling = 1
        if gExceptionWritten == 0 { writeSignalReport(sig, context) }
    }
    // Hand the signal to whoever had it before (another crash reporter, or the default action,
    // which ends the process as it would have ended without Zharp).
    if let previous = gPreviousActions, let index = signalIndex(sig) {
        sigaction(sig, previous + index, nil)
    } else {
        var fallback = sigaction() // a nil handler is SIG_DFL
        sigaction(sig, &fallback, nil)
    }
    raise(sig)
}

private func writeSignalReport(_ sig: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let path = gReportPath else { return }
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd < 0 { return }
    writeLiteral(fd, "zharp-crash 1\nsignal ")
    writeDecimal(fd, Int64(sig))
    writeLiteral(fd, "\ntime ")
    writeDecimal(fd, Int64(time(nil)))
    writeLiteral(fd, "\npc ")
    writeHex(fd, faultingAddress(context))
    writeLiteral(fd, "\nframes\n")
    if let frames = gFrames {
        let count = Int(backtrace(frames, kMaxFrames))
        var index = 0
        while index < count {
            writeHex(fd, UInt64(UInt(bitPattern: frames[index])))
            writeLiteral(fd, "\n")
            index += 1
        }
    }
    writeLiteral(fd, "images\n")
    if let images = gImageList, gImageListLength > 0 {
        writeBytes(fd, UnsafeRawPointer(images), gImageListLength)
    }
    close(fd)
}

/// The instruction that faulted, from the machine context the kernel passes to the handler.
private func faultingAddress(_ context: UnsafeMutableRawPointer?) -> UInt64 {
    guard let context = context else { return 0 }
    let userContext = context.assumingMemoryBound(to: ucontext_t.self)
    guard let machineContext = userContext.pointee.uc_mcontext else { return 0 }
    #if arch(arm64)
    return UInt64(machineContext.pointee.__ss.__pc)
    #elseif arch(x86_64)
    return UInt64(machineContext.pointee.__ss.__rip)
    #else
    return 0
    #endif
}

// MARK: - Async-signal-safe output

private func writeBytes(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) {
    var offset = 0
    while offset < count {
        let written = write(fd, pointer + offset, count - offset)
        if written <= 0 { return }
        offset += written
    }
}

private func writeLiteral(_ fd: Int32, _ text: StaticString) {
    writeBytes(fd, UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
}

private func writeHex(_ fd: Int32, _ value: UInt64) {
    guard let buffer = gScratch else { return }
    var remaining = value
    var position = kScratchSize
    repeat {
        position -= 1
        let digit = UInt8(remaining & 0xF)
        buffer[position] = digit < 10 ? 48 + digit : 87 + digit // 0-9, a-f
        remaining >>= 4
    } while remaining != 0 && position > 2
    position -= 1
    buffer[position] = 120 // x
    position -= 1
    buffer[position] = 48 // 0
    writeBytes(fd, UnsafeRawPointer(buffer + position), kScratchSize - position)
}

private func writeDecimal(_ fd: Int32, _ value: Int64) {
    guard let buffer = gScratch else { return }
    var remaining = value.magnitude
    var position = kScratchSize
    repeat {
        position -= 1
        buffer[position] = 48 + UInt8(remaining % 10)
        remaining /= 10
    } while remaining != 0 && position > 1
    if value < 0 {
        position -= 1
        buffer[position] = 45 // -
    }
    writeBytes(fd, UnsafeRawPointer(buffer + position), kScratchSize - position)
}

#else

enum SignalHandler {
    static func install(reportPath: String, imageList: String) {}
    static func markExceptionWritten() {}
}

#endif
