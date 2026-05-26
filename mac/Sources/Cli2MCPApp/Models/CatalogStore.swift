import Foundation
import Observation

/// Errors surfaced by attempts to mutate the catalog.
enum CatalogError: LocalizedError {
    case duplicateId(String)
    case immutableBuiltIn
    case invalidBinary(String)
    case invalidDisplayName

    var errorDescription: String? {
        switch self {
        case .duplicateId(let id): "A preset with id '\(id)' already exists."
        case .immutableBuiltIn: "Built-in presets cannot be edited. Delete them via the row context menu and add a custom preset instead."
        case .invalidBinary(let bin): "Binary name '\(bin)' is invalid (no spaces or path separators)."
        case .invalidDisplayName: "Display name cannot be empty."
        }
    }
}

/// On-disk shape of the persistent catalog state. Versioned so future
/// schema migrations are explicit rather than guesswork.
///
/// Both `deletedBuiltIns` (current) and `disabledBuiltIns` (legacy v1)
/// are decoded; only the new key is written. The legacy key existed for
/// roughly one release before the UX shifted from "hide" to "delete + reset",
/// so the in-place rename is fine without a versioned migration.
///
/// `currentVersion` is the integer written into every freshly-encoded file.
/// Bump it when adding a real migration so older builds can detect a newer
/// format and refuse to clobber it.
private struct PersistedCatalog: Codable {
    static let currentVersion = 1


    var version: Int
    var userPresets: [CliPreset]
    var deletedBuiltIns: [String]
    /// Per-preset override for "forward the user's shell environment to the
    /// wrapped CLI". Map keyed by preset id. A missing key means the default
    /// (true) applies; this map exists to record explicit opt-outs and
    /// re-enables made by the user.
    var forwardEnvironment: [String: Bool]?
    var disabledBuiltIns: [String]?  // legacy v1, decode-only

    enum CodingKeys: String, CodingKey {
        case version, userPresets, deletedBuiltIns, forwardEnvironment, disabledBuiltIns
    }

    init(
        version: Int,
        userPresets: [CliPreset],
        deletedBuiltIns: [String],
        forwardEnvironment: [String: Bool]
    ) {
        self.version = version
        self.userPresets = userPresets
        self.deletedBuiltIns = deletedBuiltIns
        self.forwardEnvironment = forwardEnvironment
        self.disabledBuiltIns = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.userPresets = try c.decode([CliPreset].self, forKey: .userPresets)
        let new = try c.decodeIfPresent([String].self, forKey: .deletedBuiltIns)
        let legacy = try c.decodeIfPresent([String].self, forKey: .disabledBuiltIns)
        self.deletedBuiltIns = new ?? legacy ?? []
        self.forwardEnvironment = try c.decodeIfPresent([String: Bool].self, forKey: .forwardEnvironment)
        self.disabledBuiltIns = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(userPresets, forKey: .userPresets)
        try c.encode(deletedBuiltIns, forKey: .deletedBuiltIns)
        if let forwardEnvironment, !forwardEnvironment.isEmpty {
            try c.encode(forwardEnvironment, forKey: .forwardEnvironment)
        }
        // legacy disabledBuiltIns is intentionally not encoded
    }
}

/// The unified catalog the UI renders against. Combines the compiled-in
/// built-in whitelist with user-added presets and a per-built-in
/// hide-flag, persisting all user state to JSON on every mutation.
@Observable
@MainActor
final class CatalogStore {
    private(set) var userPresets: [CliPreset] = []
    /// IDs of built-in presets the user has chosen to remove from the sidebar.
    /// Persisted across launches; the originals can be brought back en masse
    /// via `resetBuiltIns()`.
    private(set) var deletedBuiltIns: Set<String> = []
    /// Per-preset override for "forward the user's shell environment". Only
    /// holds explicit user choices — absent keys read as the default
    /// (`forwardEnvironmentDefault`, currently `true`).
    private(set) var forwardEnvironmentOverrides: [String: Bool] = [:]

    /// Default for any preset without an explicit override. The user's most
    /// common pain point is OAuth tokens / PATH not propagating into wrapped
    /// CLIs, so we default this on.
    static let forwardEnvironmentDefault = true

    private let storeURL: URL?
    private let builtIns: [CliPreset]

    init(builtIns: [CliPreset] = PresetCatalog.presets, storeURL: URL? = CatalogStore.defaultStoreURL()) {
        self.builtIns = builtIns
        self.storeURL = storeURL
        load()
    }

    // MARK: - Per-preset env-forwarding toggle

    /// Effective value: explicit override if present, else the default.
    func forwardsEnvironment(for presetID: String) -> Bool {
        forwardEnvironmentOverrides[presetID] ?? Self.forwardEnvironmentDefault
    }

    /// Set the explicit override for a preset. Persists immediately.
    func setForwardsEnvironment(_ value: Bool, for presetID: String) {
        forwardEnvironmentOverrides[presetID] = value
        save()
    }

    // MARK: - Derived views

    /// Every preset declared in the catalog, including ones the user deleted.
    /// Used internally for id resolution; not what the sidebar renders.
    private var catalog: [CliPreset] {
        builtIns + userPresets
    }

    /// Built-ins the user has not deleted.
    var liveBuiltIns: [CliPreset] {
        builtIns.filter { !deletedBuiltIns.contains($0.id) }
    }

