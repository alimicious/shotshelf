import SwiftUI
import Translation

private let terracotta = Color(nsColor: ShelfIcon.terracotta)
private let hoverSpring = Animation.spring(duration: 0.28, bounce: 0.25)

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @AppStorage(Prefs.autoTidyDays) private var autoTidyDays = 0
    @AppStorage(Prefs.smartNames) private var smartNames = true
    @AppStorage(Prefs.iconAnimation) private var iconAnimation = true
    @AppStorage(Prefs.autoUpdates) private var autoUpdates = true
    @AppStorage(Prefs.searchEyes) private var searchEyes = true
    @AppStorage(Prefs.capturePopup) private var capturePopup = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            grid
            folderChips
            footer
        }
        .padding(16)
        .frame(width: store.panelSize.width)
        // On first launch the welcome takes the shelf's place, at the shelf's size.
        .opacity(store.showWelcome ? 0 : 1)
        .allowsHitTesting(!store.showWelcome)
        .overlay { if store.showWelcome { WelcomeView(store: store) } }
        .animation(.smooth(duration: 0.35), value: store.showWelcome)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            OrbMark(size: 34, animated: store.panelVisible)
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
        .modifier(LightSweep())
        .help("ShotShelf \(update.version) is available")
        .popover(isPresented: $store.showUpdate, arrowEdge: .bottom) { UpdateView(update: update, store: store) }
    }

    private var subtitle: String {
        "\(store.todayCount) today · \(store.shots.count) on \(store.folder.lastPathComponent)"
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
        .overlay(alignment: .top) { if let toast = store.toast { ToastCapsule(toast: toast, store: store).padding(.top, 10) } }
        .animation(hoverSpring, value: store.toast)
        // Translate Text… opens the system's own translation popover, which works on your Mac.
        .translationPresentation(isPresented: $store.showTranslation, text: store.translation)
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

    private var emptyState: some View {
        VStack(spacing: 4) {
            if store.folderReadable {
                OrbMark(size: 52, animated: store.panelVisible).padding(.bottom, 6)
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
        // Confirming and selecting swap the row's contents in place, keeping the panel the same height.
        return HStack(spacing: 8) {
            if !store.selection.isEmpty {
                selectionBar
            } else if store.confirmingTidy {
                Text(tidyQuestion(older: count - store.tidyDuplicateCount, duplicates: store.tidyDuplicateCount))
                    .font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
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
                .help("Move screenshots from before today, and near-copies of newer ones, to the Trash. Pinned ones stay.")
            }
        }
        .frame(height: 28)
        .animation(hoverSpring, value: store.confirmingTidy)
        .animation(hoverSpring, value: store.selection.isEmpty)
    }

    private func tidyQuestion(older: Int, duplicates: Int) -> String {
        let olderText = "\(older) older shot\(older == 1 ? "" : "s")"
        let duplicateText = "\(duplicates) duplicate\(duplicates == 1 ? "" : "s")"
        switch (older, duplicates) {
        case (_, 0): return "Move \(olderText) to the Trash?"
        case (0, _): return "Move \(duplicateText) to the Trash?"
        default: return "Move \(olderText) and \(duplicateText) to the Trash?"
        }
    }

    /// What you can do with the shots you've picked. The stack on the left drags them all at once.
    @ViewBuilder
    private var selectionBar: some View {
        let group = store.selectedShots
        Label("\(store.selection.count) selected", systemImage: "rectangle.stack.fill")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.regular.tint(terracotta.opacity(0.3)).interactive(), in: .capsule)
            .overlay { SelectionDragArea(store: store) }
            .help("Drag to put all \(store.selection.count) into an app or onto a folder chip")
        Spacer(minLength: 4)
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                FooterButton(systemName: "doc.on.doc", help: "Copy all (⌘C)") { store.copy(group) }
                FooterButton(systemName: "square.and.arrow.up", help: "Share") { store.share(group) }
                Menu { SelectionMenu(shots: group, store: store) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium)).frame(width: 14, height: 14)
                }
                .menuStyle(.button).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
                .menuIndicator(.hidden).fixedSize()
                .help("More")
                FooterButton(systemName: "trash", help: "Move to the Trash (⌫)") { store.trash(group) }
                FooterButton(systemName: "xmark", help: "Deselect (Esc)") { store.selection = [] }
            }
        }
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

    /// Settings in three tabs, so the popover stays a comfortable height: General, Shortcuts (all
    /// five together) and Updates, with the folder and Quit under all of them.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Settings", selection: $store.settingsTab) {
                ForEach(SettingsTab.allCases) { tab in
                    // A dot on Updates when there's one waiting.
                    Text(tab == .updates && store.availableUpdate != nil ? "Updates •" : tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch store.settingsTab {
            case .general: generalSettings
            case .shortcuts: shortcutSettings
            case .updates: updateSettings
            }
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

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Size", selection: $store.panelSize) {
                ForEach(PanelSize.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Auto-tidy", selection: $autoTidyDays) {
                Text("Off").tag(0)
                Text("After 1 day").tag(1)
                Text("After 3 days").tag(3)
                Text("After 7 days").tag(7)
                Text("After 1 month").tag(30)
            }
            Text("Moves unpinned screenshots to the Trash once they're this old.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsSection("New screenshots") {
                Toggle("Name them from their text", isOn: $smartNames)
                Toggle("Animate the menu bar icon", isOn: $iconAnimation)
                Toggle("Show a pop-up", isOn: $capturePopup)
            }
            SettingsSection("App") {
                Toggle("Eye buttons in search", isOn: $searchEyes)
                Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            }
        }
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection("Shelf") {
                ForEach(ShortcutSlot.allCases.filter { !$0.actsOnNewest }, id: \.self) {
                    ShortcutRow(title: $0.label, slot: $0, store: store)
                }
            }
            SettingsSection("Newest screenshot") {
                ForEach(ShortcutSlot.allCases.filter(\.actsOnNewest), id: \.self) {
                    ShortcutRow(title: $0.label, slot: $0, store: store)
                }
            }
            Text(store.recording == nil ? "These work from any app. The newest-screenshot ones act without opening the shelf."
                                        : "Press the new shortcut. Esc cancels, Delete removes it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var updateSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Cell

private struct ShotCell: View {
    let shot: Shot
    @ObservedObject var store: ShelfStore
    let size: CGSize
    let isHero: Bool

    private var isHovered: Bool { store.hovered == shot.url }
    private var isSelected: Bool { store.selection.contains(shot.url) }
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
            // A hairline edge like the system's glass, which turns terracotta while hovered, selected
            // or targeted. Selected shots also take on a wash of it.
            RoundedRectangle(cornerRadius: radius)
                .fill(terracotta.opacity(isSelected ? 0.14 : 0))
                .strokeBorder(isDropTarget || isHovered || isSelected ? AnyShapeStyle(terracotta) : AnyShapeStyle(.white.opacity(0.12)),
                              lineWidth: isDropTarget || isSelected ? 2.5 : isHovered ? 1.5 : 1)
                .allowsHitTesting(false)
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
        .onTapGesture {
            // One handler for both, so a click that selects doesn't wait to rule out a double-click.
            if NSApp.currentEvent?.clickCount == 2 {
                store.open(shot)
            } else {
                store.click(shot, in: Array(store.visible))
            }
        }
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
            if isSelected {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .glassEffect(.regular.tint(terracotta), in: .circle)
            }
            if shot.isVideo { RecordingBadge(duration: store.durations[shot.url]) }
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
                if shot.isVideo {
                    CellButton(systemName: "doc.on.doc", help: "Copy recording (⌘C)") { store.copy(shot) }
                    CellButton(systemName: "photo.stack", help: "Trim or make a GIF (R)") { store.editRecording(shot) }
                } else {
                    CellButton(systemName: "doc.on.doc", help: "Copy image (⌘C)") { store.copy(shot) }
                    CellButton(systemName: "text.viewfinder", help: "Copy text (T)") { store.copyText(shot) }
                    // A link, email address or QR code found in the shot gets a button of its own.
                    if let link = store.links(for: shot).first {
                        CellButton(systemName: link.symbol, help: link.title) { store.use(link) }
                    }
                }
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

    func validateDrop(info: DropInfo) -> Bool { store.dragging != nil && !store.draggingSelection }
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

/// Everything you can do with a shot, for the ⋯ button and right-click menus. On a shot that's part
/// of a selection, it acts on the whole selection instead.
struct ShotMenu: View {
    let shot: Shot
    @ObservedObject var store: ShelfStore
    /// Set when the menu belongs to a search result, so Quick Look steps through the results.
    var results: [Shot]? = nil

    var body: some View {
        let group = store.group(for: shot)
        if group.count > 1 {
            Button("Copy \(group.count) Images", systemImage: "doc.on.doc") { store.copy(group) }
            Button("Share \(group.count) Shots…", systemImage: "square.and.arrow.up") { store.share(group) }
            Divider()
            SelectionMenu(shots: group, store: store)
            Divider()
            Button("Move \(group.count) to Trash", systemImage: "trash", role: .destructive) { store.trash(group) }
        } else {
            single
        }
    }

    @ViewBuilder
    private var single: some View {
        if shot.isVideo {
            Button("Copy Recording", systemImage: "doc.on.doc") { store.copy(shot) }
        } else {
            Button("Copy Image", systemImage: "doc.on.doc") { store.copy(shot) }
            Button("Copy Text", systemImage: "text.viewfinder") { store.copyText(shot) }
            Button("Copy with Background", systemImage: "photo.artframe") { store.copyWithBackdrop(shot) }
            Button("Copy Subject", systemImage: "person.and.background.dotted") { store.copySubject(shot) }
        }
        Divider()
        Button("Quick Look", systemImage: "eye") {
            if let results {
                store.quickLook(shot, among: results, follow: { store.searchSelection = $0 })
            } else {
                store.quickLook(shot)
            }
        }
        if shot.isVideo {
            Button("Trim or Make a GIF…", systemImage: "photo.stack") { store.editRecording(shot) }
        } else {
            Button("Float on Screen", systemImage: "pip.enter") { store.float(shot) }
        }
        Button("Share…", systemImage: "square.and.arrow.up") { store.share([shot]) }
        let links = store.links(for: shot)
        if !links.isEmpty {
            Divider()
            ForEach(links) { link in
                Button(link.title, systemImage: link.symbol) { store.use(link) }
            }
        }
        Divider()
        Button(store.isPinned(shot) ? "Unpin" : "Pin", systemImage: store.isPinned(shot) ? "pin.slash" : "pin") {
            store.togglePin(shot)
        }
        if !shot.isVideo {
            Button("Markup and Redact…", systemImage: "pencil.tip.crop.circle") { store.markup(shot) }
            Button("Redact Private Info…", systemImage: "wand.and.sparkles") { store.markup(shot, redactPrivate: true) }
            Button("Translate Text…", systemImage: "translate") { store.translate(shot) }
            Button("Rename from Text", systemImage: "character.cursor.ibeam") { store.smartRename(shot) }
        }
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

/// The actions for several shots at once that don't fit in the footer's buttons. Also in the
/// right-click menu of any selected shot.
struct SelectionMenu: View {
    let shots: [Shot]
    @ObservedObject var store: ShelfStore

    var body: some View {
        let allPinned = shots.allSatisfy(store.isPinned)
        if shots.filter({ !$0.isVideo }).count > 1 {
            Button("Combine Side by Side", systemImage: "rectangle.split.3x1") { store.combine(shots, stacked: false) }
            Button("Combine Stacked", systemImage: "rectangle.split.1x2") { store.combine(shots, stacked: true) }
            Divider()
        }
        Button(allPinned ? "Unpin \(shots.count)" : "Pin \(shots.count)", systemImage: allPinned ? "pin.slash" : "pin") {
            store.togglePin(shots)
        }
        if !store.folders.isEmpty {
            Menu("Move \(shots.count) to", systemImage: "folder") {
                ForEach(store.folders, id: \.self) { folder in
                    Button(folder.lastPathComponent) { store.file(shots, into: folder) }
                }
            }
        }
        Button("Show in Finder", systemImage: "magnifyingglass") {
            NSWorkspace.shared.activateFileViewerSelecting(shots.map(\.url))
        }
        Button("Deselect All", systemImage: "xmark.circle") { store.selection = [] }
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
        if store.draggingSelection {
            store.file(store.selectedShots, into: folder)
            return true
        }
        guard let url = store.dragging, let shot = store.shots.first(where: { $0.url == url }) else { return false }
        store.file(shot, into: folder)
        return true
    }
}

/// A soft band of light that sweeps across a pill every few seconds, to catch the eye. Skipped
/// with Reduce Motion, and it never takes clicks.
struct LightSweep: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: -0.45, repeating: true) { view, position in
                view.overlay { SweepBand(position: position) }
            } keyframes: { _ in
                CubicKeyframe(1.1, duration: 0.9)   // the sweep
                LinearKeyframe(1.1, duration: 2.6)  // then a rest before the next one
            }
        }
    }
}

/// The band itself, at `position` (0 is the pill's left edge, 1 its right).
struct SweepBand: View {
    let position: CGFloat

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.45, height: geo.size.height * 3)
                .rotationEffect(.degrees(20))
                .offset(x: position * geo.size.width, y: -geo.size.height)
        }
        .clipShape(Capsule())
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
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
                OrbMark(size: 34, animated: store.panelVisible)
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

