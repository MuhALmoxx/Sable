import SwiftUI
import LibraryKit

// OWNER: library agent.
struct LibraryScreen: View {
    @Environment(AppServices.self) private var services

    @State private var search = ""
    @State private var showVideoPicker = false
    @State private var showSettings = false
    @State private var subtitleTarget: MediaItem?
    @State private var isRenaming = false
    @State private var renameItemID: UUID?
    @State private var renameText = ""
    @State private var removalTarget: MediaItem?
    @FocusState private var searchFocused: Bool

    var body: some View {
        // Reading the revision makes the screen refresh whenever the library changes.
        let _ = services.libraryRevision
        let allItems = services.library.items
        let items = LibraryQuery.apply(allItems, search: search, sort: services.settings.librarySort)
        let jobs = services.imports.jobs

        VStack(spacing: 0) {
            header(count: allItems.count, isEmpty: allItems.isEmpty)
            if !allItems.isEmpty {
                searchBar
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.sm)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            content(items: items, allItems: allItems, jobs: jobs)
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showSettings) { SettingsScreen() }
        .sheet(isPresented: $showVideoPicker) {
            DocumentPicker(contentTypes: ImportPaths.videoTypes, allowsMultipleSelection: true, onPick: { urls in
                showVideoPicker = false
                services.importVideos(urls)
            }, onCancel: {
                showVideoPicker = false
            })
            .ignoresSafeArea()
        }
        .sheet(item: $subtitleTarget) { item in
            DocumentPicker(contentTypes: ImportPaths.subtitleTypes, allowsMultipleSelection: true, onPick: { urls in
                subtitleTarget = nil
                services.attachSubtitles(urls, to: item.id)
            }, onCancel: {
                subtitleTarget = nil
            })
            .ignoresSafeArea()
        }
        .alert("Rename video", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
                .accessibilityIdentifier(AX.Library.renameField)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renameItemID = nil }
        } message: {
            Text("Changes the title shown in Sable. The file itself keeps its name.")
        }
        .confirmationDialog(removalTitle, isPresented: removalPresented, titleVisibility: .visible, presenting: removalTarget) { item in
            Button("Remove", role: .destructive) { remove(item) }
                .accessibilityIdentifier(AX.Library.remove)
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: { _ in
            Text("Deletes the video, its subtitles, translations and timing from Sable on this iPhone. The original in Files is not touched.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Library.screen)
    }

    // MARK: Header

    private func header(count: Int, isEmpty: Bool) -> some View {
        HStack(alignment: .center, spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SABLE")
                    .font(Typo.display)
                    .tracking(2)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityLabel("Sable")
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: count == 1 ? "1 VIDEO" : "\(count) VIDEOS")
                    .font(Typo.micro)
                    .tracking(1)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityLabel(Text(verbatim: count == 1 ? "1 video" : "\(count) videos"))
            }
            Spacer(minLength: Spacing.xs)
            if !isEmpty {
                PixelIconButton(services.settings.libraryUsesGrid ? .list : .grid,
                                label: services.settings.libraryUsesGrid ? "Show as list" : "Show as grid",
                                size: 18) {
                    services.settings.libraryUsesGrid.toggle()
                }
                .accessibilityIdentifier(AX.Library.layoutToggle)
            }
            PixelIconButton(.settings, label: "Settings", size: 20) {
                searchFocused = false
                showSettings = true
            }
            .accessibilityIdentifier(AX.Library.settings)
            if !isEmpty {
                importButton(title: "Import")
            }
        }
        .padding(.leading, Spacing.md)
        .padding(.trailing, Spacing.xs)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.sm)
    }

    private func importButton(title: String) -> some View {
        Button {
            searchFocused = false
            showVideoPicker = true
        } label: {
            HStack(spacing: Spacing.xs) {
                PixelIcon(.plus, size: 14, color: Palette.onAccent)
                Text(title)
            }
        }
        .buttonStyle(PixelButtonStyle(kind: .primary))
        .accessibilityLabel(title == "Import" ? "Import videos" : title)
        .accessibilityHint("Opens Files to choose videos")
        .accessibilityIdentifier(AX.Library.importVideo)
    }

    // MARK: Search and sort

    private var searchBar: some View {
        HStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                PixelIcon(.search, size: 16, color: Palette.textTertiary)
                TextField("", text: $search, prompt: Text("Search titles").foregroundStyle(Palette.textTertiary))
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .accessibilityLabel("Search library")
                    .accessibilityIdentifier(AX.Library.search)
                if !search.isEmpty {
                    PixelIconButton(.close, label: "Clear search", size: 12) { search = "" }
                        .accessibilityIdentifier(AX.Library.clearSearch)
                }
            }
            .padding(.leading, Spacing.sm)
            .frame(minHeight: Spacing.touch)
            .frame(maxWidth: .infinity)
            .pixelPanel(fill: Palette.surface, border: searchFocused ? Palette.borderStrong : Palette.border)

            sortMenu
        }
    }

    private var sortMenu: some View {
        let current = services.settings.librarySort
        return Menu {
            Picker("Sort by", selection: Binding(
                get: { services.settings.librarySort },
                set: { services.settings.librarySort = $0 }
            )) {
                ForEach(LibrarySort.allCases, id: \.self) { sort in
                    Text(sort.label).tag(sort)
                }
            }
        } label: {
            HStack(spacing: 6) {
                PixelIcon(.sort, size: 16, color: Palette.textPrimary)
                Text(shortLabel(current))
                    .font(Typo.callout)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: Spacing.touch)
            .pixelPanel(fill: Palette.surface)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Sort")
        .accessibilityValue(current.label)
        .accessibilityIdentifier(AX.Library.sort)
    }

    private func shortLabel(_ sort: LibrarySort) -> String {
        switch sort {
        case .recentlyAdded: return "Added"
        case .recentlyPlayed: return "Played"
        case .title: return "A–Z"
        case .duration: return "Length"
        case .size: return "Size"
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(items: [MediaItem], allItems: [MediaItem], jobs: [ImportCoordinator.Job]) -> some View {
        if allItems.isEmpty && jobs.isEmpty {
            LibraryEmptyState { importButton(title: "Import a video from Files") }
        } else if items.isEmpty && jobs.isEmpty {
            noResults
        } else if services.settings.libraryUsesGrid {
            grid(items: items, jobs: jobs)
        } else {
            list(items: items, jobs: jobs)
        }
    }

    private var noResults: some View {
        VStack(spacing: Spacing.md) {
            Spacer(minLength: Spacing.xl)
            PixelMessage(glyph: .search, title: "No matches",
                         message: "Nothing in your library matches “\(search.trimmingCharacters(in: .whitespaces))”.")
            Button("Clear search") { search = "" }
                .buttonStyle(PixelButtonStyle(kind: .secondary))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Library.noResults)
    }

    private func list(items: [MediaItem], jobs: [ImportCoordinator.Job]) -> some View {
        List {
            ForEach(jobs) { job in
                ImportJobRow(job: job) { services.imports.dismiss(job.id) }
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.xs))
                    .listRowBackground(Palette.surface)
                    .listRowSeparatorTint(Palette.border)
            }
            ForEach(items) { item in
                LibraryRow(item: item, thumbnail: services.thumbnails.image(for: item),
                           showResumeHint: services.settings.resumePlayback) { play(item) }
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md))
                    .listRowBackground(Palette.background)
                    .listRowSeparatorTint(Palette.border)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { removalTarget = item } label: { Text("Remove") }
                            .tint(Palette.danger)
                        Button { beginRename(item) } label: { Text("Rename") }
                            .tint(Palette.surfaceHigh)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { subtitleTarget = item } label: { Text("Subtitle") }
                            .tint(Palette.surfaceHigh)
                        if hasProgress(item) {
                            Button { markUnwatched(item) } label: { Text("Unwatched") }
                                .tint(Palette.borderStrong)
                        }
                    }
                    .contextMenu { itemMenu(item) }
                    .accessibilityActions { accessibilityActions(item) }
                    .task(id: item.id) {
                        await services.imports.repairMetadataIfNeeded(for: item, services: services)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .scrollDismissesKeyboard(.immediately)
        .environment(\.defaultMinListRowHeight, Spacing.touch)
    }

    private func grid(items: [MediaItem], jobs: [ImportCoordinator.Job]) -> some View {
        ScrollView {
            VStack(spacing: Spacing.sm) {
                ForEach(jobs) { job in
                    ImportJobRow(job: job) { services.imports.dismiss(job.id) }
                        .padding(.horizontal, Spacing.sm)
                        .pixelPanel(fill: Palette.surface)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.md, alignment: .top),
                                    GridItem(.flexible(), spacing: Spacing.md, alignment: .top)],
                          alignment: .leading, spacing: Spacing.lg) {
                    ForEach(items) { item in
                        LibraryGridCell(item: item, thumbnail: services.thumbnails.image(for: item),
                                        showResumeHint: services.settings.resumePlayback) { play(item) }
                            .contextMenu { itemMenu(item) }
                            .accessibilityActions { accessibilityActions(item) }
                            .task(id: item.id) {
                                await services.imports.repairMetadataIfNeeded(for: item, services: services)
                            }
                    }
                }
            }
            .padding(Spacing.md)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func itemMenu(_ item: MediaItem) -> some View {
        Button("Rename") { beginRename(item) }
            .accessibilityIdentifier(AX.Library.rename)
        Button("Add subtitle file") { subtitleTarget = item }
            .accessibilityIdentifier(AX.Library.addSubtitle)
        if hasProgress(item) {
            Button("Mark as unwatched") { markUnwatched(item) }
                .accessibilityIdentifier(AX.Library.markUnwatched)
        }
        Divider()
        Button("Remove", role: .destructive) { removalTarget = item }
            .accessibilityIdentifier(AX.Library.remove)
    }

    @ViewBuilder
    private func accessibilityActions(_ item: MediaItem) -> some View {
        Button("Rename") { beginRename(item) }
        Button("Add subtitle file") { subtitleTarget = item }
        if hasProgress(item) {
            Button("Mark as unwatched") { markUnwatched(item) }
        }
        Button("Remove") { removalTarget = item }
    }

    // MARK: Actions

    private func play(_ item: MediaItem) {
        searchFocused = false
        let url = services.library.mediaURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            services.banner = "The video file for “\(item.title)” is missing. Remove it and import it again."
            return
        }
        services.playingItemID = item.id
    }

    private func hasProgress(_ item: MediaItem) -> Bool {
        item.playback.position > 0 || item.playback.completed || item.lastPlayedAt != nil
    }

    private func beginRename(_ item: MediaItem) {
        renameText = item.title
        renameItemID = item.id
        isRenaming = true
    }

    private func commitRename() {
        guard let id = renameItemID else { return }
        renameItemID = nil
        do {
            try services.library.rename(itemID: id, to: renameText)
            services.libraryDidChange()
        } catch {
            services.banner = "Could not rename the video: \(error.localizedDescription)"
        }
    }

    private func markUnwatched(_ item: MediaItem) {
        do {
            try services.library.markUnwatched(itemID: item.id)
            services.libraryDidChange()
        } catch {
            services.banner = "Could not update “\(item.title)”: \(error.localizedDescription)"
        }
    }

    private func remove(_ item: MediaItem) {
        removalTarget = nil
        do {
            try services.removeItem(id: item.id)
        } catch {
            services.banner = "Could not remove “\(item.title)”: \(error.localizedDescription)"
        }
    }

    private var removalTitle: String {
        guard let item = removalTarget else { return "Remove video?" }
        return "Remove “\(item.title)”?"
    }

    private var removalPresented: Binding<Bool> {
        Binding(get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } })
    }
}
