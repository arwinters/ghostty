// Compile: swiftc -O system-stats.swift -o system-stats
// Usage: system-stats [network-interface] [--graph blocks|lines] [--no-disk]
//   for example: system-stats en0 --graph blocks
// Blocks: CPU shows one block per core (performance cores blue, efficiency cores teal);
// the other measurements show their last 12 samples as blocks. Lines: 60-sample sparklines.
// Emits protocol v1 NDJSON; all measurements stay on this Mac.
import Darwin
import Foundation
import IOKit

struct Widget: Encodable {
    let id: String
    let label: String
    let value: String
    let color: String
    var history: [Double]?
    var bars: [Double]?
    var barColors: [String]?
}
struct Frame: Encodable {
    let version = 1
    let widgets: [Widget]
}

/// One color per measurement so related values (in/out, read/write) are easy to tell apart.
enum Palette {
    static let cpu = "5CC8FF"        // ice blue: performance cores
    static let cpuEfficiency = "2DD4BF" // teal: efficiency cores
    static let memory = "BD93F9"     // purple
    static let download = "50FA7B"   // green
    static let upload = "FFB86C"     // orange
    static let diskSpace = "F1FA8C"  // yellow
    static let diskRead = "F78C6C"   // coral
    static let diskWrite = "FF79C6"  // pink
}

// MARK: Arguments

var interface = "en0"
var blocks = true
var showDisk = true
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--graph", "--cpu-graph":
        // "sparkline" is the 0.5.0 spelling of "lines".
        if !arguments.isEmpty { blocks = arguments.removeFirst() == "blocks" }
    case "--no-disk": showDisk = false
    default: interface = argument
    }
}

// MARK: CPU

/// Per-core (user+system+nice, total) tick counters.
func coreTicks() -> [(busy: UInt64, total: UInt64)]? {
    var count: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
          let info else { return nil }
    defer {
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                      vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }
    return (0..<Int(count)).map { core in
        let base = core * Int(CPU_STATE_MAX)
        let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
        let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
        let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
        return (user + system + nice, user + system + nice + idle)
    }
}

/// Number of efficiency cores. Apple silicon numbers them first; Intel Macs have none.
func efficiencyCoreCount() -> Int {
    var levels: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("hw.nperflevels", &levels, &size, nil, 0) == 0, levels > 1 else { return 0 }
    var count: Int32 = 0
    size = MemoryLayout<Int32>.size
    guard sysctlbyname("hw.perflevel1.logicalcpu", &count, &size, nil, 0) == 0 else { return 0 }
    return Int(count)
}

// MARK: Memory

func memoryUsed() -> Double? {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    // Physical pages in active, wired and compressed pools; an approximation,
    // not Activity Monitor's application memory or memory pressure calculation.
    let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
    return min(Double(ProcessInfo.processInfo.physicalMemory), Double(pages) * Double(getpagesize()))
}

// MARK: Network

func networkBytes(_ interface: String) -> (UInt64, UInt64)? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
        let entry = current.pointee
        if String(cString: entry.ifa_name) == interface,
           entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
           (entry.ifa_flags & UInt32(IFF_UP)) != 0,
           let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) {
            return (UInt64(data.pointee.ifi_ibytes), UInt64(data.pointee.ifi_obytes))
        }
        cursor = entry.ifa_next
    }
    return nil
}

// MARK: Disk

/// Used and total bytes of the volume holding user data.
func diskSpace() -> (used: Double, total: Double)? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
    guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey]),
          let total = values.volumeTotalCapacity, total > 0 else { return nil }
    let available = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
    return (Double(total) - available, Double(total))
}

/// Cumulative bytes read and written by all block storage drivers.
func diskBytes() -> (read: UInt64, written: UInt64)? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                       &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var read: UInt64 = 0
    var written: UInt64 = 0
    var service = IOIteratorNext(iterator)
    while service != 0 {
        if let unmanaged = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0),
           let statistics = unmanaged.takeRetainedValue() as? [String: Any] {
            read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return (read, written)
}

