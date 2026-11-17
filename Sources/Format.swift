import SwiftUI

// MARK: Цвета Grafana

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: String(s.prefix(6))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 255) / 255,
                  green: Double((v >> 8) & 255) / 255,
                  blue: Double(v & 255) / 255)
    }
}

func gfColor(_ name: String?) -> Color {
    guard var n = name?.lowercased(), !n.isEmpty else { return Color(hex: "73BF69") }
    if n.hasPrefix("#") { return Color(hex: n) }
    if n.hasPrefix("rgb") {
        let nums = n.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        if nums.count >= 3 {
            return Color(red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255)
                .opacity(nums.count > 3 ? nums[3] : 1)
        }
    }
    for p in ["super-light-", "light-", "semi-dark-", "dark-"] where n.hasPrefix(p) {
        n = String(n.dropFirst(p.count))
    }
    switch n {
    case "green": return Color(hex: "73BF69")
    case "red": return Color(hex: "F2495C")
    case "yellow": return Color(hex: "FADE2A")
    case "orange": return Color(hex: "FF9830")
    case "blue": return Color(hex: "5794F2")
    case "purple": return Color(hex: "B877D9")
    case "text", "white": return .white
    case "transparent": return .clear
    default: return Color(hex: "8E8E93")
    }
}

let seriesPalette: [Color] = [
    "7EB26D", "EAB839", "6ED0E0", "EF843C", "E24D42", "1F78C1",
    "BA43A9", "705DA0", "508642", "CCA300", "447EBC", "C15C17"
].map { Color(hex: $0) }

// MARK: Форматирование значений

private func trimmed(_ v: Double, decimals: Int?) -> String {
    let d: Int
    if let decimals { d = decimals }
    else if abs(v) >= 100 || v == v.rounded() { d = 0 }
    else if abs(v) >= 10 { d = 1 }
    else { d = 2 }
    return String(format: "%.\(d)f", v)
}

private func scaled(_ v: Double, base: Double, suffixes: [String], decimals: Int?) -> String {
    var x = abs(v)
    var i = 0
    while x >= base && i < suffixes.count - 1 { x /= base; i += 1 }
    let sign = v < 0 ? "-" : ""
    let d = decimals ?? (x >= 100 ? 0 : (x >= 10 ? 1 : 2))
    return sign + String(format: "%.\(d)f", x) + suffixes[i]
}

func formatValue(_ v: Double, unit: String?, decimals: Int? = nil) -> String {
    switch unit ?? "" {
    case "percent": return trimmed(v, decimals: decimals) + "%"
    case "percentunit": return trimmed(v * 100, decimals: decimals) + "%"
    case "bytes", "deckbytes": return scaled(v, base: 1024, suffixes: [" Б", " КиБ", " МиБ", " ГиБ", " ТиБ", " ПиБ"], decimals: decimals)
    case "decbytes": return scaled(v, base: 1000, suffixes: [" Б", " КБ", " МБ", " ГБ", " ТБ", " ПБ"], decimals: decimals)
    case "kbytes": return scaled(v * 1024, base: 1024, suffixes: [" Б", " КиБ", " МиБ", " ГиБ", " ТиБ", " ПиБ"], decimals: decimals)
    case "mbytes": return scaled(v * 1_048_576, base: 1024, suffixes: [" Б", " КиБ", " МиБ", " ГиБ", " ТиБ", " ПиБ"], decimals: decimals)
    case "gbytes": return scaled(v * 1_073_741_824, base: 1024, suffixes: [" Б", " КиБ", " МиБ", " ГиБ", " ТиБ", " ПиБ"], decimals: decimals)
    case "bits": return scaled(v, base: 1000, suffixes: [" бит", " Кбит", " Мбит", " Гбит", " Тбит"], decimals: decimals)
    case "bps": return scaled(v, base: 1000, suffixes: [" бит/с", " Кбит/с", " Мбит/с", " Гбит/с", " Тбит/с"], decimals: decimals)
    case "Bps": return scaled(v, base: 1000, suffixes: [" Б/с", " КБ/с", " МБ/с", " ГБ/с", " ТБ/с"], decimals: decimals)
    case "short": return scaled(v, base: 1000, suffixes: ["", " К", " М", " Млрд", " Трлн"], decimals: decimals)
    case "s": return duration(seconds: v)
    case "ms": return duration(seconds: v / 1000)
    case "m": return duration(seconds: v * 60)
    case "h": return duration(seconds: v * 3600)
    case "d": return duration(seconds: v * 86400)
    case "celsius": return trimmed(v, decimals: decimals) + " °C"
    case "ops": return trimmed(v, decimals: decimals) + " оп/с"
    case "none", "": return trimmed(v, decimals: decimals)
    default:
        if v == v.rounded() || decimals != nil { return trimmed(v, decimals: decimals) }
        return trimmed(v, decimals: decimals)
    }
}

func duration(seconds: Double) -> String {
    let s = abs(seconds)
    let sign = seconds < 0 ? "-" : ""
    if s < 1 { return sign + String(format: "%.0f мс", s * 1000) }
    if s < 60 { return sign + String(format: "%.1f с", s) }
    if s < 3600 { return sign + String(format: "%.0f мин", s / 60) }
    if s < 86400 {
        let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        return sign + "\(h) ч" + (m > 0 ? " \(m) мин" : "")
    }
    let d = Int(s / 86400), h = Int(s.truncatingRemainder(dividingBy: 86400) / 3600)
    return sign + "\(d) дн" + (h > 0 ? " \(h) ч" : "")
}

// MARK: Пороги и преобразования значений

struct FieldStyle {
    var unit: String?
    var decimals: Int?
    var min: Double?
    var max: Double?
    var thresholds: [(value: Double?, color: String)]
    var mappings: [JSON]

    init(panel: JSON, unit fallbackUnit: String? = nil) {
        let d = panel["fieldConfig"]["defaults"]
        unit = d["unit"].string ?? fallbackUnit
        decimals = d["decimals"].int
        min = d["min"].double
        max = d["max"].double
        thresholds = d["thresholds"]["steps"].array.map { ($0["value"].double, $0["color"].string ?? "green") }
        if thresholds.isEmpty { thresholds = [(nil, "green")] }
        mappings = d["mappings"].array
    }

    func color(for v: Double?) -> Color {
        guard let v else { return gfColor("text") }
        var picked = thresholds.first?.color
        for step in thresholds {
            if let sv = step.value { if v >= sv { picked = step.color } } else { picked = step.color }
        }
        return gfColor(picked)
    }

    /// Текст и цвет значения с учётом value mappings.
    func display(_ v: Double?, text: String? = nil) -> (text: String, color: Color) {
        if let m = mapped(v, text: text) { return m }
        if let v { return (formatValue(v, unit: unit, decimals: decimals), color(for: v)) }
        if let text { return (text, gfColor("text")) }
        return ("нет данных", .gray)
    }

    private func mapped(_ v: Double?, text: String?) -> (text: String, color: Color)? {
        let key: String? = v.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? text
        for m in mappings {
            switch m["type"].string {
            case "value":
                if let key, let hit = m["options"][key].isObject ? m["options"][key] : nil {
                    return (hit["text"].string ?? key, gfColor(hit["color"].string))
                }
            case "range":
                if let v {
                    let from = m["options"]["from"].double ?? -.infinity
                    let to = m["options"]["to"].double ?? .infinity
                    if v >= from && v <= to {
                        let r = m["options"]["result"]
                        return (r["text"].string ?? formatValue(v, unit: unit), gfColor(r["color"].string))
                    }
                }
            default: break
            }
        }
        return nil
    }
}
