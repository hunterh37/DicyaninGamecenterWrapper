import SwiftUI

// Shared multiplayer debug UI used by both the visionOS and iOS targets.
// Platform-neutral styling (materials, no glassBackgroundEffect) so it renders
// identically on iPhone and Vision Pro.

// Custom matchmaking loading view. Replaces the bare ProgressView so a stuck
// search is obvious and always cancellable.
public struct MatchmakingOverlay: View {

    public let onCancel: () -> Void

    public init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    @State private var spin = false
    @State private var elapsed = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 6)
                    .frame(width: 72, height: 72)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(
                        Color(red: 0.55, green: 0.75, blue: 0.95),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            }

            VStack(spacing: 4) {
                Text("Finding a match")
                    .font(.title3.weight(.semibold))
                Text("\(elapsed)s elapsed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if elapsed >= 12 {
                    Text("Still searching. Needs a second signed-in player in the same group.")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 260)
                }
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .onAppear { spin = true }
        .onReceive(tick) { _ in elapsed += 1 }
    }
}

// Scrollable in-app debug console for the multiplayer core, with copy + clear.
public struct DebugConsoleView: View {

    @ObservedObject public var log: MultiplayerLog
    @State private var copied = false

    public init(log: MultiplayerLog) {
        self.log = log
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                Text("Multiplayer Console")
                    .font(.caption.weight(.semibold))
                Text("\(log.entries.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = log.joined
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button {
                    log.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if log.entries.isEmpty {
                            Text("No events yet.")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        }
                        ForEach(log.entries) { entry in
                            Text(entry.line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .frame(height: 180)
                .onChange(of: log.entries.count) { _, _ in
                    if let last = log.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(12)
    }

    private func color(for level: MultiplayerLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
