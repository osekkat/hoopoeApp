import Charts
import SwiftUI

// MARK: - Convergence Meter View

/// Visual convergence meter showing how much a plan has stabilized between refinement rounds.
///
/// Displays a circular gauge with color gradient, a history chart of convergence scores
/// across rounds, and a per-metric breakdown. The 0.75 threshold marks the recommended
/// stopping point per the Flywheel methodology.
struct ConvergenceMeterView: View {
    let plan: PlanDocument
    let tracker: ConvergenceTracker

    @State private var showsBreakdown = false
    @State private var showConvergedBanner = false

    private var allMetrics: [ConvergenceVersionPairMetrics] {
        tracker.computeAllMetrics(for: plan)
    }

    private var latestScore: Double? {
        tracker.latestConvergenceScore(for: plan)
    }

    var body: some View {
        VStack(spacing: 12) {
            if plan.versions.count < 2 {
                notEnoughDataView
            } else {
                gaugeSection
                if allMetrics.count >= 2 {
                    historyChart
                }
                breakdownSection
            }
        }
        .padding(12)
        .overlay(alignment: .top) {
            if showConvergedBanner {
                convergedBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: latestScore) { _, newValue in
            if let score = newValue, score >= 0.75, !showConvergedBanner {
                withAnimation(.easeInOut(duration: 0.4)) {
                    showConvergedBanner = true
                }
            }
        }
    }

    // MARK: - Not Enough Data

    private var notEnoughDataView: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("Not enough data")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Refine the plan at least once to see convergence metrics.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Gauge Section

    private var gaugeSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Convergence")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let score = latestScore {
                    Text(scoreLabel(score))
                        .font(.caption)
                        .foregroundStyle(scoreColor(score))
                }
            }

            ZStack {
                // Background arc
                ArcShape(startAngle: .degrees(135), endAngle: .degrees(405))
                    .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 10, lineCap: .round))

                // Colored arc
                if let score = latestScore {
                    ArcShape(
                        startAngle: .degrees(135),
                        endAngle: .degrees(135 + 270 * score)
                    )
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [.red, .orange, .yellow, .green]),
                            center: .center,
                            startAngle: .degrees(135),
                            endAngle: .degrees(405)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )

                    // Threshold tick at 0.75
                    ThresholdTick(angle: .degrees(135 + 270 * 0.75))
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                }

                // Score text
                VStack(spacing: 2) {
                    if let score = latestScore {
                        Text("\(Int(score * 100))")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(scoreColor(score))
                        Text("/ 100")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 120, height: 90)

            // Threshold label
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 4, height: 4)
                Text("75 = recommended stop")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - History Chart

    private var historyChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("History")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(Array(allMetrics.enumerated()), id: \.offset) { index, metrics in
                    LineMark(
                        x: .value("Round", metrics.currentRoundNumber),
                        y: .value("Score", metrics.compositeScore)
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Round", metrics.currentRoundNumber),
                        y: .value("Score", metrics.compositeScore)
                    )
                    .foregroundStyle(scoreColor(metrics.compositeScore))
                    .symbolSize(30)
                }

                // Threshold line
                RuleMark(y: .value("Threshold", 0.75))
                    .foregroundStyle(.green.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("0.75")
                            .font(.system(size: 9))
                            .foregroundStyle(.green.opacity(0.6))
                    }
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.25, 0.5, 0.75, 1.0]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v * 100))")
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("R\(v)")
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: 100)
        }
    }

    // MARK: - Breakdown Section

    private var breakdownSection: some View {
        DisclosureGroup("Metrics", isExpanded: $showsBreakdown) {
            if let metrics = allMetrics.last {
                VStack(spacing: 6) {
                    metricRow(
                        label: "Size Delta",
                        value: metrics.sizeDelta,
                        description: "Word count change",
                        inverted: true
                    )
                    metricRow(
                        label: "Velocity",
                        value: metrics.changeVelocity,
                        description: "Lines changed",
                        inverted: true
                    )
                    metricRow(
                        label: "Similarity",
                        value: metrics.contentSimilarity,
                        description: "Word overlap",
                        inverted: false
                    )
                }
                .padding(.top, 4)
            }
        }
        .font(.caption)
    }

    private func metricRow(label: String, value: Double, description: String, inverted: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(.medium))
                Text(description)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 80, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(metricBarColor(value: value, inverted: inverted))
                        .frame(width: geo.size.width * min(value, 1.0))
                }
            }
            .frame(height: 6)

            Text(String(format: "%.2f", value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    // MARK: - Converged Banner

    private var convergedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Plan has converged")
                .font(.caption.weight(.medium))
            Spacer()
            Button {
                withAnimation { showConvergedBanner = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case ..<0.3: return .red
        case 0.3..<0.5: return .orange
        case 0.5..<0.75: return .yellow
        default: return .green
        }
    }

    private func scoreLabel(_ score: Double) -> String {
        switch score {
        case ..<0.3: return "Diverging"
        case 0.3..<0.5: return "Evolving"
        case 0.5..<0.75: return "Stabilizing"
        default: return "Converged"
        }
    }

    private func metricBarColor(value: Double, inverted: Bool) -> Color {
        let effective = inverted ? (1.0 - min(value, 1.0)) : value
        switch effective {
        case ..<0.3: return .red.opacity(0.6)
        case 0.3..<0.6: return .orange.opacity(0.6)
        case 0.6..<0.8: return .yellow.opacity(0.6)
        default: return .green.opacity(0.6)
        }
    }
}

// MARK: - Arc Shape

/// A circular arc used for the gauge background and fill.
private struct ArcShape: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}

// MARK: - Threshold Tick

/// A small radial tick mark at a specific angle on the gauge.
private struct ThresholdTick: Shape {
    let angle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let innerRadius = radius - 7
        let outerRadius = radius + 7

        let cosA = cos(angle.radians)
        let sinA = sin(angle.radians)

        path.move(to: CGPoint(
            x: center.x + innerRadius * cosA,
            y: center.y + innerRadius * sinA
        ))
        path.addLine(to: CGPoint(
            x: center.x + outerRadius * cosA,
            y: center.y + outerRadius * sinA
        ))
        return path
    }
}

// MARK: - Preview

#Preview("With Data") {
    let planId = UUID()
    let plan = PlanDocument(
        id: planId,
        title: "Preview Plan",
        content: "# Final refined plan content",
        versions: [
            PlanVersion(planId: planId, content: "# Draft\n\nInitial rough idea about building something.", roundNumber: 1, changeDescription: "Initial"),
            PlanVersion(planId: planId, content: "# Draft\n\nRefined idea about building a web app with React.", roundNumber: 2, changeDescription: "Round 2"),
            PlanVersion(planId: planId, content: "# Plan\n\nRefined idea about building a web app with React and Node.", roundNumber: 3, changeDescription: "Round 3"),
            PlanVersion(planId: planId, content: "# Plan\n\nRefined idea about building a web app with React and Node.js backend.", roundNumber: 4, changeDescription: "Round 4"),
        ]
    )
    ConvergenceMeterView(plan: plan, tracker: ConvergenceTracker())
        .frame(width: 220)
        .padding()
}

#Preview("No Data") {
    let plan = PlanDocument(title: "Empty Plan", content: "# Draft")
    ConvergenceMeterView(plan: plan, tracker: ConvergenceTracker())
        .frame(width: 220)
        .padding()
}