/// A small heading over a group of settings.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(.top, 2)
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

/// The first-launch welcome, in the shelf's place until Get Started. It explains the basics and why
/// macOS is about to ask for access to the screenshot folder, which is only read after it.
private struct WelcomeView: View {
    @ObservedObject var store: ShelfStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The orb, big, over the title; the small panel keeps it beside the title to fit.
            if store.panelSize == .small {
                HStack(spacing: 12) {
                    OrbMark(size: 44, animated: store.panelVisible)
                    titles(alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    OrbMark(size: 88, animated: store.panelVisible)
                    titles(alignment: .center)
                }
                .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 14) {
                if let shortcut = store.shortcut(for: .open) {
                    row("command", "Press \(shortcut.display) in any app, or click the polaroid in the menu bar, to open this shelf.")
                } else {
                    row("menubar.arrow.up.rectangle", "Click the polaroid in the menu bar to open this shelf.")
                }
                row("hand.point.up.left", "Hover a shot to copy it or the text in it, or drag it straight into any app.")
                row("checkmark", "⌘-click to pick several, then copy, share or trash them together.")
                row("pencil.tip.crop.circle", "Press R to mark a shot up or redact it, or F to float it above your windows.")
                row("lock", "Everything stays on your Mac. Next, macOS asks to let ShotShelf see your \(store.folder.lastPathComponent) folder, where your screenshots are saved.")
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Get Started") { store.finishWelcome() }
                    .buttonStyle(.glassProminent).tint(terracotta)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
    }

    private func titles(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("Welcome to ShotShelf").font(.headline)
            Text("Your latest screenshots, one click away").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(terracotta)
                .frame(width: 28, height: 28)
                .glassEffect(.regular.tint(terracotta.opacity(0.18)), in: .circle)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }
}

/// Marks a screen recording's tile: a play symbol and how long it runs.
struct RecordingBadge: View {
    let duration: Double?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill").font(.system(size: 7, weight: .bold))
            if let duration { Text(Recording.label(duration)).font(.system(size: 9, weight: .semibold)).monospacedDigit() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).frame(height: 18)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
    }
}

