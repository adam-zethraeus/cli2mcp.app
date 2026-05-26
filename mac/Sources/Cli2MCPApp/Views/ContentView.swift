import SwiftUI

struct ContentView: View {
    @State private var store = CatalogStore()
    @State private var selection: CliPreset.ID?
    @State private var runtime: NativeRuntime? = NativeRuntime.resolve()
    @StateObject private var runner = McpRunner()

    var body: some View {
        NavigationSplitView {
            PresetSidebar(store: store, selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detailPane
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                RuntimeStatusBadge(present: runtime != nil)
            }
        }
        .onAppear {
            if selection == nil {
                selection = store.visiblePresets.first?.id
            }
        }
        .onChange(of: store.visiblePresets.map(\.id)) { _, ids in
            // Selection followed a preset that just got hidden or deleted.
            if let current = selection, !ids.contains(current) {
                selection = ids.first
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let runtime {
            if let id = selection, let preset = store.preset(id: id) {
                PresetDetailView(preset: preset, runtime: runtime, runner: runner, store: store)
                    .id(preset.id)  // reset transient view state when switching presets
            } else {
                ContentUnavailableView(
                    "Pick a CLI",
                    systemImage: "terminal",
                    description: Text("Choose one from the sidebar, or add your own with the + button.")
                )
            }
        } else {
            // Hard error: the .app shipped (or was tampered with) without its
            // native helper. Snippets would point at nonexistent paths and
            // the test runner couldn't spawn anything, so we refuse to render
            // either rather than expose a misleading partial UI.
            ContentUnavailableView {
                Label("Native helper missing", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            } description: {
                Text(
                    "Cli2MCP.app ships cli2mcp-server, but it is not present in this build. Reinstall the app, or rebuild with `make app` from a checkout."
                )
            }
        }
    }
}

private struct RuntimeStatusBadge: View {
    let present: Bool

    var body: some View {
        if present {
            Label("Native helper ✓", systemImage: "shippingbox.fill")
                .foregroundStyle(.green)
                .help("cli2mcp-server shipped inside this app is present and executable.")
        } else {
            Label("Native helper missing", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help("Reinstall this app — its cli2mcp-server helper is missing or not executable.")
        }
    }
}
