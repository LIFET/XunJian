import SwiftUI

enum SidebarNavigationStep {
    static func destination(current: NavigationDestination?, destinations: [NavigationDestination], forward: Bool) -> NavigationDestination? {
        guard !destinations.isEmpty else { return nil }
        guard let current, let index = destinations.firstIndex(of: current) else {
            return forward ? destinations.first : destinations.last
        }
        return destinations[min(destinations.count - 1, max(0, index + (forward ? 1 : -1)))]
    }
}

struct SidebarView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.appVisualTheme) private var visualTheme
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: NavigationDestination?
    let categories: [FileCategory]

    @State private var searchToRename: SavedSearch?
    @State private var searchToDelete: SavedSearch?
    @State private var renameDraft = ""
    @State private var showsSaveSearch = false
    @State private var savedSearchDraft = ""
    @State private var dropTargetCategoryIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppLanguage.localized("资源目录", english: "Directory"))
                    .font(.headline)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .xunJianShowCommandPalette, object: nil)
                } label: { Image(systemName: "command") }
                .buttonStyle(XunJianIconButtonStyle())
                .help(AppLanguage.localized("快速前往（⌘K）", english: "Quick Switch (⌘K)"))
                .accessibilityLabel(AppLanguage.localized("打开命令面板", english: "Open Command Palette"))
            }
            .padding(16)
            List(selection: $selection) {

                Section {
                    if appModel.savedSearches.isEmpty {
                        Text(AppLanguage.localized("保存常用条件，一键再次查找。", english: "Save filters to find them again."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(appModel.savedSearches) { search in
                        Button {
                            appModel.applySavedSearch(search)
                            selection = .allFiles
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(verbatim: search.name)
                                            .lineLimit(1)
                                        if isCurrentSavedSearch(search) {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(Color.accentColor)
                                                .accessibilityLabel(AppLanguage.localized(
                                                    "当前条件",
                                                    english: "Current filters"
                                                ))
                                        }
                                    }
                                }
                            } icon: {
                                Image(systemName: "bookmark")
                                    .symbolRenderingMode(.hierarchical)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(search.conditionSummary(usesEnglish: AppLanguage.selected.usesEnglish))
                        .contextMenu {
                            Button(AppLanguage.localized("重命名…", english: "Rename…")) {
                                searchToRename = search
                                renameDraft = search.name
                            }
                            Button(AppLanguage.localized(
                                "用当前条件更新",
                                english: "Update with Current Filters"
                            )) {
                                appModel.updateSavedSearch(search)
                            }
                            .disabled(selection != .allFiles)
                            Divider()
                            Button(
                                AppLanguage.localized("删除保存的搜索", english: "Delete Saved Search"),
                                role: .destructive
                            ) {
                                searchToDelete = search
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(AppLanguage.localized("保存的搜索", english: "Saved Searches"))
                        Spacer()
                        Button {
                            savedSearchDraft = appModel.searchText
                            showsSaveSearch = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(XunJianIconButtonStyle())
                        .disabled(selection != .allFiles || !canSaveCurrentSearch(named: "Search"))
                        .help(AppLanguage.localized("保存当前搜索条件", english: "Save Current Search"))
                        .accessibilityLabel(AppLanguage.localized("保存当前搜索条件", english: "Save Current Search"))
                    }
            }

            Section(AppLanguage.localized("资料集", english: "Collections")) {
                ForEach(categories) { category in
                    navigationRow(
                        Text(verbatim: category.localizedDisplayName),
                        symbol: category.symbolName,
                        destination: .category(category.id)
                    )
                    // Drop a file onto a category to file it there (F06).
                    .dropDestination(for: URL.self) { urls, _ in
                        appModel.assignDroppedFiles(urls: urls, to: category)
                    } isTargeted: { targeted in
                        if targeted {
                            dropTargetCategoryIDs.insert(category.id)
                        } else {
                            dropTargetCategoryIDs.remove(category.id)
                        }
                    }
                    .listRowBackground(
                        dropTargetCategoryIDs.contains(category.id)
                            ? XunJianUI.Fill.selectedSoft
                            : Color.clear
                    )
                }
            }

        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 32)
        Divider().padding(.horizontal, 16)
        Button {
            NotificationCenter.default.post(name: .xunJianShowStorageInsights, object: nil)
        } label: {
            Label(AppLanguage.localized("存储概览", english: "Storage Overview"), systemImage: "chart.bar.xaxis")
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityIdentifier("sidebar.storageOverview")
        .accessibilityLabel(AppLanguage.localized("存储概览", english: "Storage Overview"))
        .padding(.bottom, 12)
        }
        .background(visualTheme.palette(for: colorScheme).sidebar)
        .alert(AppLanguage.localized("保存搜索", english: "Save Search"), isPresented: $showsSaveSearch) {
            TextField(AppLanguage.localized("名称", english: "Name"), text: $savedSearchDraft)
            Button(AppLanguage.localized("保存", english: "Save")) {
                appModel.saveSearch(name: savedSearchDraft, query: appModel.searchText,
                                    minSizeBytes: appModel.minimumFilterSizeBytes,
                                    minDate: appModel.filterMinDate > 0 ? Date(timeIntervalSince1970: appModel.filterMinDate) : nil)
            }
            .disabled(!canSaveCurrentSearch(named: savedSearchDraft))
            Button(AppLanguage.localized("取消", english: "Cancel"), role: .cancel) { }
        }
        .alert(
            AppLanguage.localized("重命名保存的搜索", english: "Rename Saved Search"),
            isPresented: Binding(
                get: { searchToRename != nil },
                set: { if !$0 { searchToRename = nil } }
            )
        ) {
            TextField(
                AppLanguage.localized("名称", english: "Name"),
                text: $renameDraft
            )
            Button(AppLanguage.localized("保存", english: "Save")) {
                if let searchToRename {
                    appModel.renameSavedSearch(searchToRename, to: renameDraft)
                }
                searchToRename = nil
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(AppLanguage.localized("取消", english: "Cancel"), role: .cancel) {
                searchToRename = nil
            }
        }
        .confirmationDialog(
            AppLanguage.localized(
                "删除保存的搜索？",
                english: "Delete Saved Search?"
            ),
            isPresented: Binding(
                get: { searchToDelete != nil },
                set: { if !$0 { searchToDelete = nil } }
            )
        ) {
            Button(
                AppLanguage.localized("删除", english: "Delete"),
                role: .destructive
            ) {
                if let searchToDelete {
                    appModel.deleteSearch(id: searchToDelete.id)
                }
                searchToDelete = nil
            }
            Button(AppLanguage.localized("取消", english: "Cancel"), role: .cancel) {
                searchToDelete = nil
            }
        } message: {
            if let searchToDelete {
                Text(verbatim: searchToDelete.name)
            }
        }
    }

    private func navigationRow(
        _ title: Text,
        symbol: String,
        destination: NavigationDestination
    ) -> some View {
        NavigationLink(value: destination) {
            Label {
                title.lineLimit(1)
            } icon: {
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
            }
            .font(.system(size: 13))
        }
        .listRowSeparator(.hidden)
        .accessibilityLabel(title)
        .tag(destination)
        .id(destination)
    }

    private func isCurrentSavedSearch(_ search: SavedSearch) -> Bool {
        appModel.aiSearchResults == nil
            && search.matches(
                query: appModel.searchText,
                minSizeBytes: Int64(appModel.filterMinSizeMB * 1_024 * 1_024),
                minDate: appModel.filterMinDate > 0
                    ? Date(timeIntervalSince1970: appModel.filterMinDate)
                    : nil,
                fileKind: appModel.selectedKind
            )
    }

    private func canSaveCurrentSearch(named name: String) -> Bool {
        AllFilesView.canSaveSearch(name: name, query: appModel.searchText,
                                 hasManualFilter: appModel.minimumFilterSizeBytes > 0 || appModel.filterMinDate > 0,
                                 kind: appModel.selectedKind)
    }
}