    /// Everything the sidebar should currently show: surviving built-ins
    /// followed by user presets.
    var visiblePresets: [CliPreset] {
        liveBuiltIns + userPresets
    }

    /// Number of built-ins currently deleted, for the "Reset built-ins (N)"
    /// menu item.
    var deletedBuiltInCount: Int { deletedBuiltIns.count }

    func preset(id: String) -> CliPreset? {
        catalog.first { $0.id == id }
    }

    // MARK: - Mutations

    /// Remove a built-in from the sidebar. Persistent across launches.
    /// Reversible only via `resetBuiltIns()`. No-op for user-preset ids;
    /// those are removed via `deleteUserPreset`.
    func deleteBuiltIn(_ id: String) {
        guard builtIns.contains(where: { $0.id == id }) else { return }
        deletedBuiltIns.insert(id)
        save()
    }

    /// Restore every built-in that has been deleted. User presets are
    /// untouched.
    func resetBuiltIns() {
        guard !deletedBuiltIns.isEmpty else { return }
        deletedBuiltIns.removeAll()
        save()
    }

    func addUserPreset(_ draft: CliPresetDraft) throws -> CliPreset {
        let preset = try draft.validated(existingIds: Set(catalog.map(\.id)))
        userPresets.append(preset)
        save()
        return preset
    }

    func updateUserPreset(id: String, with draft: CliPresetDraft) throws -> CliPreset {
        guard let idx = userPresets.firstIndex(where: { $0.id == id }) else {
            throw CatalogError.immutableBuiltIn
        }
        let othersIds = Set(catalog.filter { $0.id != id }.map(\.id))
        let updated = try draft.validated(existingIds: othersIds, preservingId: id)
        userPresets[idx] = updated
        save()
        return updated
    }

    func deleteUserPreset(id: String) throws {
        guard let idx = userPresets.firstIndex(where: { $0.id == id }) else {
            throw CatalogError.immutableBuiltIn
        }
        userPresets.remove(at: idx)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let url = storeURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersistedCatalog.self, from: data)
        else { return }
        userPresets = decoded.userPresets.map { p in
            // Coerce on load so a tampered file can't smuggle in a fake built-in.
            CliPreset(
                id: p.id,
                displayName: p.displayName,
                binary: p.binary,
                summary: p.summary,
                serverArgs: p.serverArgs,
                tier: p.tier,
                origin: .user
            )
        }
        deletedBuiltIns = Set(decoded.deletedBuiltIns)
        forwardEnvironmentOverrides = decoded.forwardEnvironment ?? [:]
    }

    private func save() {
        guard let url = storeURL else { return }
        let payload = PersistedCatalog(
            version: PersistedCatalog.currentVersion,
            userPresets: userPresets,
            deletedBuiltIns: Array(deletedBuiltIns).sorted(),
            forwardEnvironment: forwardEnvironmentOverrides
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: url, options: [.atomic])
        } catch {
            // We don't crash on persistence failures — the in-memory state stays
            // valid for this session; the user gets a stderr line.
            FileHandle.standardError.write(
                Data("cli2mcp: failed to write catalog: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    nonisolated static func defaultStoreURL() -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support
            .appendingPathComponent("cli2mcp", isDirectory: true)
            .appendingPathComponent("state.json")
    }
}

// MARK: - Draft used by the editor sheet

/// Form-shaped value distinct from `CliPreset` so the editor can work with
/// invalid intermediate state without faking up a malformed preset.
struct CliPresetDraft: Sendable {
    var displayName: String = ""
    var binary: String = ""
    var summary: String = ""
    var serverArgsText: String = ""
    var tier: SafetyTier = .yellow

    init() {}

    init(from preset: CliPreset) {
        self.displayName = preset.displayName
        self.binary = preset.binary
        self.summary = preset.summary
        self.serverArgsText = preset.serverArgs.joined(separator: "\n")
        self.tier = preset.tier
    }

    /// Parse args one-per-line so users don't have to wrestle with shell
    /// quoting for values that contain spaces.
    var parsedArgs: [String] {
        serverArgsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func validated(existingIds: Set<String>, preservingId: String? = nil) throws -> CliPreset {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let trimmedBin = binary.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else { throw CatalogError.invalidDisplayName }
        guard !trimmedBin.isEmpty,
              !trimmedBin.contains(where: { $0.isWhitespace }),
              !trimmedBin.contains("/")
        else { throw CatalogError.invalidBinary(trimmedBin) }

        let id = preservingId ?? Self.makeId(displayName: trimmedName, existingIds: existingIds)
        if existingIds.contains(id) { throw CatalogError.duplicateId(id) }

        return CliPreset(
            id: id,
            displayName: trimmedName,
            binary: trimmedBin,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            serverArgs: parsedArgs,
            tier: tier,
            origin: .user
        )
    }

    private static func makeId(displayName: String, existingIds: Set<String>) -> String {
        let slug = displayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let base = slug.isEmpty ? "cli" : slug

        if !existingIds.contains(base) { return base }
        for n in 2...999 {
            let candidate = "\(base)-\(n)"
            if !existingIds.contains(candidate) { return candidate }
        }
        return base + "-" + UUID().uuidString.prefix(8).lowercased()
    }
}
