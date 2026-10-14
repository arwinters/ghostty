// Compile: swiftc -O clock.swift -o clock
// Usage: clock [--template "EEE d MMM yyyy HH:mm"] [--locale nl_NL]
// Emits protocol v1 NDJSON with the current day, date and time. The template uses
// Unicode date symbols; the locale decides order and punctuation.
import Foundation

struct Widget: Encodable {
    let id: String
    let label: String
    let value: String
    let color: String
}
struct Frame: Encodable {
    let version = 1
    let widgets: [Widget]
}

var template = "EEE d MMM yyyy HH:mm"
var locale = Locale.current
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    guard let value = arguments.first else { break }
    switch argument {
    case "--template": template = value; arguments.removeFirst()
    case "--locale": locale = Locale(identifier: value); arguments.removeFirst()
    default: break
    }
}

let formatter = DateFormatter()
formatter.locale = locale
formatter.setLocalizedDateFormatFromTemplate(template)
let encoder = JSONEncoder()

while true {
    let value = String(formatter.string(from: Date()).prefix(64))
    do {
        var data = try encoder.encode(Frame(widgets: [Widget(id: "clock", label: "", value: value, color: "F8F8F2")]))
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch { exit(0) }
    // Wake just after the next second boundary so the display never lags.
    let now = Date().timeIntervalSince1970
    Thread.sleep(forTimeInterval: max(0.05, 1.02 - (now - now.rounded(.down))))
}
