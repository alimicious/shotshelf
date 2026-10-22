import SwiftUI

private let terracotta = Color(nsColor: ShelfIcon.terracotta)
private let hoverSpring = Animation.spring(duration: 0.28, bounce: 0.25)

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @AppStorage(Prefs.autoTidyDays) private var autoTidyDays = 0
    @AppStorage(Prefs.smartNames) private var smartNames = true
    @AppStorage(Prefs.mascot) private var mascot = true
    @AppStorage(Prefs.autoUpdates) private var autoUpdates = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            presetRow
            grid
            folderChips
            footer
        }
        .padding(16)
        .frame(width: store.panelSize.width)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: ShelfIcon.image(size: 22)).renderingMode(.template).foregroundStyle(terracotta)
                .frame(width: 34, height: 34)
                .glassEffect(.regular.tint(terracotta.opacity(0.18)), in: .rect(cornerRadius: 10))
            // The small panel has no room beside the buttons, so its Update pill takes the subtitle's place.
            let compact = store.panelSize == .small
            VStack(alignment: .leading, spacing: 1) {
                Text("Screenshots").font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                if compact, let update = store.availableUpdate {
                    updatePill(update).controlSize(.small)
                } else {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !compact, let update = store.availableUpdate {
                updatePill(update)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    GlassIconButton(systemName: "square.grid.2x2", help: "Show all and search (⌘F)") {
                        store.showAll.toggle()
                    }
                    GlassIconButton(systemName: "folder", help: "Open \(store.folder.lastPathComponent) in Finder") {
                        NSWorkspace.shared.open(store.folder)
                    }
                    // Settings open in a popover so the panel never changes height; MenuBarExtra
                    // windows don't resize cleanly when their content grows or shrinks.
                    GlassIconButton(systemName: "gearshape", help: "Settings") {
                        store.showSettings.toggle()
                    }
                    .popover(isPresented: $store.showSettings, arrowEdge: .bottom) { settings }
                }
            }
        }
    }

    /// Big and terracotta on purpose: an update should be hard to miss.
    private func updatePill(_ update: AvailableUpdate) -> some View {
        Button { store.showUpdate.toggle() } label: {
            Label("Update", systemImage: "arrow.down.circle.fill").font(.callout.weight(.semibold))
        }
        .buttonStyle(.glassProminent).tint(terracotta)
        .help("ShotShelf \(update.version) is available")
        .popover(isPresented: $store.showUpdate, arrowEdge: .bottom) { UpdateView(update: update, store: store) }
    }

    private var subtitle: String {
        "\(store.todayCount) today · \(store.shots.count) on \(store.folder.lastPathComponent)"
    }

    // MARK: - Capture presets

    /// Up to four capture sizes: click one to place a frame of that size and capture it.
    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(store.presets) { preset in
                        Button { store.capture(preset) } label: {
                            Label(preset.label, systemImage: "viewfinder").font(.caption.weight(.medium))
                        }
                        .buttonStyle(.glass).controlSize(.small)
                        .help("Capture a \(preset.width) × \(preset.height) area. Right-click to edit.")
                        .contextMenu {
                            Button("Edit…") { store.editPreset(preset) }
                            Button("Delete", role: .destructive) { store.deletePreset(preset.id) }
                        }
                    }
                    if store.presets.count < CapturePreset.limit {
                        Button { store.newPreset() } label: {
                            Label(store.presets.isEmpty ? "Add a capture size" : "Size", systemImage: "plus")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.glass).controlSize(.small)
                        .help("Save a screenshot size you can capture in one click")
                    }
                }
                .padding(.vertical, 3).padding(.horizontal, 1)
            }
        }
        .frame(height: 32)
        .popover(isPresented: Binding(get: { store.presetEditor != nil }, set: { if !$0 { store.presetEditor = nil } }),
                 arrowEdge: .bottom) {
            if let draft = store.presetEditor { PresetEditor(draft: draft, store: store) }
        }
    }

    // MARK: - Grid

    /// The first shot gets the big slot; the rest fill rows of tiles below it (more of them in bigger panels).
    private var grid: some View {
        let shots = Array(store.visible)
        let size = store.panelSize
        return VStack(spacing: 8) {
            slot(shots, 0, size: size.hero)
            ForEach(0..<size.rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<size.columns, id: \.self) { col in
                        slot(shots, 1 + row * size.columns + col, size: size.tile)
                    }
                }
            }
        }
        .overlay { if store.shots.isEmpty { emptyState } }
        .overlay(alignment: .top) { if let toast = store.toast { toastView(toast) } }
        .animation(hoverSpring, value: store.toast)
    }

    @ViewBuilder
    private func slot(_ shots: [Shot], _ index: Int, size: CGSize) -> some View {
        if index < shots.count {
            ShotCell(shot: shots[index], store: store, size: size, isHero: index == 0)
        } else {
            RoundedRectangle(cornerRadius: index == 0 ? 18 : 12)
                .fill(.quinary.opacity(0.6))
                .overlay { Image(systemName: "photo").font(.system(size: index == 0 ? 28 : 16)).foregroundStyle(.quaternary) }
                .frame(width: size.width, height: size.height)
        }
    }

    private func toastView(_ toast: Toast) -> some View {
        Label(toast.text, systemImage: toast.symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            if store.folderReadable {
                Text("No screenshots yet").font(.callout.weight(.semibold))
                Text("Press ⇧⌘4 to grab one").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Can't read \(store.folder.lastPathComponent)").font(.callout.weight(.semibold))
                Text("Allow access in System Settings › Privacy & Security › Files & Folders")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Folders

    /// Folder chips: drop a shot on one to move it there, click to open it, right-click to remove.
    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(store.folders, id: \.self) { FolderChip(folder: $0, store: store) }
                    Button { store.addFolder() } label: {
                        Label(store.folders.isEmpty ? "Add a folder to drop shots into" : "Add", systemImage: "plus")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.glass).controlSize(.small)
                    .help("Shots dropped on a folder chip are moved into that folder")
                }
                .padding(.vertical, 3).padding(.horizontal, 1)
            }
        }
        .frame(height: 32)
    }

    // MARK: - Footer

    private var footer: some View {
        let count = store.tidyCandidates.count
        // Confirming swaps the row's contents in place, keeping the panel the same height.
        return HStack(spacing: 8) {
            if store.confirmingTidy {
                Text("Move \(count) older shot\(count == 1 ? "" : "s") to the Trash?").font(.caption.weight(.medium))
                Spacer()
                Button("Cancel") { store.confirmingTidy = false }
                    .buttonStyle(.glass).controlSize(.small)
                Button("Trash") { store.tidy() }
                    .buttonStyle(.glassProminent).tint(terracotta).controlSize(.small)
            } else {
                Text(store.panelSize == .small ? "Space to preview" : "Drag to share or rearrange · Space to preview")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { store.confirmingTidy = true } label: {
                    Label(count > 0 ? "Tidy \(count)" : "Tidy", systemImage: "sparkles")
                }
                .buttonStyle(.glass).controlSize(.small)
                .disabled(count == 0)
                .help("Move screenshots from before today to the Trash. Pinned ones stay.")
            }
        }
        .frame(height: 28)
        .animation(hoverSpring, value: store.confirmingTidy)
    }

    // MARK: - Settings

    private var updateStatusText: String {
        if let update = store.availableUpdate { return "Version \(update.version) is available." }
        switch store.updateStatus {
        case .checking: return "Checking…"
        case .upToDate: return "You're up to date (\(Updater.currentVersion))."
        case .failed(let message): return message
        default: return "Version \(Updater.currentVersion)"
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)
            Picker("Auto-tidy", selection: $autoTidyDays) {
                Text("Off").tag(0)
                Text("After 1 day").tag(1)
                Text("After 3 days").tag(3)
                Text("After 7 days").tag(7)
            }
            Text("Moves unpinned screenshots to the Trash once they're this old.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Size", selection: $store.panelSize) {
                ForEach(PanelSize.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            ShortcutRow(title: "Open shelf", slot: .open, store: store)
            ShortcutRow(title: "Search screenshots", slot: .search, store: store)
            Text(store.recording == nil ? "Shortcuts work from any app." : "Press the new shortcut. Esc cancels, Delete removes it.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Name new shots from their text", isOn: $smartNames)
            Toggle("Mascot snaps new shots", isOn: $mascot)
            Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            Divider()
            Toggle("Check for updates automatically", isOn: $autoUpdates)
            HStack {
                Text(updateStatusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if store.availableUpdate != nil {
                    Button("Update…") { store.showSettings = false; store.showUpdate = true }
                        .buttonStyle(.glassProminent).tint(terracotta).controlSize(.small)
                } else {
                    Button("Check Now") { Task { await store.checkForUpdates(userInitiated: true) } }
                        .buttonStyle(.glass).controlSize(.small)
                        .disabled(store.updateStatus == .checking)
                }
            }
            Text("Checks GitHub once a day. Nothing about you or your screenshots is sent.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text(store.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.glass).controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Cell

private struct ShotCell: View {
    let shot: Shot
    @ObservedObject var store: ShelfStore
    let size: CGSize
    let isHero: Bool

    private var isHovered: Bool { store.hovered == shot.url }
    private var isDropTarget: Bool { store.dropTarget == shot.url && store.dragging != shot.url }
    private var radius: CGFloat { isHero ? 18 : 12 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(.quinary)
            if let image = store.thumbnails[shot.url] {
                if isHero {
                    // Show the whole shot, over a blurred copy of itself instead of empty bars.
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height).blur(radius: 24).opacity(0.7).clipped()
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: size.width, height: size.height)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                } else {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height).clipped()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay {
            // A hairline edge like the system's glass, which turns terracotta while hovered or targeted.
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(isDropTarget || isHovered ? AnyShapeStyle(terracotta) : AnyShapeStyle(.white.opacity(0.12)),
                              lineWidth: isDropTarget ? 2.5 : isHovered ? 1.5 : 1)
        }
        .overlay(alignment: .topLeading) { badges }
        .overlay(alignment: .topTrailing) { if isHero { age } }
        .overlay(alignment: .bottom) { if isHovered { actions } }
        .shadow(color: isDropTarget ? terracotta.opacity(0.5) : .black.opacity(isHovered ? 0.28 : 0.1),
                radius: isHovered || isDropTarget ? 10 : 3, y: isHovered ? 5 : 1)
        .scaleEffect(isDropTarget ? 1.04 : isHovered ? (isHero ? 1.01 : 1.03) : 1)
        .zIndex(isHovered || isDropTarget ? 1 : 0)
        .animation(hoverSpring, value: isHovered)
        .animation(hoverSpring, value: isDropTarget)
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .onHover { inside in
            if inside { store.hovered = shot.url } else if isHovered { store.hovered = nil }
        }
        .onTapGesture(count: 2) { store.open(shot) }
        .onDrag {
            store.dragging = shot.url
            return NSItemProvider(contentsOf: shot.url) ?? NSItemProvider()
        }
        .onDrop(of: [.item], delegate: RearrangeDrop(target: shot, store: store))
        .contextMenu { ShotMenu(shot: shot, store: store) }
        .help("\(shot.date.formatted(date: .abbreviated, time: .shortened)) · \(shot.url.lastPathComponent)")
    }

    private var age: some View {
        Text(shot.date.formatted(.relative(presentation: .named)))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .padding(9)
    }

    private var badges: some View {
        HStack(spacing: 5) {
            if shot.date > store.freshSince {
                Circle().fill(terracotta).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.2))
                    .shadow(color: terracotta.opacity(0.8), radius: 4)
            }
            if store.isPinned(shot) {
                Image(systemName: "pin.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .glassEffect(.regular.tint(terracotta), in: .circle)
            }
        }
        .padding(isHero ? 9 : 6)
    }

    /// Glass over the screenshot itself, so the controls pick up its colours.
    private var actions: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                CellButton(systemName: "doc.on.doc", help: "Copy image (⌘C)") { store.copy(shot) }
                CellButton(systemName: "text.viewfinder", help: "Copy text (T)") { store.copyText(shot) }
                CellButton(systemName: "eye", help: "Quick Look (Space)") { store.quickLook(shot) }
                Menu { ShotMenu(shot: shot, store: store) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 18)
                }
                .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                .help("More")
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.bottom, isHero ? 10 : 6)
        .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
    }
}

