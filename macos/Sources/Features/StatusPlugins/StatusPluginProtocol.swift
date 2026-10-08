import Foundation
import Darwin

/// Experimental v1 API: plugins provide data, never executable UI or terminal input.
struct StatusPluginManifest: Decodable {
    let version: Int
    let plugins: [Plugin]

    struct Plugin: Decodable {
        let id: String
        let executable: String
        let arguments: [String]
    }

    static func load(_ path: String) throws -> Self {
        guard path.hasPrefix("/") else { throw StatusPluginError.invalidManifest }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw StatusPluginError.invalidManifest }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { throw StatusPluginError.invalidManifest }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw StatusPluginError.invalidManifest }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, result.plugins.count <= 8,
              Set(result.plugins.map(\.id)).count == result.plugins.count,
              result.plugins.allSatisfy({
                  !$0.id.isEmpty && $0.id.count <= 64 &&
                  $0.executable.hasPrefix("/") && !$0.executable.contains("\0") && $0.arguments.count <= 32 &&
                  $0.arguments.allSatisfy { $0.utf8.count <= 4096 && !$0.contains("\0") }
              }) else { throw StatusPluginError.invalidManifest }
        return result
    }
}

enum StatusPluginError: Error {
    case invalidManifest
    case invalidFrame
    case outputLimit
}

struct StatusPluginFrame: Decodable {
    let version: Int
    let widgets: [Widget]

    struct Widget: Decodable, Identifiable {
        let id: String
        let label: String
        let value: String
        /// Hex RRGGBB. No markup, terminal escapes, or arbitrary view code.
        let color: String
        /// Optional history, normalized to 0...1 by the producer.
        let history: [Double]?
    }

    static func decode(_ data: Data) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: data)
        func plain(_ value: String, limit: Int) -> Bool {
            value.count <= limit && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
        }
        guard result.version == 1, result.widgets.count <= 12,
              Set(result.widgets.map(\.id)).count == result.widgets.count,
              result.widgets.allSatisfy({ widget in
                  !widget.id.isEmpty && plain(widget.id, limit: 64) &&
                  plain(widget.label, limit: 32) && plain(widget.value, limit: 64) &&
                  widget.color.utf8.count == 6 && UInt32(widget.color, radix: 16) != nil &&
                  (widget.history?.count ?? 0) <= 60 &&
                  (widget.history?.allSatisfy { $0.isFinite && (0...1).contains($0) } ?? true)
              }) else { throw StatusPluginError.invalidFrame }
        return result
    }
}

/// Bounded NDJSON framing. Partial records may span reads; newest complete frame wins.
struct StatusPluginDecoder {
    private var pending = Data()
    static let maximumRecordBytes = 16_384

    mutating func append(_ chunk: Data) throws -> StatusPluginFrame? {
        var latest: StatusPluginFrame?
        for byte in chunk {
            if byte == 10 {
                if !pending.isEmpty { latest = try StatusPluginFrame.decode(pending) }
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < Self.maximumRecordBytes else {
                    throw StatusPluginError.outputLimit
                }
                pending.append(byte)
            }
        }
        return latest
    }
}
