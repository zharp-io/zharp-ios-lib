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
                                      path: String(cString: name)))
        }
        return images
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
