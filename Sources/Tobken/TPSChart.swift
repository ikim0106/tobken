import SwiftUI
import TobkenCore

struct TPSChart: View {
    let history: TPSHistory
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .trailing) {
                    Text(MetricFormat.rate(history.ceiling))
                    Spacer(minLength: 0)
                    Text("0")
                }.foregroundStyle(.secondary).monospacedDigit()
                GeometryReader { geometry in
                    let rect = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 2, dy: 2)
                    let points = coordinates(in: rect)
                    Path { path in
                        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    }.stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    Path { path in
                        var previous: Date?
                        for (sample, point) in zip(history.samples, points) {
                            guard let point else { previous = nil; continue }
                            if let previous, sample.time.timeIntervalSince(previous) <= 2 {
                                path.addLine(to: point)
                            } else { path.move(to: point) }
                            previous = sample.time
                        }
                    }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    if let point = points.last ?? nil {
                        Circle().fill(color).frame(width: 4, height: 4).position(point)
                    }
                }
            }.frame(height: 28)
            HStack {
                Text("60s ago")
                Spacer()
                Text("Now")
            }.foregroundStyle(.secondary)
        }
        .font(.system(size: 9))
        .frame(width: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current TPS readings over the last 60 seconds, scale 0 to \(MetricFormat.rate(history.ceiling)) TPS")
        .help("The same trailing 5-second observed TPS shown on the left, sampled once a second during activity. Quiet time counts as zero. The dot is the latest reading. Past readings stay fixed; gaps mean no reading. The scale stays fixed during activity and grows for new peaks.")
    }

    private func coordinates(in rect: CGRect) -> [CGPoint?] {
        guard let now = history.samples.last?.time else { return [] }
        return history.samples.map { sample in
            guard let value = sample.value else { return nil }
            let age = now.timeIntervalSince(sample.time)
            return CGPoint(x: rect.maxX - age / TPSHistory.duration * rect.width,
                           y: rect.maxY - value / history.ceiling * rect.height)
        }
    }
}