/// Rearranging: dropping one of the shelf's own shots onto another moves it into that spot.
/// Only acts on a drop, not while passing over, so dragging a shot out to another app never reshuffles the shelf.
@MainActor
private struct RearrangeDrop: DropDelegate {
    let target: Shot
    let store: ShelfStore

    func validateDrop(info: DropInfo) -> Bool { store.dragging != nil }
    func dropEntered(info: DropInfo) { store.dropTarget = target.url }
    func dropExited(info: DropInfo) { if store.dropTarget == target.url { store.dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { store.dragging = nil; store.dropTarget = nil }
        guard let url = store.dragging else { return false }
        withAnimation(.snappy) { store.move(url, onto: target.url) }
        return true
    }
}

/// Everything you can do with a shot, for the ⋯ button and right-click menus.
struct ShotMenu: View {
    let shot: Shot
    @ObservedObject var store: ShelfStore

    var body: some View {
        Button("Copy Image", systemImage: "doc.on.doc") { store.copy(shot) }
        Button("Copy Text", systemImage: "text.viewfinder") { store.copyText(shot) }
        Button("Quick Look", systemImage: "eye") { store.quickLook(shot) }
        Divider()
        Button(store.isPinned(shot) ? "Unpin" : "Pin", systemImage: store.isPinned(shot) ? "pin.slash" : "pin") {
            store.togglePin(shot)
        }
        Button("Redact…", systemImage: "eye.slash") { store.redact(shot) }
        Button("Rename from Text", systemImage: "character.cursor.ibeam") { store.smartRename(shot) }
        if !store.folders.isEmpty {
            Menu("Move to", systemImage: "folder") {
                ForEach(store.folders, id: \.self) { folder in
                    Button(folder.lastPathComponent) { store.file(shot, into: folder) }
                }
            }
        }
        Button("Show in Finder", systemImage: "magnifyingglass") { store.reveal(shot) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { store.trash(shot) }
    }
}

private struct FolderChip: View {
    let folder: URL
    @ObservedObject var store: ShelfStore

