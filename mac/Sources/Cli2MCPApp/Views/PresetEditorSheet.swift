import SwiftUI

/// Modal form for adding a custom CLI to the whitelist or editing an existing
/// user-added one. Built-ins never reach this sheet — the sidebar disables
/// the affordances that would open it for them.
struct PresetEditorSheet: View {
    enum Mode: Equatable {
        case adding
        case editing(id: String)

        var title: String {
            switch self {
            case .adding: "Add custom CLI"
            case .editing: "Edit custom CLI"
            }
        }

        var saveLabel: String {
            switch self {
            case .adding: "Add"
            case .editing: "Save"
            }
        }
    }

    let mode: Mode
    let store: CatalogStore
    let onCommit: (CliPreset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CliPresetDraft
    @State private var errorMessage: String?

    init(
        mode: Mode,
        store: CatalogStore,
        initial: CliPresetDraft = CliPresetDraft(),
        onCommit: @escaping (CliPreset) -> Void
    ) {
        self.mode = mode
        self.store = store
        self.onCommit = onCommit
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                form
                    .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private var header: some View {
        HStack {
            Text(mode.title).font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            field(label: "Display name", help: "Shown in the sidebar.") {
                TextField("e.g. ImageMagick", text: $draft.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            field(label: "Binary", help: "The command name on PATH. No spaces, no slashes.") {
                TextField("e.g. magick", text: $draft.binary)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            field(label: "Summary", help: "One sentence shown under the title.") {
                TextField("Short description", text: $draft.summary, axis: .vertical)
                    .lineLimit(2...3)
                    .textFieldStyle(.roundedBorder)
            }

            field(
                label: "Safety tier",
                help: "Pick based on what the CLI can actually do — write files, hit network, mutate state."
            ) {
                Picker("", selection: $draft.tier) {
                    ForEach(SafetyTier.allCases, id: \.self) { tier in
                        Text(tier.label).tag(tier)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            field(
                label: "Server args",
                help: "One per line. e.g. --name then on the next line my-tool. Don't include the binary itself or the safe defaults — those are added automatically."
            ) {
                TextEditor(text: $draft.serverArgsText)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    private func field<Content: View>(
        label: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.medium))
            content()
            if let help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(mode.saveLabel) { commit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    private func commit() {
        do {
            let preset: CliPreset
            switch mode {
            case .adding:
                preset = try store.addUserPreset(draft)
            case .editing(let id):
                preset = try store.updateUserPreset(id: id, with: draft)
            }
            onCommit(preset)
            dismiss()
        } catch let err as CatalogError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
