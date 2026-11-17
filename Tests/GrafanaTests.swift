import XCTest
@testable import Grafana

/// Быстрые проверки логики, которую легко сломать: разбор ответов, прогноз, зависимости.
final class GrafanaTests: XCTestCase {
    func testForecastFollowsTrend() throws {
        let t0 = Date().addingTimeInterval(-7 * 86400)
        let pts = (0..<168).map { Pt(id: $0, t: t0.addingTimeInterval(Double($0) * 3600), v: 20 + Double($0) * 0.3) }
        let s = Series(id: 1, name: "HOST", points: pts, text: nil, unit: nil)
        let f = try XCTUnwrap(Forecaster.run(s))
        XCTAssertEqual(f.slopePerDay, 7.2, accuracy: 0.1)
        XCTAssertEqual(f.forecast.count, 168)
        XCTAssertGreaterThan(f.forecast.last!.v, f.forecast.first!.v)
    }

    func testHostLevels() {
        let now = Date()
        let ps = [Problem(id: "1", triggerId: "1", name: "a", severity: 3, clock: now, acked: false, host: "A"),
                  Problem(id: "2", triggerId: "2", name: "b", severity: 5, clock: now, acked: false, host: "A"),
                  Problem(id: "3", triggerId: "3", name: "c", severity: 2, clock: now, acked: false, host: "B")]
        let l = hostLevels(ps)
        XCTAssertEqual(l["A"], .bad)
        XCTAssertEqual(l["B"], .warn)
    }

    func testParseFrames() {
        let resp: JSON = .object(["results": .object(["A": .object(["frames": .array([.object([
            "schema": .object(["fields": .array([.object(["name": .string("time"), "type": .string("time")]),
                                                 .object(["name": .string("CPU"), "type": .string("number")])])]),
            "data": .object(["values": .array([.array([.number(1_700_000_000_000), .number(1_700_000_060_000)]),
                                               .array([.number(10), .number(20)])])])
        ])])])])])
        let r = DashboardModel.parse(resp, wantTable: false)
        XCTAssertEqual(r.series.count, 1)
        XCTAssertEqual(r.series.first?.points.map(\.v), [10, 20])
    }

    func testTemplatingAll() {
        let dash: JSON = .object(["templating": .object(["list": .array([
            .object(["name": .string("grp"), "current": .object(["value": .string("$__all")])]),
            .object(["name": .string("host"), "current": .object(["value": .array([.string("A"), .string("B")])])])
        ])])])
        let v = DashTemplating.vars(dash)
        XCTAssertEqual(v["grp"], "/.*/")
        XCTAssertEqual(v["host"], "/^(A|B)$/")
        let t = DashTemplating.apply(.object(["group": .object(["filter": .string("$grp")])]), v)
        XCTAssertEqual(t["group"]["filter"].string, "/.*/")
    }

    func testExcludedOnlyWhenAllGroupsExcluded() {
        let p = Problem(id: "1", triggerId: "1", name: "x", severity: 4, clock: Date(), acked: false, host: "h",
                        tags: nil, groups: ["Workstations", "Office"])
        XCTAssertFalse(ProblemFilters.isExcluded(p, ["Workstations"]))
        XCTAssertTrue(ProblemFilters.isExcluded(p, ["Workstations", "Office"]))
        let noGroups = Problem(id: "2", triggerId: "2", name: "y", severity: 4, clock: Date(), acked: false, host: "h")
        XCTAssertFalse(ProblemFilters.isExcluded(noGroups, ["Workstations"]))
    }

    func testDashVarValue() {
        var v = DashVar(name: "h", label: "Хост", options: ["A", "B"], multi: true, includeAll: true, selected: ["$__all"])
        XCTAssertEqual(v.value, "/.*/")
        v.selected = ["A"]
        XCTAssertEqual(v.value, "A")
        v.selected = ["A", "B"]
        XCTAssertEqual(v.value, "/^(A|B)$/")
        XCTAssertEqual(v.display, "2 выбрано")
    }

    func testRedaction() {
        let r = BugReport.redact("Сервер https://grafana.corp.example/x, 10.1.2.3, a.b@corp.example, user ivanov",
                                 server: "https://grafana.corp.example", user: "ivanov")
        XCTAssertFalse(r.contains("10.1.2.3"))
        XCTAssertFalse(r.contains("a.b@corp.example"))
        XCTAssertFalse(r.contains("ivanov"))
        XCTAssertFalse(r.contains("grafana.corp.example"))
    }

    func testStatusPageCategories() {
        let ps = [Problem(id: "1", triggerId: "1", name: "Exchange: очередь растёт", severity: 4, clock: Date(), acked: false, host: "MBX1")]
        let l = StatusPage.lines(ps)
        XCTAssertEqual(l.first { $0.title == "Почта" }?.state, 2)
        XCTAssertEqual(l.first { $0.title.hasPrefix("Файлы") }?.state, 0)
    }

    func testAckTextBits() {
        let (t, _, _) = ProblemTimelineSection.ackText(2 | 4, .object([:]))
        XCTAssertEqual(t, "подтвердил")
        let (t2, _, _) = ProblemTimelineSection.ackText(1, .object([:]))
        XCTAssertEqual(t2, "закрыл")
    }

    func testQuietWindowWrapsMidnight() {
        UserDefaults.standard.set(true, forKey: "quietOn")
        UserDefaults.standard.set(23, forKey: "quietFrom")
        UserDefaults.standard.set(7, forKey: "quietTo")
        defer { UserDefaults.standard.removeObject(forKey: "quietOn") }
        let cal = Calendar.current
        XCTAssertTrue(QuietHours.isQuiet(cal.date(bySettingHour: 2, minute: 0, second: 0, of: Date())!))
        XCTAssertFalse(QuietHours.isQuiet(cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!))
    }
}
