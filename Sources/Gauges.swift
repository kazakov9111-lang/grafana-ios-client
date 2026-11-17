import SwiftUI
import Charts

// Графические элементы в стиле панелей Grafana: gauge, bar gauge, кольцо состояний.

/// Круговая шкала на 270° (панель Gauge).
struct RingGauge: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 7

    var body: some View {
        let f = min(max(fraction, 0.004), 1)
        ZStack {
            Circle().trim(from: 0.125, to: 0.875)
                .stroke(Color.white.opacity(0.09), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle().trim(from: 0.125, to: 0.125 + 0.75 * f)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .shadow(color: color.opacity(0.55), radius: 4)
        }
        .rotationEffect(.degrees(90))
    }
}

/// Горизонтальная шкала (панель Bar gauge).
struct BarGauge: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Кольцо из нескольких долей (общая «здоровость»).
struct SegmentRing: View {
    let segments: [(value: Double, color: Color)]
    var lineWidth: CGFloat = 9

    var body: some View {
        let total = max(segments.map { $0.value }.reduce(0, +), 0.0001)
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: lineWidth)
            ForEach(0..<segments.count, id: \.self) { i in
                let start = segments[..<i].map { $0.value }.reduce(0, +) / total
                let end = start + segments[i].value / total
                if segments[i].value > 0 {
                    Circle().trim(from: start, to: max(start + 0.002, end - (segments.count > 1 ? 0.012 : 0)))
                        .stroke(segments[i].color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
    }
}

/// Минимум / среднее / максимум под графиком (легенда-таблица Grafana).
struct SeriesStats: View {
    let series: Series
    var unit: String?

    var body: some View {
        let v = series.points.map(\.v)
        if let last = v.last, let mn = v.min(), let mx = v.max() {
            let avg = v.reduce(0, +) / Double(v.count)
            HStack(spacing: 0) {
                cell("сейчас", last)
                cell("мин", mn)
                cell("средн.", avg)
                cell("макс", mx)
            }
        }
    }

    private func cell(_ t: String, _ x: Double) -> some View {
        VStack(spacing: 1) {
            Text(formatValue(x, unit: unit)).font(.caption.weight(.semibold).monospacedDigit())
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
