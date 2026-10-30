import Foundation

/// An error as the server reads it: `exception.type`, `exception.message`, `exception.stacktrace`.
/// The stack's first line is "Type: message"; the frames below it are in Apple's crash-report
/// shape (`3   MyApp   0x0000000100a3c1f4 symbol + 52`), which the server recognises.
public struct ErrorDescription: Codable, Equatable {
    public var type: String
    public var message: String
    public var stacktrace: String
    /// The images the stack's addresses are in (also listed under "Binary Images:" in
    /// `stacktrace`); sent as `zharp.binary_images` so Zharp can symbolicate with the dSYMs.
    public var images: [BinaryImage]

    public init(type: String, message: String, stacktrace: String, images: [BinaryImage] = []) {
        self.type = type
        self.message = message
        self.stacktrace = stacktrace
        self.images = images
    }
}

public enum ErrorFormatting {
    /// Markers of the SDK's own frames in `Thread.callStackSymbols` (mangled module names).
    static let sdkFrameMarkers = ["5Zharp", "9ZharpCore"]

    /// A Swift or Cocoa error as captured by `Zharp.captureError`, with the stack of the place it
    /// was captured (Swift errors carry no stack of their own). Given the stack's return addresses
    /// and the loaded images, the images it runs through are listed under "Binary Images:", so a
    /// stripped release build's frames can be symbolicated with its dSYM.
    public static func describe(_ error: Error, callStack: [String], addresses: [UInt64] = [],
                                images: [BinaryImage] = []) -> ErrorDescription {
        let nsError = error as NSError
        let reflected = String(reflecting: type(of: error))
        let cocoa = isCocoaType(reflected)
        let typeName = cocoa ? "\(nsError.domain)(\(nsError.code))" : cleanTypeName(reflected)
        let text = message(for: error, cocoa: cocoa)
        let frames = renumber(dropSDKFrames(callStack))
        let used = CrashFormat.usedImages(addresses: addresses, images: images)
        var stack = stacktrace(type: typeName, message: text, frames: frames)
        let section = CrashFormat.binaryImagesSection(used)
        if !section.isEmpty { stack += "\n\n" + section }
        return ErrorDescription(type: typeName, message: text, stacktrace: stack, images: used)
    }

    /// An Objective-C error class (NSError and its private subclasses) rather than a Swift type,
    /// which is always module-qualified.
    static func isCocoaType(_ reflected: String) -> Bool {
        !reflected.contains(".") || reflected.hasPrefix("__C.")
    }