// MARK: Formatting

var histories: [String: [Double]] = [:]

func history(_ id: String, _ value: Double) -> [Double] {
    var values = histories[id] ?? []
    values.append(value)
    values = Array(values.suffix(60))
    histories[id] = values
    return values
}

/// A history scaled to its own recent peak, for unbounded rates.
func scaledHistory(_ id: String, _ value: Double) -> [Double] {
    let samples = history(id, value)
    let peak = max(1, samples.max() ?? 1)
    return samples.map { $0 / peak }
}

func rateText(_ bytes: Double) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB/s", bytes / 1_000_000_000) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
    return String(format: "%.0f kB/s", bytes / 1000)
}

/// Fixed-width rate for the compact block layout, e.g. " 41k", "1.2M".
func shortRate(_ bytes: Double) -> String {
    if bytes >= 1e9 { return String(format: "%4.1fG", bytes / 1e9) }
    if bytes >= 1e7 { return String(format: "%4.0fM", bytes / 1e6) }
    if bytes >= 1e6 { return String(format: "%4.1fM", bytes / 1e6) }
    return String(format: "%4.0fk", bytes / 1e3)
}

/// The most recent samples as blocks, scaled to `peak` (or to their own maximum).
func recentBlocks(_ samples: [Double], count: Int = 12, peak: Double? = nil) -> [Double] {
    let recent = Array(samples.suffix(count))
    let scale = max(peak ?? (recent.max() ?? 1), 1e-9)
    let padded = Array(repeating: 0.0, count: max(0, count - recent.count)) + recent
    return padded.map { min(1, max(0, $0 / scale)) }
}

/// A segmented meter, e.g. 72% of 8 segments -> six full blocks and a partial one.
func meter(_ ratio: Double, segments: Int = 8) -> [Double] {
    (0..<segments).map { min(1, max(0, ratio * Double(segments) - Double($0))) }
}

func sizeText(_ bytes: Double) -> String {
    bytes >= 1e12 ? String(format: "%.2f TB", bytes / 1e12) : String(format: "%.0f GB", bytes / 1e9)
}

// MARK: Loop

let encoder = JSONEncoder()
let efficiencyCores = efficiencyCoreCount()
var previousCores = coreTicks()
var previousNetwork = networkBytes(interface)
var previousDisk = showDisk ? diskBytes() : nil
var previousTime = ProcessInfo.processInfo.systemUptime
var tick = 0
var cachedSpace = showDisk ? diskSpace() : nil
var rawRates: [String: [Double]] = [:]

func rate(_ id: String, _ value: Double) -> [Double] {
    var values = rawRates[id] ?? []
    values.append(value)
    values = Array(values.suffix(60))
    rawRates[id] = values
    return values
}

