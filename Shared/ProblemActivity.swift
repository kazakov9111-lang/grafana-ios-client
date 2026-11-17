import Foundation
import ActivityKit

/// Данные Live Activity: общие для приложения и расширения виджетов.
struct ProblemActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var count: Int
        var critical: Int
        var worst: String
        var worstHost: String
        var severity: Int
        var since: Date
        var updated: Date
    }

    var title: String
}