    private var isTarget: Bool { store.dropFolder == folder }

    var body: some View {
        Label(folder.lastPathComponent, systemImage: isTarget ? "folder.fill.badge.plus" : "folder.fill")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(isTarget ? .regular.tint(terracotta.opacity(0.6)).interactive() : .regular.interactive(), in: .capsule)
            .scaleEffect(isTarget ? 1.08 : 1)
            .animation(hoverSpring, value: isTarget)
            .onTapGesture { NSWorkspace.shared.open(folder) }
            .onDrop(of: [.item], delegate: FolderDrop(folder: folder, store: store))
            .contextMenu {
                Button("Open in Finder") { NSWorkspace.shared.open(folder) }
                Button("Remove from Shelf") { store.removeFolder(folder) }
            }
            .help("Drop a shot here to move it to \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
    }
}

@MainActor
private struct FolderDrop: DropDelegate {
    let folder: URL
    let store: ShelfStore

    func validateDrop(info: DropInfo) -> Bool { store.dragging != nil }
    func dropEntered(info: DropInfo) { store.dropFolder = folder }
    func dropExited(info: DropInfo) { if store.dropFolder == folder { store.dropFolder = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { store.dragging = nil; store.dropFolder = nil }
        guard let url = store.dragging, let shot = store.shots.first(where: { $0.url == url }) else { return false }
        store.file(shot, into: folder)
        return true
    }
}

/// The update popover: what's new, then install and relaunch in one click.
private struct UpdateView: View {
    let update: AvailableUpdate
    @ObservedObject var store: ShelfStore

