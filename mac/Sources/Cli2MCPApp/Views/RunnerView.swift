import SwiftUI

struct RunnerView: View {
    // Visible transcript window: tall enough to show a typical handshake
    // (~6 log lines) without scrolling, capped so the runner card doesn't
    // dominate the detail pane on tall windows. Beyond this, the inner
    // ScrollView takes over.
    private static let transcriptMinHeight: CGFloat = 220
    private static let transcriptMaxHeight: CGFloat = 360

    let preset: CliPreset
    let runtime: NativeRuntime
    @ObservedObject var runner: McpRunner
    let forwardEnvironment: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if runner.isRunning {
                    Button {
                        runner.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        runner.start(
                            preset: preset,
                            runtime: runtime,
                            forwardEnvironment: forwardEnvironment
                        )
                    } label: {
                        Label("Run server", systemImage: "play.fill")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }

                Button("Clear", role: .destructive) {
                    runner.clear()
                }
                .disabled(runner.isRunning || runner.transcript.isEmpty)

                Spacer()
            }

            transcriptPane
        }
    }

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(runner.transcript) { line in
                        TranscriptLineView(line: line)
                            .id(line.id)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Self.transcriptMinHeight, maxHeight: Self.transcriptMaxHeight)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
            .onChange(of: runner.transcript.last?.id) { _, newValue in
                if let newValue {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct TranscriptLineView: View {
    let line: McpRunner.LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(symbol)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 18, alignment: .leading)
            Text(line.text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var symbol: String {
        switch line.kind {
        case .info: "•"
        case .sent: "→"
        case .recv: "←"
        case .stderr: "⚠︎"
        case .error: "✗"
        }
    }

    private var color: Color {
        switch line.kind {
        case .info: .secondary
        case .sent: .blue
        case .recv: .green
        case .stderr: .orange
        case .error: .red
        }
    }

    private var textColor: Color {
        line.kind == .error ? .red : .primary
    }
}
