// Compile: swiftc -O system-stats.swift -o system-stats
// Usage: system-stats [network-interface], for example system-stats en0
// Emits protocol v1 NDJSON; all measurements stay on this Mac.
import Darwin
import Foundation

struct Widget: Encodable {
    let id: String
    let label: String
    let value: String
    let color: String
    let history: [Double]?
}
struct Frame: Encodable {
    let version = 1
    let widgets: [Widget]
}

func cpuTicks() -> [UInt64]? {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3].map(UInt64.init)
}

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

let interface = CommandLine.arguments.dropFirst().first ?? "en0"
let encoder = JSONEncoder()
var previousCPU = cpuTicks()
var previousNetwork = networkBytes(interface)
var previousTime = ProcessInfo.processInfo.systemUptime
var histories: [String: [Double]] = [:]

func history(_ id: String, _ value: Double) -> [Double] {
    var values = histories[id] ?? []
    values.append(value)
    values = Array(values.suffix(60))
    histories[id] = values
    return values
}

func rateText(_ bytes: Double) -> String {
    if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
    return String(format: "%.1f kB/s", bytes / 1000)
}

// Wait for two samples: never display fabricated initial CPU or network rates.
while true {
    Thread.sleep(forTimeInterval: 1)
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = max(0.001, now - previousTime)
    previousTime = now
    var widgets: [Widget] = []
    let cpu = cpuTicks()
    if let current = cpu, let previous = previousCPU,
       zip(current, previous).allSatisfy({ $0 >= $1 }) {
        let delta = zip(current, previous).map { $0 - $1 }
        let total = delta.reduce(0, +)
        if total > 0 {
            let ratio = Double(total - delta[2]) / Double(total)
            widgets.append(Widget(id: "cpu", label: "CPU", value: String(format: "%.0f%%", ratio * 100),
                                  color: "5CC8FF", history: history("cpu", ratio)))
        }
    }
    previousCPU = cpu
    if let used = memoryUsed() {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        widgets.append(Widget(id: "ram", label: "RAM ≈", value: String(format: "%.1f / %.0f GiB", used / pow(1024, 3), total / pow(1024, 3)),
                              color: "82AAFF", history: history("ram", used / total)))
    }
    let network = networkBytes(interface)
    if let current = network, let previous = previousNetwork,
       current.0 >= previous.0, current.1 >= previous.1 {
        let rates = [("download", "↓", Double(current.0 - previous.0) / elapsed),
                     ("upload", "↑", Double(current.1 - previous.1) / elapsed)]
        for (id, label, rate) in rates {
            let samples = history(id, rate)
            let peak = max(1, samples.max() ?? 1)
            widgets.append(Widget(id: id, label: "\(interface) \(label)", value: rateText(rate),
                                  color: "89DDFF", history: samples.map { $0 / peak }))
        }
    } else {
        widgets.append(Widget(id: "network", label: interface, value: "Waiting for network sample", color: "89DDFF", history: nil))
    }
    previousNetwork = network
    do {
        var data = try encoder.encode(Frame(widgets: widgets))
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch { exit(0) }
}
