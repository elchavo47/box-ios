import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BoxActivityBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

private let accent = Color(red: 0.12, green: 0.84, blue: 0.38)

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(s.done)/\(s.total)")
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.status)
                        .font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !s.title.isEmpty {
                            Text(s.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ProgressView(value: s.progress)
                            .tint(accent)
                    }
                }
            } compactLeading: {
                Image(systemName: s.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text("\(s.done)/\(s.total)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            } minimal: {
                ProgressView(value: s.progress)
                    .progressViewStyle(.circular)
                    .tint(accent)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(accent)
                Text(state.status)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(state.done)/\(state.total)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            if !state.title.isEmpty {
                Text(state.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProgressView(value: state.progress)
                .tint(accent)
        }
        .padding(16)
    }
}
