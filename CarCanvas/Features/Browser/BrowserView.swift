import SwiftUI
import UniformTypeIdentifiers

/// The original in-app file browser.
///
/// It has two roots, exactly as the upstream copy describes:
///   * Workspace — this app's own Documents folder ("On My iPhone")
///   * an app's data container, reached through worse_query
/// Both are browsed with the same UI. Operations are limited to the workspace
/// for writing; containers are only shown read-only for the cache files the
/// app already restricts itself to.
struct BrowserView: View {
    @StateObject private var containers = AppContainerStore()

    @State private var items: [WorkspaceFile] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var alertMessage: String?
    @State private var showNewFolder = false
    @State private var showNewFile = false
    @State private var newName = ""
    @State private var renameTarget: WorkspaceFile?
    @State private var renameName = ""
    @State private var deleteTarget: WorkspaceFile?
    @State private var showImporter = false
    @State private var importConflict: URL?
    @State private var containerFiles: [WallpaperTarget] = []

    private var currentDirectory: URL { Workspace.root }
    private var atRoot: Bool { true }

    var body: some View {
        List {
            if atRoot { rootsSection }
            if !containerFiles.isEmpty { containerSection }
            filesSection
        }
        .navigationTitle(L("BROWSER_TITLE"))
        .searchable(text: $searchText, prompt: Text(atRoot ? L("BROWSER_SEARCH") : L("BROWSER_SEARCH_FILES")))
        .toolbar { toolbarContent }
        .task { reload() }
        .refreshable { reload() }
        .alert(L("COMMON_ERROR"), isPresented: Binding(
            get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button(L("COMMON_OK")) { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
        .alert(L("BROWSER_IMPORT_CONFLICT_TITLE"), isPresented: Binding(
            get: { importConflict != nil }, set: { if !$0 { importConflict = nil } })) {
            Button(L("BROWSER_KEEP_BOTH")) { resolveImport(keepBoth: true) }
            Button(L("BROWSER_REPLACE")) { resolveImport(keepBoth: false) }
            Button(L("COMMON_CANCEL"), role: .cancel) { importConflict = nil }
        } message: {
            Text(LF("BROWSER_IMPORT_CONFLICT_MESSAGE", importConflict?.lastPathComponent ?? ""))
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .alert(L("BROWSER_NEW_FOLDER"), isPresented: $showNewFolder) {
            TextField(L("BROWSER_NEW_FOLDER_DEFAULT"), text: $newName)
            Button(L("COMMON_OK")) { createFolder() }
            Button(L("COMMON_CANCEL"), role: .cancel) {}
        }
        .alert(L("BROWSER_NEW_FILE"), isPresented: $showNewFile) {
            TextField(L("BROWSER_NEW_FILE"), text: $newName)
            Button(L("COMMON_OK")) { createFile() }
            Button(L("COMMON_CANCEL"), role: .cancel) {}
        }
        .alert(L("BROWSER_RENAME"), isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField(L("BROWSER_RENAME"), text: $renameName)
            Button(L("COMMON_OK")) { performRename() }
            Button(L("COMMON_CANCEL"), role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(L("BROWSER_DELETE_TITLE"), isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget) { target in
            Button(L("BROWSER_DELETE"), role: .destructive) { performDelete(target) }
        } message: { target in
            Text(LF("BROWSER_DELETE_MESSAGE", target.name))
        }
    }

    // MARK: - Sections

    private var rootsSection: some View {
        Section(L("BROWSER_WORKSPACE")) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("BROWSER_WORKSPACE_NAME"))
                    Text(L("BROWSER_WORKSPACE_SUBTITLE"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "folder")
            }

            if containers.isScanning {
                HStack { ProgressView(); Text(L("BROWSER_MHA_SCANNING")) }
            } else if let containerError = containers.lastError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(containerError).font(.footnote).foregroundStyle(.secondary)
                    Button(L("BROWSER_RETRY")) { containers.scanIfNeeded(force: true) }
                }
            } else {
                NavigationLink {
                    ContainerBrowserView(entry: nil, store: containers)
                } label: {
                    Label(L("BROWSER_APPS_COUNT").replacingOccurrences(of: "%ld", with: "\(containers.entries.count)"),
                          systemImage: "shippingbox")
                }
            }
        }
    }

    private var containerSection: some View {
        Section(L("BROWSER_TITLE")) {
            ForEach(containerFiles) { target in
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.fileName).font(.footnote.monospaced())
                    Text(LF("BROWSER_ITEM_DETAIL",
                            target.appearance == .dark ? L("WALLPAPER_SET_DARK") : L("WALLPAPER_SET_LIGHT"),
                            "\(target.byteCount)"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filesSection: some View {
        Section {
            if isLoading {
                HStack { ProgressView(); Text(L("BROWSER_LOADING")) }
            } else if filteredItems.isEmpty {
                Text(searchText.isEmpty ? L("BROWSER_EMPTY_FOLDER") : L("BROWSER_SEARCH_FILES_EMPTY"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredItems) { item in
                    row(for: item)
                }
            }
        } header: {
            if !atRoot {
                Text(LF("BROWSER_ITEMS_COUNT", "\(filteredItems.count)"))
            }
        }
    }

    private func row(for item: WorkspaceFile) -> some View {
        Group {
            if item.isDirectory {
                NavigationLink {
                    BrowserDirectoryView(directory: item.url)
                } label: {
                    Label(item.name, systemImage: "folder")
                }
            } else {
                HStack {
                    Image(systemName: item.isCPBitmap ? "photo" : "doc")
                    Text(item.name).font(.body)
                    Spacer()
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button(L("BROWSER_SHARE")) { share(item) }
                    Button(L("BROWSER_DUPLICATE")) { duplicate(item) }
                    Button(L("BROWSER_COPY_PATH")) { copyPath(item) }
                    Button(L("BROWSER_RENAME")) { startRename(item) }
                    Button(L("BROWSER_DELETE"), role: .destructive) { deleteTarget = item }
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) { deleteTarget = item } label: {
                Label(L("BROWSER_DELETE"), systemImage: "trash")
            }
            Button { startRename(item) } label: {
                Label(L("BROWSER_RENAME"), systemImage: "pencil")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(L("BROWSER_NEW_FOLDER")) {
                    newName = L("BROWSER_NEW_FOLDER_DEFAULT"); showNewFolder = true
                }
                Button(L("BROWSER_NEW_FILE")) { newName = ""; showNewFile = true }
                Button(L("BROWSER_IMPORT")) { showImporter = true }
            } label: {
                Label(L("BROWSER_ADD"), systemImage: "plus")
            }
        }
    }

    // MARK: - Data

    private var filteredItems: [WorkspaceFile] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func reload() {
        isLoading = true
        containers.scanIfNeeded()
        do {
            items = try Workspace.list(currentDirectory)
        } catch {
            items = []
            alertMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Operations (workspace only)

    private func createFolder() {
        do {
            let name = try Workspace.validate(name: newName)
            try FileManager.default.createDirectory(at: currentDirectory.appendingPathComponent(name),
                                                    withIntermediateDirectories: false)
            reload()
        } catch {
            alertMessage = (error as? CCError)?.localizedDescription ?? L("BROWSER_ERROR_CREATE")
        }
    }

    private func createFile() {
        do {
            let name = try Workspace.validate(name: newName)
            let url = currentDirectory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw CCError.invalidName }
            try Data().write(to: url)
            reload()
        } catch {
            alertMessage = (error as? CCError)?.localizedDescription ?? L("BROWSER_ERROR_CREATE")
        }
    }

    private func startRename(_ item: WorkspaceFile) {
        renameName = item.name
        renameTarget = item
    }

    private func performRename() {
        guard let target = renameTarget else { return }
        defer { renameTarget = nil }
        do {
            let name = try Workspace.validate(name: renameName)
            let destination = target.url.deletingLastPathComponent().appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CCError.invalidName
            }
            try FileManager.default.moveItem(at: target.url, to: destination)
            reload()
        } catch {
            alertMessage = (error as? CCError)?.localizedDescription ?? L("BROWSER_ERROR_RENAME")
        }
    }

    private func performDelete(_ target: WorkspaceFile) {
        defer { deleteTarget = nil }
        do {
            try FileManager.default.removeItem(at: target.url)
            reload()
        } catch { alertMessage = L("BROWSER_ERROR_DELETE") }
    }

    private func duplicate(_ item: WorkspaceFile) {
        do {
            let destination = Workspace.uniqueURL(in: currentDirectory, preferredName: item.name)
            try FileManager.default.copyItem(at: item.url, to: destination)
            reload()
        } catch { alertMessage = L("BROWSER_ERROR_CREATE") }
    }

    private func copyPath(_ item: WorkspaceFile) {
        UIPasteboard.general.string = item.url.path
    }

    private func share(_ item: WorkspaceFile) {
        let controller = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        root.present(controller, animated: true)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            alertMessage = L("BROWSER_ERROR_SOURCE_MISSING")
        case .success(let urls):
            guard let first = urls.first else { return }
            let destination = currentDirectory.appendingPathComponent(first.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                importConflict = first
                return
            }
            importAll(urls)
        }
    }

    private func resolveImport(keepBoth: Bool) {
        guard let source = importConflict else { return }
        importConflict = nil
        if keepBoth {
            let destination = Workspace.uniqueURL(in: currentDirectory,
                                                  preferredName: source.lastPathComponent)
            copyIntoWorkspace(source, to: destination)
        } else {
            copyIntoWorkspace(source,
                              to: currentDirectory.appendingPathComponent(source.lastPathComponent))
        }
    }

    private func importAll(_ urls: [URL]) {
        for url in urls {
            let destination = Workspace.uniqueURL(in: currentDirectory,
                                                  preferredName: url.lastPathComponent)
            copyIntoWorkspace(url, to: destination, reloadAfter: url == urls.last)
        }
    }

    private func copyIntoWorkspace(_ source: URL, to destination: URL, reloadAfter: Bool = true) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            alertMessage = L("BROWSER_ERROR_IMPORT")
        }
        if reloadAfter { reload() }
    }
}

/// Child listing used when descending into a workspace folder. Kept separate so
/// each directory level owns its own listing state.
struct BrowserDirectoryView: View {
    let directory: URL
    @State private var items: [WorkspaceFile] = []
    @State private var isLoading = false

    var body: some View {
        List {
            if isLoading {
                HStack { ProgressView(); Text(L("BROWSER_LOADING")) }
            } else if items.isEmpty {
                Text(L("BROWSER_EMPTY_FOLDER")).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    if item.isDirectory {
                        NavigationLink {
                            BrowserDirectoryView(directory: item.url)
                        } label: {
                            Label(item.name, systemImage: "folder")
                        }
                    } else {
                        Label(item.name, systemImage: item.isCPBitmap ? "photo" : "doc")
                    }
                }
            }
        }
        .navigationTitle(directory.lastPathComponent)
        .task { load() }
    }

    private func load() {
        isLoading = true
        items = (try? Workspace.list(directory)) ?? []
        isLoading = false
    }
}

/// Read-only listing of one app data container, reached through worse_query.
/// No write operations are offered here at all.
struct ContainerBrowserView: View {
    let entry: AppContainerStore.Entry?
    @ObservedObject var store: AppContainerStore
    @State private var files: [WorkspaceFile] = []
    @State private var alertMessage: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if entry == nil {
                containerListContent
            } else if isLoading {
                HStack { ProgressView(); Text(L("BROWSER_LOADING")) }
            } else if files.isEmpty {
                Text(L("BROWSER_EMPTY_FOLDER")).foregroundStyle(.secondary)
            } else {
                ForEach(files) { item in
                    Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                }
            }
        }
        .navigationTitle(navigationTitle)
        .task { await load() }
        .alert(L("COMMON_ERROR"), isPresented: Binding(
            get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button(L("COMMON_OK")) { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
    }

    @ViewBuilder
    private var containerListContent: some View {
        if store.isScanning {
            HStack { ProgressView(); Text(L("BROWSER_MHA_SCANNING")) }
        } else if store.entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.lastError ?? L("BROWSER_EMPTY"))
                    .font(.footnote).foregroundStyle(.secondary)
                Button(L("BROWSER_RETRY")) { store.scanIfNeeded(force: true) }
            }
        } else {
            ForEach(store.entries) { item in
                NavigationLink {
                    ContainerBrowserView(entry: item, store: store)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName).font(.footnote)
                        Text(item.bundleID).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var navigationTitle: String {
        if let entry { return entry.displayName }
        return L("BROWSER_WORKSPACE")
    }

    private func load() async {
        guard let entry else { return }
        isLoading = true
        let outcome = await Task.detached(priority: .userInitiated) { () -> ([WorkspaceFile], String?) in
            do {
                let listed = try WQAccess.shared.withAccess(containerPath: entry.id) {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: entry.id)) ?? []
                    return names.compactMap { name -> WorkspaceFile? in
                        let path = entry.id + "/" + name
                        var st = stat()
                        guard lstat(path, &st) == 0 else { return nil }
                        let isDir = (st.st_mode & UInt16(S_IFMT)) == UInt16(S_IFDIR)
                        return WorkspaceFile(url: URL(fileURLWithPath: path),
                                             isDirectory: isDir,
                                             byteCount: Int(st.st_size),
                                             modified: .distantPast)
                    }
                }
                return (listed, nil)
            } catch {
                return ([], error.localizedDescription)
            }
        }.value
        files = outcome.0
        alertMessage = outcome.1
        isLoading = false
    }
}