// Wait for two samples: never display fabricated initial rates.
while true {
    Thread.sleep(forTimeInterval: 1)
    tick += 1
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = max(0.001, now - previousTime)
    previousTime = now
    var widgets: [Widget] = []

    let cores = coreTicks()
    if let current = cores, let previous = previousCores, current.count == previous.count {
        let loads = zip(current, previous).map { now, before -> Double in
            guard now.total > before.total, now.busy >= before.busy else { return 0 }
            return min(1, Double(now.busy - before.busy) / Double(now.total - before.total))
        }
        let busy = zip(current, previous).reduce(0.0) { $0 + Double($1.0.busy &- $1.1.busy) }
        let total = zip(current, previous).reduce(0.0) { $0 + Double($1.0.total &- $1.1.total) }
        let ratio = total > 0 ? min(1, busy / total) : 0
        let averaged = history("cpu", ratio)
        var widget = Widget(id: "cpu", label: "CPU", value: String(format: "%3.0f%%", ratio * 100),
                            color: Palette.cpu)
        if blocks {
            // Performance cores first, then the efficiency cores in their own color.
            let split = min(efficiencyCores, loads.count)
            let ordered = Array(loads[split...]) + Array(loads[..<split])
            widget.bars = Array(ordered.prefix(64))
            widget.barColors = Array((Array(repeating: Palette.cpu, count: loads.count - split) +
                                      Array(repeating: Palette.cpuEfficiency, count: split)).prefix(64))
        } else {
            widget.history = averaged
        }
        widgets.append(widget)
    }
    previousCores = cores

    if let used = memoryUsed() {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let samples = history("ram", used / total)
        if blocks {
            widgets.append(Widget(id: "ram", label: "MEM",
                                  value: String(format: "%.0f/%.0fG", used / pow(1024, 3), total / pow(1024, 3)),
                                  color: Palette.memory, bars: recentBlocks(samples, peak: 1)))
        } else {
            widgets.append(Widget(id: "ram", label: "RAM ≈",
                                  value: String(format: "%.1f / %.0f GiB", used / pow(1024, 3), total / pow(1024, 3)),
                                  color: Palette.memory, history: samples))
        }
    }

    let network = networkBytes(interface)
    if let current = network, let previous = previousNetwork,
       current.0 >= previous.0, current.1 >= previous.1 {
        let down = Double(current.0 - previous.0) / elapsed
        let up = Double(current.1 - previous.1) / elapsed
        if blocks {
            widgets.append(Widget(id: "download", label: "NET ↓", value: shortRate(down),
                                  color: Palette.download, bars: recentBlocks(rate("download", down))))
            widgets.append(Widget(id: "upload", label: "↑", value: shortRate(up),
                                  color: Palette.upload, bars: recentBlocks(rate("upload", up))))
        } else {
            widgets.append(Widget(id: "download", label: "\(interface) ↓", value: rateText(down),
                                  color: Palette.download, history: scaledHistory("download", down)))
            widgets.append(Widget(id: "upload", label: "↑", value: rateText(up),
                                  color: Palette.upload, history: scaledHistory("upload", up)))
        }
    } else {
        widgets.append(Widget(id: "network", label: blocks ? "NET" : interface, value: "waiting",
                              color: Palette.download))
    }
    previousNetwork = network

    if showDisk {
        // Free space changes slowly; query it every ten seconds.
        if tick % 10 == 0 { cachedSpace = diskSpace() }
        if let space = cachedSpace {
            let used = space.used / space.total
            widgets.append(Widget(id: "disk-space", label: blocks ? "DSK" : "Disk",
                                  value: blocks ? String(format: "%.0f%%", used * 100)
                                                : "\(sizeText(space.used)) / \(sizeText(space.total))",
                                  color: Palette.diskSpace, bars: blocks ? meter(used) : [used]))
        }
        let disk = diskBytes()
        if let current = disk, let previous = previousDisk,
           current.read >= previous.read, current.written >= previous.written {
            let read = Double(current.read - previous.read) / elapsed
            let written = Double(current.written - previous.written) / elapsed
            if blocks {
                widgets.append(Widget(id: "disk-read", label: "R", value: shortRate(read),
                                      color: Palette.diskRead, bars: recentBlocks(rate("disk-read", read))))
                widgets.append(Widget(id: "disk-write", label: "W", value: shortRate(written),
                                      color: Palette.diskWrite, bars: recentBlocks(rate("disk-write", written))))
            } else {
                widgets.append(Widget(id: "disk-read", label: "R", value: rateText(read),
                                      color: Palette.diskRead, history: scaledHistory("disk-read", read)))
                widgets.append(Widget(id: "disk-write", label: "W", value: rateText(written),
                                      color: Palette.diskWrite, history: scaledHistory("disk-write", written)))
            }
        }
        previousDisk = disk
    }

    do {
        var data = try encoder.encode(Frame(widgets: widgets))
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch { exit(0) }
}