    /// Removes what changes between builds from a reflected type name, which would otherwise
    /// split one issue into many: "(unknown context at $1029a4b2c)." of local types, and the
    /// discriminator of private types, "(PaymentError in _3B8C…)" → "PaymentError".
    public static func cleanTypeName(_ name: String) -> String {
        var out = name
        out = replace(#"\(unknown context at \$[0-9A-Fa-f]+\)\.?"#, in: out, with: "")
        out = replace(#"\(([^()\s]+) in _[0-9A-Fa-f]+\)"#, in: out, with: "$1")
        return out
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    static func message(for error: Error, cocoa: Bool) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        if cocoa { return (error as NSError).localizedDescription }
        return String(describing: error)
    }

    public static func headline(type: String, message: String) -> String {
        message.isEmpty ? type : "\(type): \(message)"
    }

    public static func stacktrace(type: String, message: String, frames: [String]) -> String {
        ([headline(type: type, message: message)] + frames).joined(separator: "\n")
    }

    /// Drops the SDK's own frames from the top of a captured stack.
    public static func dropSDKFrames(_ frames: [String]) -> [String] {
        var index = 0
        while index < frames.count, sdkFrameMarkers.contains(where: { frames[index].contains($0) }) {
            index += 1
        }
        return Array(frames[index...])
    }

    /// Numbers frames from 0 again after some were dropped.
    public static func renumber(_ frames: [String]) -> [String] {
        frames.enumerated().map { item -> String in
            let (offset, frame) = item
            let rest = frame.drop(while: { $0.isNumber }).drop(while: { $0 == " " })
            guard rest.count < frame.count else { return frame }
            return padRight(String(offset), 4) + String(rest)
        }
    }

    static func padRight(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}

// MARK: - Crash reports

/// A loaded binary image (the app, its frameworks, system libraries): enough to symbolicate an
/// address with `atos` and the dSYM.
public struct BinaryImage: Codable, Equatable {
    public var loadAddress: UInt64
    /// The Mach-O LC_UUID, as `dwarfdump --uuid` prints it for the matching dSYM.
    public var uuid: String
    public var path: String
    /// `arm64`, `arm64e`, `x86_64`… ("" when unknown).
    public var arch: String

    public init(loadAddress: UInt64, uuid: String, path: String, arch: String = "") {
        self.loadAddress = loadAddress
        self.uuid = uuid
        self.path = path
        self.arch = arch
    }

    public var name: String {
        (path as NSString).lastPathComponent
    }
}

/// What the signal handler writes. It may only use async-signal-safe calls, so it writes this
/// plain text (numbers and a pre-built image list) and the next launch turns it into an error.
public struct SignalCrashReport: Equatable {
    public var signal: Int32
    public var time: TimeInterval
    /// The faulting instruction, from the signal's machine context (0 when unknown).
    public var pc: UInt64
    /// Return addresses from `backtrace()`, called inside the handler.
    public var frames: [UInt64]
    public var images: [BinaryImage]

    public init(signal: Int32, time: TimeInterval, pc: UInt64, frames: [UInt64], images: [BinaryImage]) {
        self.signal = signal
        self.time = time
        self.pc = pc
        self.frames = frames
        self.images = images
    }
}

/// What the uncaught NSException handler writes (it runs before the process aborts, so it can use
/// Foundation and builds the stack text right away).
public struct ExceptionCrashReport: Codable, Equatable {
    public var type: String
    public var message: String
    public var stacktrace: String
    public var time: TimeInterval
    /// The images in the stack's Binary Images section (absent in reports written before).
    public var images: [BinaryImage]?

    public init(type: String, message: String, stacktrace: String, time: TimeInterval, images: [BinaryImage]? = nil) {
        self.type = type
        self.message = message
        self.stacktrace = stacktrace
        self.time = time
        self.images = images
    }
}

public enum CrashFormat {
    public static let signalReportHeader = "zharp-crash 1"
    static let maxFrames = 100
    /// An address more than this past an image's start isn't considered inside it.
    static let maxImageSpan: UInt64 = 1 << 30

    // MARK: Image list

    /// One line of the image list and of "Binary Images:": "0x100a30000 <UUID> arm64 /path/to/MyApp"
    /// ("-" for an unknown UUID or arch). The path may contain spaces, so it comes last.
    public static func imageLine(_ image: BinaryImage) -> String {
        "0x\(String(image.loadAddress, radix: 16)) \(image.uuid.isEmpty ? "-" : image.uuid) "
            + "\(image.arch.isEmpty ? "-" : image.arch) \(image.path)"
    }

    public static func parseImageLine(_ line: Substring) -> BinaryImage? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let load = hexValue(parts[0]) else { return nil }
        let uuid = parts[1] == "-" ? "" : String(parts[1])
        let arch = parts[2] == "-" ? "" : String(parts[2])
        return BinaryImage(loadAddress: load, uuid: uuid, path: String(parts[3]), arch: arch)
    }

    /// `zharp.binary_images`: `[{"arch","loadAddress","name","uuid"}]`, the load address as a hex
    /// string ("0x100a30000"; 64-bit values don't survive JSON numbers in JavaScript).
    public static func binaryImagesJSON(_ images: [BinaryImage]) -> String {
        let list: [[String: String]] = images.map {
            ["name": $0.name, "uuid": $0.uuid, "loadAddress": "0x" + String($0.loadAddress, radix: 16), "arch": $0.arch]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    // MARK: Signal report

    public static func parseSignalReport(_ text: String) -> SignalCrashReport? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }) == signalReportHeader else { return nil }
        var signal: Int32?
        var time: TimeInterval = 0
        var pc: UInt64 = 0
        var frames: [UInt64] = []
        var images: [BinaryImage] = []
        enum Section { case header, frames, images }
        var section = Section.header

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "frames" { section = .frames; continue }
            if trimmed == "images" { section = .images; continue }
            switch section {
            case .header:
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "signal": signal = Int32(String(parts[1]))
                case "time": time = TimeInterval(String(parts[1])) ?? 0
                case "pc": pc = hexValue(parts[1]) ?? 0
                default: break
                }
            case .frames:
                if let address = hexValue(Substring(trimmed)) { frames.append(address) }
            case .images:
                if let image = parseImageLine(Substring(trimmed)) { images.append(image) }
            }
        }
        guard let found = signal else { return nil }
        return SignalCrashReport(signal: found, time: time, pc: pc, frames: frames, images: images)
    }

    /// The crash as an error: type from the signal, message saying what it means, and the
    /// crashed thread's frames plus the binary images they are in.
    public static func describe(_ report: SignalCrashReport) -> ErrorDescription {
        let type = exceptionType(signal: report.signal)
        let message = signalMessage(report.signal)
        let addresses = crashedThreadAddresses(report)
        var text = stacktrace(type: type, message: message, addresses: addresses, images: report.images)
        let used = usedImages(addresses: addresses, images: report.images)
        let section = binaryImagesSection(used)
        if !section.isEmpty { text += "\n\n" + section }
        return ErrorDescription(type: type, message: message, stacktrace: text, images: used)
    }

    /// The crashed thread's frames, innermost first: the faulting instruction, then the callers.
    /// `backtrace()` runs inside the handler, so the handler's own frame and the kernel's
    /// `_sigtramp` frame (in libsystem_platform) come first; they are removed.
    static func crashedThreadAddresses(_ report: SignalCrashReport) -> [UInt64] {
        var frames = Array(report.frames.dropFirst())
        if let trampoline = frames.prefix(4).firstIndex(where: {
            image(containing: $0, in: report.images)?.name == "libsystem_platform.dylib"
        }) {
            frames.removeFirst(trampoline + 1)
        }
        if report.pc != 0 {
            if frames.first != report.pc { frames.insert(report.pc, at: 0) }
        }
        return Array(frames.prefix(maxFrames))
    }

    static func stacktrace(type: String, message: String, addresses: [UInt64], images: [BinaryImage]) -> String {
        var lines = [ErrorFormatting.headline(type: type, message: message)]
        for (index, address) in addresses.enumerated() {
            lines.append(frameLine(index: index, address: address, image: image(containing: address, in: images)))
        }
        return lines.joined(separator: "\n")
    }

    /// "0   MyApp                           0x0000000100a3c1f4 0x100a30000 + 49652"
    public static func frameLine(index: Int, address: UInt64, image: BinaryImage?) -> String {
        let name = image?.name ?? "???"
        let paddedName = name.count >= 32 ? name + " " : name + String(repeating: " ", count: 32 - name.count)
        var line = ErrorFormatting.padRight(String(index), 4) + paddedName + " " + hex16(address)
        if let image = image {
            line += " 0x\(String(image.loadAddress, radix: 16)) + \(address - image.loadAddress)"
        }
        return line
    }

    /// Each image an address is in, once, by load address.
    public static func usedImages(addresses: [UInt64], images: [BinaryImage]) -> [BinaryImage] {
        var used: [BinaryImage] = []
        for address in addresses {
            if let image = image(containing: address, in: images), !used.contains(image) { used.append(image) }
        }
        return used.sorted { $0.loadAddress < $1.loadAddress }
    }

    /// "Binary Images:" with each image an address is in, for symbolication.
    public static func binaryImagesSection(addresses: [UInt64], images: [BinaryImage]) -> String {
        binaryImagesSection(usedImages(addresses: addresses, images: images))
    }

    /// "Binary Images:" then one `imageLine` per image ("" for none).
    public static func binaryImagesSection(_ used: [BinaryImage]) -> String {
        guard !used.isEmpty else { return "" }
        return (["Binary Images:"] + used.map(imageLine)).joined(separator: "\n")
    }

    /// The image with the highest load address at or below `address`, if the address is plausibly
    /// inside it.
    public static func image(containing address: UInt64, in images: [BinaryImage]) -> BinaryImage? {
        var best: BinaryImage?
        for image in images where image.loadAddress <= address {
            if best == nil || image.loadAddress > best!.loadAddress { best = image }
        }
        guard let found = best, address - found.loadAddress < maxImageSpan else { return nil }
        return found
    }

    // MARK: Exception report

    /// The stack text for an uncaught NSException: its symbolicated call stack plus the images
    /// its return addresses are in.
    public static func exceptionStacktrace(type: String, message: String, symbols: [String],
                                           addresses: [UInt64], images: [BinaryImage]) -> String {
        var text = ([ErrorFormatting.headline(type: type, message: message)] + symbols.prefix(maxFrames))
            .joined(separator: "\n")
        let section = binaryImagesSection(addresses: addresses, images: images)
        if !section.isEmpty { text += "\n\n" + section }
        return text
    }

    // MARK: Signals

    public static func exceptionType(signal: Int32) -> String {
        switch signal {
        case SIGSEGV, SIGBUS: return "EXC_BAD_ACCESS"
        case SIGILL: return "EXC_BAD_INSTRUCTION"
        case SIGTRAP: return "EXC_BREAKPOINT"
        case SIGFPE: return "EXC_ARITHMETIC"
        case SIGABRT: return "SIGABRT"
        default: return "SIGNAL \(signal)"
        }
    }

    public static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGFPE: return "SIGFPE"
        case SIGABRT: return "SIGABRT"
        default: return "signal \(signal)"
        }
    }

    public static func signalMessage(_ signal: Int32) -> String {
        switch signal {
        case SIGSEGV, SIGBUS:
            return "\(signalName(signal)), the app touched memory it may not use"
        case SIGILL:
            return "SIGILL, an illegal instruction"
        case SIGTRAP:
            return "SIGTRAP, a Swift runtime error such as force-unwrapping nil, an index out of range or fatalError()"
        case SIGFPE:
            return "SIGFPE, an arithmetic error"
        case SIGABRT:
            return "the app called abort(), for example from a failed assertion"
        default:
            return "the app was stopped by \(signalName(signal))"
        }
    }

    // MARK: Hex

    static func hex16(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    static func hexValue(_ text: Substring) -> UInt64? {
        let lowered = text.lowercased()
        guard lowered.hasPrefix("0x") else { return nil }
        return UInt64(lowered.dropFirst(2), radix: 16)
    }
}
