import Foundation
import MachO
import ZharpCore

/// The images (app, frameworks, system libraries) loaded in this process, with the load address
/// and UUID a crash needs for symbolication.
enum BinaryImages {
    static func loaded() -> [BinaryImage] {
        var images: [BinaryImage] = []
        let count = _dyld_image_count()
        for index in 0..<count {
            guard let header = _dyld_get_image_header(index), let name = _dyld_get_image_name(index) else { continue }
            images.append(BinaryImage(loadAddress: UInt64(UInt(bitPattern: header)),
                                      uuid: uuid(of: header) ?? "",
                                      path: String(cString: name),
                                      arch: arch(of: header)))
        }
        return images
    }

    /// The image's CPU architecture as dSYMs name it: system libraries are often `arm64e` while
    /// the app is `arm64`.
    static func arch(of header: UnsafePointer<mach_header>) -> String {
        // <mach/machine.h> values, spelled out: the CPU_TYPE_* macros are built from casts and
        // ORs that Swift doesn't always import.
        let type = UInt32(bitPattern: header.pointee.cputype)
        let subtype = UInt32(bitPattern: header.pointee.cpusubtype) & 0x00ff_ffff
        switch type {
        case 0x0100_000c: return subtype == 2 ? "arm64e" : "arm64"   // CPU_TYPE_ARM64 (CPU_SUBTYPE_ARM64E = 2)
        case 0x0200_000c: return "arm64_32"                          // CPU_TYPE_ARM64_32
        case 0x0100_0007: return "x86_64"                            // CPU_TYPE_X86_64
        case 0x0000_000c: return "armv7"                             // CPU_TYPE_ARM
        case 0x0000_0007: return "i386"                              // CPU_TYPE_X86
        default: return ""
        }
    }

    /// The LC_UUID of a Mach-O image in memory.
    private static func uuid(of header: UnsafePointer<mach_header>) -> String? {
        let start = UnsafeRawPointer(header)
        var cursor: UnsafeRawPointer
        switch header.pointee.magic {
        case UInt32(MH_MAGIC_64): cursor = start.advanced(by: MemoryLayout<mach_header_64>.size)
        case UInt32(MH_MAGIC): cursor = start.advanced(by: MemoryLayout<mach_header>.size)
        default: return nil
        }
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.load(as: load_command.self)
            if command.cmd == UInt32(LC_UUID) {
                let uuidCommand = cursor.load(as: uuid_command.self)
                return UUID(uuid: uuidCommand.uuid).uuidString
            }
            guard command.cmdsize > 0 else { return nil }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return nil
    }
}
