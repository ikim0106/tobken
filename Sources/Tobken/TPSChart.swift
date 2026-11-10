import SwiftUI
import TobkenCore

/// Current TPS over the last minute: a smoothed area with no axes. The scale follows the minute's peak (which the
/// caption names) and eases when it changes; hovering reads out any second.
struct TPSChart: View {
    let history: TPSHistory
    let color: Color
    @State private var hoverIndex: Int?

    static let height: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                let size = geometry.size
                let points = normalizedPoints
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height - 0.5))
                        path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                    }.stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    TPSCurve(points: points, ceiling: history.ceiling, closed: true)
                        .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                    TPSCurve(points: points, ceiling: history.ceiling, closed: false)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    if let index = hoverIndex ?? lastKnownIndex, let point = points[index] {
                        let location = position(point, in: size)
                        if hoverIndex != nil {
                            Path { path in
                                path.move(to: CGPoint(x: location.x, y: 0))
                                path.addLine(to: CGPoint(x: location.x, y: size.height))
                            }.stroke(Color.primary.opacity(0.25), lineWidth: 1)
                        }
                        Circle().fill(color).frame(width: 5, height: 5).position(location)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: history.ceiling)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverIndex = nearestIndex(to: location.x, width: size.width)
                    case .ended: hoverIndex = nil
                    }
                }
            }
            .frame(height: Self.height)
            caption
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current TPS over the last minute")
        .accessibilityValue(history.peak.map { "Peak \(MetricFormat.rate($0)) TPS" } ?? "No readings yet")
        .help("Current TPS at each second of the last minute: output placed across the time it was generated, averaged over 30 seconds. Most tools log usage when a response finishes, so recent seconds fill in then. Gaps mean no reading.")
    }

    @ViewBuilder private var caption: some View {
        HStack {
            if let index = hoverIndex, history.samples.indices.contains(index) {
                let sample = history.samples[index]
                let age = Int((history.samples.last?.time ?? sample.time).timeIntervalSince(sample.time).rounded())
                Text(sample.value.map { "\(MetricFormat.rate($0)) TPS" } ?? "No reading")
                Spacer()
                Text(age == 0 ? "now" : "\(age) s ago")
            } else {
                Text("Last minute")
                Spacer()
                if let peak = history.peak, peak > 0 {
                    Text("peak \(MetricFormat.rate(peak)) TPS")
                } else if history.peak == 0 {
                    Text("no output")
                } else {
                    Text("waiting for readings")
                }
            }
        }
        .font(.system(size: MenuMetrics.captionFont))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    /// Each sample as (fraction of the minute from the left, value), aligned so the latest sits at the right edge.
    private var normalizedPoints: [TPSCurve.Point?] {
        guard let end = history.samples.last?.time else { return [] }
        return history.samples.map { sample in
            sample.value.map { TPSCurve.Point(x: 1 - end.timeIntervalSince(sample.time) / TPSHistory.duration, value: $0) }
        }
    }

    private var lastKnownIndex: Int? { history.samples.lastIndex { $0.value != nil } }

    private func position(_ point: TPSCurve.Point, in size: CGSize) -> CGPoint {
        TPSCurve.position(point, ceiling: history.ceiling, in: CGRect(origin: .zero, size: size))
    }

    private func nearestIndex(to x: CGFloat, width: CGFloat) -> Int? {
        guard width > 0 else { return nil }
        let fraction = x / width
        return normalizedPoints.indices.min { lhs, rhs in
            abs((normalizedPoints[lhs]?.x ?? -10) - fraction) < abs((normalizedPoints[rhs]?.x ?? -10) - fraction)
        }
    }
}

/// The line (or the area under it), smoothed through midpoints so it never overshoots below zero or above a
/// reading. Segments break at unknown readings. The ceiling animates, so scale changes ease instead of jumping.
struct TPSCurve: Shape {
    struct Point: Equatable {
        var x: Double
        var value: Double
    }

    var points: [Point?]
    var ceiling: Double
    var closed: Bool

    var animatableData: Double {
        get { ceiling }
        set { ceiling = newValue }
    }

    static func position(_ point: Point, ceiling: Double, in rect: CGRect) -> CGPoint {
        let inset = rect.insetBy(dx: 2.5, dy: 2.5)
        let y = inset.maxY - min(point.value / max(ceiling, 0.0001), 1) * inset.height
        return CGPoint(x: inset.minX + point.x * inset.width, y: y)
    }

    func path(in rect: CGRect) -> Path {
        var segments: [[CGPoint]] = [[]]
        for point in points {
            if let point { segments[segments.count - 1].append(Self.position(point, ceiling: ceiling, in: rect)) }
            else if !(segments.last?.isEmpty ?? true) { segments.append([]) }
        }
        var path = Path()
        let baseline = rect.maxY - 0.5
        for segment in segments where !segment.isEmpty {
            if closed {
                path.move(to: CGPoint(x: segment[0].x, y: baseline))
                path.addLine(to: segment[0])
            } else {
                path.move(to: segment[0])
            }
            for index in segment.indices.dropFirst() {
                let previous = segment[index - 1]
                let mid = CGPoint(x: (previous.x + segment[index].x) / 2, y: (previous.y + segment[index].y) / 2)
                path.addQuadCurve(to: mid, control: previous)
            }
            if let last = segment.last {
                path.addLine(to: last)
                if closed {
                    path.addLine(to: CGPoint(x: last.x, y: baseline))
                    path.closeSubpath()
                }
            }
        }
        return path
    }
}