    private var busy: Bool { store.updateStatus == .downloading || store.updateStatus == .installing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: ShelfIcon.image(size: 22)).renderingMode(.template).foregroundStyle(terracotta)
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular.tint(terracotta.opacity(0.18)), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text("ShotShelf \(update.version)").font(.headline)
                    Text("You have \(Updater.currentVersion)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Link("See what's new", destination: update.pageURL).font(.callout)
            switch store.updateStatus {
            case .downloading:
                ProgressView("Downloading and checking…").controlSize(.small)
            case .installing:
                ProgressView("Installing…").controlSize(.small)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            default:
                Text("Your pins, shelf and settings carry over. macOS may ask for access to your screenshots again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if case .failed = store.updateStatus {
                    Button("Download from GitHub") { NSWorkspace.shared.open(update.pageURL) }.buttonStyle(.glass)
                } else {
                    Button("Later") { store.showUpdate = false }.buttonStyle(.glass).disabled(busy)
                }
                Button("Install and Relaunch") { store.installUpdate() }
                    .buttonStyle(.glassProminent).tint(terracotta).disabled(busy)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// A global shortcut in Settings: click to record a new one, ⓧ to remove it.
private struct ShortcutRow: View {
    let title: String
    let slot: ShortcutSlot
    @ObservedObject var store: ShelfStore

    var body: some View {
        let shortcut = store.shortcut(for: slot)
        let isRecording = store.recording == slot
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            Button {
                isRecording ? store.cancelRecording() : store.startRecording(slot)
            } label: {
                Text(isRecording ? "Press keys…" : shortcut?.display ?? "Record Shortcut")
                    .frame(minWidth: 64)
            }
            .buttonStyle(.glass).controlSize(.small)
            .tint(isRecording ? terracotta : nil)
            if shortcut != nil, !isRecording {
                Button { store.setShortcut(nil, for: slot) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Remove this shortcut")
            }
        }
    }
}

private struct CellButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct GlassIconButton: View {
    let systemName: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 12, weight: .medium)).frame(width: 16, height: 16)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help)
    }
}
