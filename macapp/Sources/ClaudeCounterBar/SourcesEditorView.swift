import SwiftUI
import AppKit
import ClaudeCounterCore

/// GUI editor for `sources.toml`. Mounted as an inline, collapsible
/// section inside `PopoverView`'s own scroll area — the same way
/// `GaugesView` is conditionally shown there — rather than as a
/// `.sheet`/separate window. A `MenuBarExtra(.window)` popover is not a
/// normal app window, and sheet presentation from inside one is
/// unverified territory; an inline section is guaranteed to render
/// because it's just more content in the same `VStack`.
///
/// Edits are staged in `rows` and only committed on Save: `Sources.write`
/// validates through the exact same rules `Sources.load` applies (see
/// its doc comment), so a rejected save shows its error inline instead
/// of silently refusing or leaving a half-written file. On success,
/// `AppState.reloadSources()` is called so the running app picks up the
/// new list immediately.
struct SourcesEditorView: View {
    @ObservedObject var state: AppState
    @Binding var isExpanded: Bool

    @State private var rows: [EditableSource]
    @State private var errorMessage: String?
    @State private var saving = false

    private let configPath: String

    init(state: AppState, isExpanded: Binding<Bool>, configPath: String = Sources.defaultConfigPath()) {
        self.state = state
        self._isExpanded = isExpanded
        self.configPath = configPath
        // Seed from the app's currently-resolved sources (not a fresh
        // `Sources.load`) so the editor starts from what's actually
        // being scanned right now, including the single-implicit-source
        // fallback when no file exists yet.
        _rows = State(initialValue: state.sources.map(EditableSource.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sources")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isExpanded = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Text("Each source is a separate Claude subscription or install. Root is the folder holding that source's project transcripts.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach($rows) { $row in
                    SourceRowView(
                        row: $row,
                        onPickRoot: { pickRoot(for: $row) },
                        onRemove: { remove(row) }
                    )
                }
            }

            Button {
                rows.append(EditableSource(vendor: "claude", label: "", root: ""))
            } label: {
                Label("Add source", systemImage: "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    save()
                } label: {
                    Text(saving ? "Saving…" : "Save")
                        .font(.system(size: 11, weight: .semibold))
                }
                .disabled(saving)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func remove(_ row: EditableSource) {
        rows.removeAll { $0.id == row.id }
    }

    /// Opens a folder picker for one row's root. Activates the app
    /// first — `NSOpenPanel.runModal()` from inside a non-activating
    /// `MenuBarExtra` panel can otherwise open behind it instead of on
    /// top, which would look like nothing happened.
    private func pickRoot(for row: Binding<EditableSource>) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            row.wrappedValue.root = url.path
        }
    }

    private func save() {
        // An empty list is technically valid TOML (Sources.load treats
        // it as "zero configured sources", not malformed), but it would
        // silently stop counting anything — the one outcome none of
        // this feature's constraints allow. Catch it here rather than
        // let Sources.write accept it.
        guard !rows.isEmpty else {
            errorMessage = "At least one source is required."
            return
        }
        let entries = rows.map { $0.toSourceEntry() }
        do {
            try Sources.write(entries, to: configPath)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        saving = true
        Task {
            await state.reloadSources()
            saving = false
            isExpanded = false
        }
    }
}

/// Editable staging copy of a `SourceEntry` — `rows` holds these instead
/// of `SourceEntry` directly so in-progress edits (an empty label while
/// typing, say) don't have to be valid `SourceEntry`s and don't touch
/// `AppState` until Save.
private struct EditableSource: Identifiable {
    let id = UUID()
    var vendor: String
    var label: String
    var root: String

    init(vendor: String, label: String, root: String) {
        self.vendor = vendor
        self.label = label
        self.root = root
    }

    init(_ entry: SourceEntry) {
        self.vendor = entry.vendor
        self.label = entry.label
        self.root = entry.root
    }

    func toSourceEntry() -> SourceEntry {
        SourceEntry(vendor: vendor, label: label, root: root)
    }
}

private struct SourceRowView: View {
    @Binding var row: EditableSource
    let onPickRoot: () -> Void
    let onRemove: () -> Void

    /// Hardcoded rather than `Sources.knownVendors` — that set isn't
    /// `public` (it's internal to `ClaudeCounterCore`, deliberately not
    /// part of the cross-module API), and this editor only ever offers
    /// the two vendors the Go/Swift loaders both already accept.
    private let vendors = ["claude", "grok"]

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $row.vendor) {
                ForEach(vendors, id: \.self) { v in
                    Text(v).tag(v)
                }
            }
            .labelsHidden()
            .frame(width: 72)

            TextField("label", text: $row.label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)

            TextField("root", text: $row.root)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: onPickRoot) {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Choose folder")

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove source")
        }
        .font(.system(size: 11))
    }
}
