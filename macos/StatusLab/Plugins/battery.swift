// Compile: swiftc -O battery.swift -o battery
// Usage: battery [--no-time]
// Emits protocol v1 NDJSON with the charge of the internal battery, read from macOS's
// power source information (IOKit). Shows nothing on a Mac without a battery.
import Foundation
import IOKit.ps

struct Widget: Encodable {
    let id: String
    let label: String
    let value: String
    let color: String
    let symbol: String
}
struct Frame: Encodable {
    let version = 1
    let widgets: [Widget]
}

struct Battery {
    var percent: Int
    var charging: Bool
    var external: Bool
    /// Minutes until empty (on battery) or full (charging); nil while macOS estimates.
    var minutes: Int?
}

let showTime = !CommandLine.arguments.contains("--no-time")

func battery() -> Battery? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              description[kIOPSIsPresentKey] as? Bool != false,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let external = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let minutes = (charging ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int
        return Battery(percent: min(100, max(0, current * 100 / maximum)), charging: charging,
                       external: external, minutes: minutes.flatMap { $0 > 0 ? $0 : nil })
    }
    return nil
}

func widget(_ battery: Battery) -> Widget {
    let level = battery.percent
    let symbol = battery.charging ? "battery.100.bolt"
        : battery.external ? "powerplug.fill"
        : level >= 88 ? "battery.100" : level >= 63 ? "battery.75"
        : level >= 38 ? "battery.50" : level >= 13 ? "battery.25" : "battery.0"
    let color = battery.charging || battery.external ? "50FA7B"
        : level <= 10 ? "FF5555" : level <= 20 ? "FFB86C" : "F8F8F2"
    var value = "\(level)%"
    // Remaining time on battery, time to full while charging; hidden when plugged in and full.
    if showTime, let minutes = battery.minutes, !battery.external || battery.charging {
        value += String(format: " %d:%02d", minutes / 60, minutes % 60)
    }
    return Widget(id: "battery", label: "", value: value, color: color, symbol: symbol)
}

let encoder = JSONEncoder()
while true {
    let widgets = battery().map { [widget($0)] } ?? []
    do {
        var data = try encoder.encode(Frame(widgets: widgets))
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch { exit(0) }
    // Charge changes slowly; the host expects a record at least every ten seconds.
    Thread.sleep(forTimeInterval: 5)
}
