import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BoxActivityBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        DownloadLiveActivity()
    }
}

private let green = Color(red: 0.12, green: 0.84, blue: 0.38)
private let mint = Color(red: 0.45, green: 0.95, blue: 0.80)
private let warn = Color(red: 1.0, green: 0.62, blue: 0.20)
private let gradient = LinearGradient(colors: [green, mint], startPoint: .leading, endPoint: .trailing)

/// Yüzdeli dairesel ilerleme halkası.
private struct Ring: View {
    let progress: Double
    let finished: Bool
    var size: CGFloat = 44
    var line: CGFloat = 4.5
    var showsPercent = true

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(AngularGradient(colors: [green, mint, green], center: .center), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if finished {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(green)
            } else if showsPercent {
                Text("\(Int(progress * 100))")
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// İnce kapsül ilerleme çubuğu.
private struct Bar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(gradient)
                    .frame(width: max(6, geo.size.width * min(1, progress)))
            }
        }
        .frame(height: 6)
    }
}

private struct FailChip: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(count)").monospacedDigit()
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(warn)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(warn.opacity(0.16), in: Capsule())
    }
}

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(red: 0.04, green: 0.07, blue: 0.05).opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Ring(progress: s.progress, finished: s.finished, size: 46)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(s.done)")
                                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                            Text("/\(s.total)")
                                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        if s.failed > 0 { FailChip(count: s.failed) }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(s.status)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        if !s.title.isEmpty {
                            Text(s.title)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Bar(progress: s.progress)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Ring(progress: s.progress, finished: s.finished, size: 20, line: 2.6, showsPercent: false)
            } compactTrailing: {
                Text("\(s.done)/\(s.total)")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(s.finished ? green : .white)
            } minimal: {
                Ring(progress: s.progress, finished: s.finished, size: 22, line: 2.8, showsPercent: false)
            }
            .keylineTint(green)
        }
    }
}

private struct LockScreenView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Ring(progress: state.progress, finished: state.finished, size: 52, line: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.status)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(state.title.isEmpty ? "Box" : state.title)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(state.done)")
                            .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("/\(state.total)")
                            .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    if state.failed > 0 { FailChip(count: state.failed) }
                }
            }
            Bar(progress: state.progress)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}
