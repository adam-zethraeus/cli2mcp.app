import SwiftUI

struct PresetSidebar: View {
    @Bindable var store: CatalogStore
    @Binding var selection: CliPreset.ID?

    @State private var sheet: SheetKind?

    enum SheetKind: Identifiable {
        case adding
        case editing(id: String)

        var id: String {
            switch self {
            case .adding: "adding"
            case .editing(let id): "editing-\(id)"
            }
        }
    }

    var body: some View {
        List(selection: $selection) {
            if !store.liveBuiltIns.isEmpty {
                Section("Built-ins") {
                    ForEach(store.liveBuiltIns) { preset in
                        PresetRow(preset: preset)
                            .tag(preset.id as CliPreset.ID?)
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    if selection == preset.id { selection = nil }
                                    store.deleteBuiltIn(preset.id)
                                }
                            }
                    }
                }
            }

            if !store.userPresets.isEmpty {
                Section("Custom") {
                    ForEach(store.userPresets) { preset in
                        PresetRow(preset: preset)
                            .tag(preset.id as CliPreset.ID?)
                            .contextMenu {
                                Button("Edit…", systemImage: "pencil") {
                                    sheet = .editing(id: preset.id)
                                }
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    if selection == preset.id { selection = nil }
                                    try? store.deleteUserPreset(id: preset.id)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("CLIs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        sheet = .adding
                    } label: {
                        Label("Add custom CLI…", systemImage: "plus")
                    }

                    if store.deletedBuiltInCount > 0 {
                        Divider()
                        Button {
                            store.resetBuiltIns()
                        } label: {
                            Label(
                                "Reset built-ins (\(store.deletedBuiltInCount))",
                                systemImage: "arrow.uturn.backward"
                            )
                        }
                    }
                } label: {
                    Label("Add or reset", systemImage: "plus")
                }
                .menuIndicator(.hidden)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .adding:
                PresetEditorSheet(mode: .adding, store: store) { newPreset in
                    selection = newPreset.id
                }
            case .editing(let id):
                if let existing = store.preset(id: id), existing.isEditable {
                    PresetEditorSheet(
                        mode: .editing(id: id),
                        store: store,
                        initial: CliPresetDraft(from: existing)
                    ) { _ in }
                }
            }
        }
    }
}

private struct PresetRow: View {
    let preset: CliPreset

    var body: some View {
        HStack(spacing: 10) {
            SafetyDot(tier: preset.tier)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(preset.displayName)
                        .font(.body.weight(.medium))
                    if preset.origin == .user {
                        Image(systemName: "person.crop.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("User-added preset")
                    }
                }
                Text(preset.binary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SafetyDot: View {
    let tier: SafetyTier

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(tier.label)
    }

    private var color: Color {
        switch tier {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }
}
