import SwiftUI

struct PresetDetailView: View {
    let preset: CliPreset
    let runtime: NativeRuntime
    @ObservedObject var runner: McpRunner
    @Bindable var store: CatalogStore

    private var forwardEnvironment: Bool {
        store.forwardsEnvironment(for: preset.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                commandLineCard
                Divider()
                snippetCard
                Divider()
                runnerCard
            }
            .padding(20)
        }
        .navigationTitle(preset.displayName)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(preset.displayName).font(.title.weight(.semibold))
                    SafetyBadge(tier: preset.tier)
                }
                Text(preset.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var commandLineCard: some View {
        SectionCard(title: "Effective server invocation") {
            CodeBlock(text: "cli2mcp-server " + preset.fullArgs().joined(separator: " "))
        }
    }

    private var snippetCard: some View {
        let renderedSnippet = McpConfig.snippet(
            for: preset,
            runtime: runtime,
            forwardEnvironment: forwardEnvironment
        )
        return SectionCard(title: "MCP client config") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Forward my shell environment to this CLI",
                    isOn: Binding(
                        get: { forwardEnvironment },
                        set: { store.setForwardsEnvironment($0, for: preset.id) }
                    )
                )
                .toggleStyle(.checkbox)
                .help(
                    "When on, the server sources your login shell at startup so the wrapped CLI sees your PATH and any OAuth tokens your dotfiles set. Tokens never enter the snippet."
                )

                CodeBlock(text: renderedSnippet)

                HStack {
                    Button {
                        copy(renderedSnippet)
                    } label: {
                        Label("Copy snippet", systemImage: "doc.on.doc")
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])

                    Spacer()
                }
                Text(
                    "Paths point at this app's current location: \(runtime.installLocation). If you move the app, reopen it and re-copy."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var runnerCard: some View {
        SectionCard(
            title: "Test run",
            trailing: { runStatusBadge }
        ) {
            RunnerView(
                preset: preset,
                runtime: runtime,
                runner: runner,
                forwardEnvironment: forwardEnvironment
            )
        }
    }

    @ViewBuilder
    private var runStatusBadge: some View {
        switch runner.status {
        case .idle:
            Text("Idle").font(.caption).foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…").font(.caption)
            }
        case .running(let name, let count):
            Label("Healthy — \(name) (\(count) inputs)", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .stopped(let code):
            Label("Exited \(code.map(String.init) ?? "?")", systemImage: "stop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Reusable bits

struct SafetyBadge: View {
    let tier: SafetyTier

    var body: some View {
        Text(tier.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch tier {
        case .green: .green.opacity(0.18)
        case .yellow: .yellow.opacity(0.22)
        case .red: .red.opacity(0.22)
        }
    }

    private var foreground: Color {
        switch tier {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        }
    }
}

struct SectionCard<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                trailing()
            }
            content()
        }
    }
}

extension SectionCard where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}
