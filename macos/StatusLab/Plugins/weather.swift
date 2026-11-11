// Compile: swiftc -O weather.swift -o weather
// Usage: weather --name Amsterdam --latitude 52.37 --longitude 4.89 [--fahrenheit] [--locale nl_NL]
// Emits protocol v1 NDJSON. Current conditions come from Open-Meteo (https://open-meteo.com),
// which needs no API key. Only the coordinates are sent; data refreshes every 15 minutes.
import Foundation

struct Widget: Encodable {
    let id: String
    let label: String
    let value: String
    let color: String
    /// SF Symbol drawn by the host before the value.
    var symbol: String?
}
struct Frame: Encodable {
    let version = 1
    let widgets: [Widget]
}

var name = "Weather"
var latitude: Double?
var longitude: Double?
var fahrenheit = false
var language = "en"
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    let value = arguments.first
    switch argument {
    case "--name": name = value ?? name; arguments = Array(arguments.dropFirst())
    case "--latitude": latitude = value.flatMap(Double.init); arguments = Array(arguments.dropFirst())
    case "--longitude": longitude = value.flatMap(Double.init); arguments = Array(arguments.dropFirst())
    case "--locale":
        language = value.map { String($0.prefix(2)) } ?? language
        arguments = Array(arguments.dropFirst())
    case "--fahrenheit": fahrenheit = true
    default: break
    }
}

struct Current: Decodable {
    let temperature_2m: Double
    let weather_code: Int
    let is_day: Int
    let wind_speed_10m: Double?
}
struct Response: Decodable { let current: Current }

/// WMO weather interpretation codes, as documented by Open-Meteo, with SF Symbols.
func describe(_ code: Int, day: Bool) -> (symbol: String, text: String, color: String) {
    switch code {
    case 0: return day ? ("sun.max.fill", "Clear", "F1FA8C") : ("moon.stars.fill", "Clear", "BD93F9")
    case 1, 2: return day ? ("cloud.sun.fill", "Partly cloudy", "F1FA8C") : ("cloud.moon.fill", "Partly cloudy", "BD93F9")
    case 3: return ("cloud.fill", "Overcast", "C0C5CE")
    case 45, 48: return ("cloud.fog.fill", "Fog", "C0C5CE")
    case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", "Drizzle", "8BE9FD")
    case 61, 63, 65, 66, 67, 80, 81, 82: return ("cloud.rain.fill", "Rain", "8BE9FD")
    case 71, 73, 75, 77, 85, 86: return ("cloud.snow.fill", "Snow", "FFFFFF")
    case 95, 96, 99: return ("cloud.bolt.rain.fill", "Thunderstorm", "FFB86C")
    default: return ("cloud.fill", "Unknown", "C0C5CE")
    }
}

/// Condition names for the locales we ship; anything else falls back to English.
let dutch = ["Clear": "Helder", "Partly cloudy": "Half bewolkt", "Overcast": "Bewolkt", "Fog": "Mist",
             "Drizzle": "Motregen", "Rain": "Regen", "Snow": "Sneeuw", "Thunderstorm": "Onweer",
             "Unknown": "Onbekend", "Loading…": "Laden…", "Unavailable": "Niet beschikbaar",
             "Set a location in Plugins": "Kies een locatie in Plugins", "Weather": "Weer"]

func localized(_ text: String) -> String { language == "nl" ? dutch[text] ?? text : text }

var latest: Widget?
var lastFetch: Date?
var fetching = false
let lock = NSLock()

func fetch() {
    guard let latitude, let longitude else { return }
    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    components.queryItems = [
        .init(name: "latitude", value: String(latitude)),
        .init(name: "longitude", value: String(longitude)),
        .init(name: "current", value: "temperature_2m,weather_code,is_day,wind_speed_10m"),
        .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        .init(name: "timezone", value: "auto"),
    ]
    lock.lock(); fetching = true; lock.unlock()
    let task = URLSession.shared.dataTask(with: components.url!) { data, _, _ in
        var widget: Widget?
        if let data, let response = try? JSONDecoder().decode(Response.self, from: data) {
            let current = response.current
            let info = describe(current.weather_code, day: current.is_day == 1)
            let temperature = String(format: "%.0f°%@", current.temperature_2m, fahrenheit ? "F" : "C")
            widget = Widget(id: "weather", label: String(name.prefix(32)),
                            value: "\(temperature) \(localized(info.text))", color: info.color, symbol: info.symbol)
        }
        lock.lock()
        if let widget { latest = widget }
        lastFetch = Date()
        fetching = false
        lock.unlock()
    }
    task.resume()
}

let encoder = JSONEncoder()
while true {
    lock.lock()
    // Retry failed requests after a minute, otherwise refresh every 15 minutes.
    let interval: TimeInterval = latest == nil ? 60 : 15 * 60
    let stale = lastFetch.map { Date().timeIntervalSince($0) > interval } ?? true
    let busy = fetching
    let widget = latest
    let failedRecently = lastFetch != nil && latest == nil
    lock.unlock()
    if stale && !busy { fetch() }

    let shown: Widget
    if latitude == nil || longitude == nil {
        shown = Widget(id: "weather", label: localized("Weather"), value: localized("Set a location in Plugins"),
                       color: "C0C5CE")
    } else if let widget {
        shown = widget
    } else {
        shown = Widget(id: "weather", label: String(name.prefix(32)),
                       value: localized(failedRecently ? "Unavailable" : "Loading…"), color: "C0C5CE")
    }
    do {
        var data = try encoder.encode(Frame(widgets: [shown]))
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch { exit(0) }
    // Heartbeat well within the host's ten-second limit.
    Thread.sleep(forTimeInterval: 5)
}
