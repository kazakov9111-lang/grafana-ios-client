import SwiftUI
import WidgetKit
import ActivityKit

import AppIntents

@main
struct GrafanaWidgets: WidgetBundle {
    var body: some Widget {
        ProblemLiveActivity()
        if #available(iOS 18.0, *) { ProblemsControl() }
        ProblemsHomeWidget()
    }
}

/// Кнопка в Пункте управления и на экране блокировки (iOS 18): открывает список проблем.
@available(iOS 18.0, *)
struct ProblemsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.personal.grafana.problems") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "grafanaapp://problems")!)) {
                Label("Проблемы", systemImage: "exclamationmark.triangle.fill")
            }
        }
        .displayName("Проблемы Zabbix")
        .description("Открыть список проблем в Grafana")
    }
}

private func sevColor(_ s: Int) -> Color {
    switch s {
    case 5...: return .red
    case 4: return Color(red: 1, green: 0.45, blue: 0.2)
    case 3: return .orange
    case 1...2: return .yellow
    default: return .green
    }
}

struct ProblemLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProblemActivityAttributes.self) { ctx in
            LockView(s: ctx.state)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(s.count)", systemImage: s.count == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title3.bold()).foregroundStyle(sevColor(s.severity))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.critical > 0 {
                        Text("\(s.critical) высоких").font(.caption.bold()).foregroundStyle(.red)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.worst).font(.caption).lineLimit(2)
                        HStack {
                            Text(s.worstHost).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            if s.count > 0 { Text(s.since, style: .timer).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: s.count == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(sevColor(s.severity))
            } compactTrailing: {
                Text("\(s.count)").font(.caption.bold()).foregroundStyle(sevColor(s.severity))
            } minimal: {
                Text("\(s.count)").font(.caption2.bold()).foregroundStyle(sevColor(s.severity))
            }
        }
    }
}

private struct LockView: View {
    let s: ProblemActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(sevColor(s.severity).opacity(0.25))
                Text("\(s.count)").font(.title2.bold()).foregroundStyle(sevColor(s.severity))
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.count == 0 ? "Проблем нет" : s.worst).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if !s.worstHost.isEmpty { Text(s.worstHost).lineLimit(1) }
                    if s.critical > 0 { Text("· высоких: \(s.critical)").foregroundStyle(.red) }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text("обновлено \(s.updated, style: .time)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
