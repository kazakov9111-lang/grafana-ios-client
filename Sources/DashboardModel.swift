import SwiftUI

enum TimeRange: String, CaseIterable, Identifiable {
    case m15, h1, h6, h24, d7
    var id: String { rawValue }
    var label: String {
        switch self {
        case .m15: return "15 минут"
        case .h1: return "1 час"
        case .h6: return "6 часов"
        case .h24: return "24 часа"
        case .d7: return "7 дней"
        }
    }
    var seconds: Double {
        switch self {
        case .m15: return 900
        case .h1: return 3600
        case .h6: return 21600
        case .h24: return 86400
        case .d7: return 604800
        }
    }
    var shortLabel: String {
        switch self {
        case .m15: return "15м"
        case .h1: return "1ч"
        case .h6: return "6ч"
        case .h24: return "24ч"
        case .d7: return "7д"
        }
    }
}

struct Pt: Identifiable {
    let id: Int
    let t: Date
    let v: Double
}

struct Series: Identifiable {
    var id: Int
    var name: String
    let points: [Pt]
    let text: String?
    let unit: String?
    var ref: String = ""
    var host: String = ""
    var item: String = ""
}

struct TableData {
    var columns: [String]
    var rows: [[String]]
}

struct PanelResult {
    var series: [Series] = []
    var table: TableData?
    var error: String?
}

/// Разбор ответа /api/ds/query в ряды.
enum DashboardModel {
    // MARK: разбор кадров

    static func parse(_ resp: JSON, wantTable: Bool) -> PanelResult {
        var res = PanelResult()
        var errors: [String] = []
        var sid = 0

        for (refId, r) in resp["results"].object.sorted(by: { $0.key < $1.key }) {
            if let e = r["error"].string { errors.append(e) }
            for frame in r["frames"].array {
                let fields = frame["schema"]["fields"].array
                let vals = frame["data"]["values"].array
                guard !fields.isEmpty, fields.count == vals.count else { continue }

                let hasTime = fields.contains { $0["type"].string == "time" }
                if wantTable && res.table == nil && !hasTime {
                    let rowCount = vals.map { $0.array.count }.max() ?? 0
                    var rows: [[String]] = []
                    for j in 0..<min(rowCount, 100) {
                        rows.append(fields.indices.map { i in
                            let cell = vals[i][j]
                            if fields[i]["type"].string == "time", let ms = cell.double {
                                let f = DateFormatter()
                                f.dateFormat = "dd.MM HH:mm"
                                return f.string(from: Date(timeIntervalSince1970: ms / 1000))
                            }
                            if case .number(let d) = cell { return d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d) }
                            return cell.string ?? ""
                        })
                    }
                    res.table = TableData(columns: fields.map { $0["name"].string ?? "" }, rows: rows)
                }

                let tIdx = fields.firstIndex { $0["type"].string == "time" }
                let times = tIdx.map { vals[$0].array } ?? []
                let frameName = frame["schema"]["name"].string ?? ""

                for (i, f) in fields.enumerated() where i != tIdx {
                    let type = f["type"].string ?? ""
                    let col = vals[i].array
                    var name = f["config"]["displayNameFromDS"].string
                        ?? f["config"]["displayName"].string ?? ""
                    if name.isEmpty {
                        let labels = f["labels"].object.sorted { $0.key < $1.key }.compactMap { $0.value.string }
                        if !labels.isEmpty { name = labels.joined(separator: " · ") }
                    }
                    if name.isEmpty {
                        let fn = f["name"].string ?? ""
                        name = (!frameName.isEmpty && (fn.lowercased() == "value" || fn.isEmpty)) ? frameName : fn
                    }
                    let unit = f["config"]["unit"].string

                    if type == "number" {
                        var pts: [Pt] = []
                        for (j, v) in col.enumerated() {
                            guard let d = v.double else { continue }
                            let t: Date = tIdx != nil
                                ? Date(timeIntervalSince1970: (times[safe: j]?.double ?? 0) / 1000)
                                : Date(timeIntervalSince1970: Double(j))
                            pts.append(Pt(id: pts.count, t: t, v: d))
                        }
                        if pts.count > 240 {
                            let step = Double(pts.count) / 240
                            var thin: [Pt] = []
                            var k = 0.0
                            while Int(k) < pts.count {
                                let p = pts[Int(k)]
                                thin.append(Pt(id: thin.count, t: p.t, v: p.v))
                                k += step
                            }
                            if let last = pts.last { thin.append(Pt(id: thin.count, t: last.t, v: last.v)) }
                            pts = thin
                        }
                        res.series.append(Series(id: sid, name: name, points: pts, text: nil, unit: unit, ref: refId,
                                                 host: f["labels"]["host"].string ?? "",
                                                 item: f["labels"]["item"].string ?? f["config"]["displayNameFromDS"].string ?? ""))
                        sid += 1
                    } else if type == "string" || type == "boolean" {
                        if let last = col.last(where: { !$0.isNull })?.string {
                            res.series.append(Series(id: sid, name: name, points: [], text: last, unit: unit, ref: refId))
                            sid += 1
                        }
                    }
                }
            }
        }
        // имя ряда: хост, а если по запросу несколько показателей — «хост: показатель»
        let byRef = Dictionary(grouping: res.series.indices, by: { res.series[$0].ref })
        for (_, idx) in byRef {
            let items = Set(idx.map { res.series[$0].item })
            for i in idx where !res.series[i].host.isEmpty {
                res.series[i].name = items.count > 1 ? "\(res.series[i].host): \(res.series[i].item)" : res.series[i].host
            }
        }
        if res.series.isEmpty && res.table == nil, !errors.isEmpty { res.error = errors.joined(separator: "; ") }
        return res
    }
}