/// A small round glass button for the footer's selection actions.
private struct FooterButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 11, weight: .medium)).frame(width: 14, height: 14)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
        .help(help)
    }
}

/// Drags the whole selection out as one stack of files: into another app (as copies), or onto a
/// folder chip to move them there. SwiftUI's drags carry a single item, so this is AppKit, laid
/// invisibly over the footer's "selected" label.
private struct SelectionDragArea: NSViewRepresentable {
    @ObservedObject var store: ShelfStore

    func makeNSView(context: Context) -> SelectionDragView {
        let view = SelectionDragView()
        view.store = store
        return view
    }

    func updateNSView(_ view: SelectionDragView, context: Context) {
        view.store = store
    }
}

final class SelectionDragView: NSView, NSDraggingSource {
    weak var store: ShelfStore?
    private var mouseDown: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDown = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDown, let store, !store.selectedShots.isEmpty else { return }
        mouseDown = nil
        let start = convert(down.locationInWindow, from: nil)
        let items = store.selectedShots.enumerated().map { i, shot -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: shot.url as NSURL)
            let image = store.thumbnails[shot.url] ?? store.minis[shot.url] ?? NSWorkspace.shared.icon(forFile: shot.url.path)
            let height = min(max(80 * image.size.height / max(image.size.width, 1), 40), 100)
            let offset = CGFloat(min(i, 4)) * 4
            item.setDraggingFrame(NSRect(x: start.x - 40 + offset, y: start.y - height / 2 - offset, width: 80, height: height),
                                  contents: image)
            return item
        }
        store.dragging = store.selectedShots.first?.url
        store.draggingSelection = true
        beginDraggingSession(with: items, event: down, source: self).draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Other apps get copies, so screenshots never vanish from the shelf by surprise; folder
        // chips move them.
        context == .withinApplication ? [.move, .copy] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store?.dragging = nil
        store?.draggingSelection = false
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
