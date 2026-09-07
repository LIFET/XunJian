import AppKit
import SwiftUI
import XCTest
import PDFKit
@testable import XunJian

/// 显式开启的原生视图截图验收；不与默认单元测试混跑。
final class ThemeLayoutSnapshotTests: XCTestCase {
    @MainActor
    func testThousandDuplicateGroupsRenderAndScrollInNativeWindow() async throws {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let suite = "XunJian.DuplicateLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = SnapshotDeniedOAuthBridge()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let model = AppModel(oauthBridgeService: bridge,
            credentialStore: LocalCredentialStore(fileURL: output.appendingPathComponent("unused.json")),
            aiConfigurationStore: AIConfigurationStore(defaults: defaults), filterPreferences: defaults)
        defer { model.index.cancelAllTasks(); model.ai.cancelAllTasks(); model.oauth.applicationResignedActive() }
        let groups = (0..<1000).map { number in
            DuplicateGroup(hash: "group-\(number)", size: 1024, files: (0..<3).map { copy in
                IndexedFile(id: "\(number)-\(copy)", sourceID: UUID(), name: "长文件名-\(number)-\(copy).txt", path: output.appendingPathComponent("\(number)-\(copy).txt").path,
                    fileExtension: "txt", kind: .document, size: 1024, createdAt: nil, modifiedAt: nil, indexedAt: Date())
            })
        }
        func exercise(_ host: NSView) async throws {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            XCTAssertGreaterThanOrEqual(host.bounds.width, 420)
            XCTAssertGreaterThanOrEqual(host.bounds.height, 620)
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            for candidate in scrollViews(host) { print("DUPLICATE_SCROLL_GEOMETRY=\(candidate.frame) doc=\(String(describing: candidate.documentView?.frame))") }
            // SwiftUI AX nodes implement these Objective-C methods without declaring
            // NSAccessibilityProtocol conformance. A protocol cast drops real rows.
            func disclosures(_ element: AnyObject) -> [AnyObject] {
                if element.accessibilityRole?() == .disclosureTriangle { return [element] }
                let children = element.accessibilityChildren?() ?? []
                return children.flatMap { disclosures($0 as AnyObject) }
            }
            let disclosure = try XCTUnwrap(disclosures(host).first)
            func expandedValue(_ element: AnyObject) -> Int? {
                // AppKit declares multiple return types for this ObjC selector.
                let value = (element as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
                return (value as? NSNumber)?.intValue
            }
            func expectExpansion(_ expected: Int) async throws {
                for _ in 0..<40 {
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    if let row = disclosures(host).first, expandedValue(row) == expected { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(expandedValue(try XCTUnwrap(disclosures(host).first)), expected)
            }
            XCTAssertEqual(expandedValue(disclosure), 0)
            XCTAssertTrue(disclosure.accessibilityPerformPress?() == true)
            try await expectExpansion(1)
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let expanded = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: expanded)
            try XCTUnwrap(expanded.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("duplicates-expanded.png"))
            XCTAssertTrue(disclosure.accessibilityPerformPress?() == true)
            try await expectExpansion(0)
            let scroll = try XCTUnwrap(scrollViews(host).max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
            XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, 40_000)
            if ProcessInfo.processInfo.environment["XUNJIAN_DUPLICATE_INTERACTIVE"] == "1" {
                print("DUPLICATE_INTERACTIVE_READY")
                fflush(stdout)
                for _ in 0..<450 { try await Task.sleep(for: .milliseconds(100)) }
            }
            let start = Date()
            for fraction in [0.0, 0.5, 1.0, 0.2, 0.0] {
                let height = scroll.documentView?.bounds.height ?? 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scroll.contentView.bounds.height) * fraction))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
            }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 10, "1000组原生布局/滚动出现长阻塞")
            print("DUPLICATE_1000_GROUP_LAYOUT_SCROLL_SECONDS=\(elapsed)")
            let returnedDisclosure = try XCTUnwrap(disclosures(host).first)
            XCTAssertTrue(returnedDisclosure.accessibilityPerformPress?() == true)
            try await expectExpansion(1)
            XCTAssertTrue(returnedDisclosure.accessibilityPerformPress?() == true)
            try await expectExpansion(0)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("live-scroll.png"))
            print("DUPLICATE_LIVE_DIRECTORY=\(output.path)")
        }
        try await capture(StorageInsightsView(initialDuplicateGroups: groups), model: model, defaults: defaults,
            theme: .precision, scheme: .light, size: NSSize(width: 420, height: 620), name: "duplicates-1000", output: output, exercise: exercise)
        print("DUPLICATE_LAYOUT_DIRECTORY=\(output.path)")
        for width: CGFloat in [360, 420] {
            try await capture(StorageInsightsView.summaryMetrics(fileCount: 123_456_789, totalSize: 9_876_543_210_000, sourceCount: 1234).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white),
                model: model, defaults: defaults, theme: .precision, scheme: .light,
                size: NSSize(width: width, height: 420), name: "summary-\(Int(width))", output: output)
        }
        let calls = await bridge.callCount
        XCTAssertEqual(calls, 0)
    }
    @MainActor
    func testSettingsAlignmentSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["XUNJIAN_THEME_SNAPSHOTS"] == "1" else {
            throw XCTSkip("Explicit native layout gate only.")
        }
        let suite = "XunJian.SettingsAlignment.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.storageKey)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bridge = SnapshotDeniedOAuthBridge()
        let model = AppModel(oauthBridgeService: bridge,
                             credentialStore: LocalCredentialStore(fileURL: output.appendingPathComponent("unused.json")),
                             aiConfigurationStore: AIConfigurationStore(defaults: defaults), filterPreferences: defaults)
        defer { model.index.cancelAllTasks(); model.ai.cancelAllTasks(); model.oauth.applicationResignedActive() }
        for scheme in [ColorScheme.light, .dark] {
            for page in SettingsPage.allCases {
                for width: CGFloat in [780, 1440] {
                    try await capture(SettingsView(selectedPage: .constant(page)), model: model, defaults: defaults,
                                      theme: .precision, scheme: scheme, size: NSSize(width: width, height: 780),
                                      name: "settings-\(page.rawValue)-\(scheme)-\(Int(width))", output: output)
                }
            }
        }
        let calls = await bridge.callCount
        XCTAssertEqual(calls, 0)
        print("SETTINGS_ALIGNMENT_DIRECTORY=\(output.path)")
    }

    @MainActor
    func testCommandPaletteClaimsFocusCancelsAndSubmitsLatestQuery() async throws {
        // Component integration: native editor ownership and actions are tested
        // here; real WindowServer keyboard delivery has a separate UI gate.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let suiteName = "XunJian.CommandPalette.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bridge = SnapshotDeniedOAuthBridge()
        let model = AppModel(oauthBridgeService: bridge,
                             credentialStore: LocalCredentialStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-palette-\(UUID().uuidString).json")),
                             aiConfigurationStore: AIConfigurationStore(defaults: defaults), filterPreferences: defaults)
        defer { model.index.cancelAllTasks(); model.ai.cancelAllTasks(); model.oauth.applicationResignedActive() }
        let route = SnapshotCommandRoute()
        let commandCenter = NotificationCenter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Without a finite proposal NSHostingController adopts the empty
        // TextField's tiny ideal size and collapses this fixture window.
        window.contentViewController = NSHostingController(rootView: SnapshotCommandHost(route: route, commandCenter: commandCenter)
            .environmentObject(model).frame(width: 900, height: 700))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<20 where !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { window.orderOut(nil); window.close() }
        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        try await Task.sleep(for: .milliseconds(150))
        window.makeFirstResponder(try XCTUnwrap(fields(in: window.contentView!).first))
        for shouldSubmit in [false, true] {
            commandCenter.post(name: .xunJianShowCommandPalette, object: nil)
            var commandField: NSSearchField?
            for _ in 0..<20 {
                commandField = fields(in: window.contentView!).compactMap { $0 as? NSSearchField }.first
                if let commandField, let editor = commandField.currentEditor(), window.firstResponder === editor { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let field = try XCTUnwrap(commandField)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "面板打开后必须直接可输入")
            XCTAssertTrue(window.firstResponder === editor, "不能把焦点留在后方页面")
            if shouldSubmit {
                // Do not wait for the debounced filter: Return must execute the new query, never the old Home command.
                field.stringValue = AppLanguage.localized("设置", english: "Settings")
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                NSApp.sendAction(try XCTUnwrap(field.action), to: field.target, from: field)
                for _ in 0..<20 where route.selection != .settings { try await Task.sleep(for: .milliseconds(50)) }
                XCTAssertEqual(route.selection, .settings)
            } else {
                XCTAssertEqual(field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))), true)
            }
            for _ in 0..<30 {
                if !fields(in: window.contentView!).contains(where: { $0 is NSSearchField }) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertFalse(fields(in: window.contentView!).contains { $0 is NSSearchField }, "面板必须销毁，提交分支：\(shouldSubmit)")
        }
        let calls = await bridge.callCount
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testNativeThemeLayoutSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["XUNJIAN_THEME_SNAPSHOTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_XUNJIAN_THEME_SNAPSHOTS=1 and run only ThemeLayoutSnapshotTests.")
        }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            throw XCTSkip("Snapshot fixture must run inside the isolated XCTest host.")
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJian-ThemeSnapshots-\(UUID().uuidString)", isDirectory: true)
        let fixture = output.appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let suiteName = "XunJian.ThemeSnapshots.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.storageKey)
        defaults.set(FileBrowseViewMode.list.rawValue, forKey: "allFiles.viewMode")

        let bridge = SnapshotDeniedOAuthBridge()
        let model = AppModel(
            oauthBridgeService: bridge,
            credentialStore: LocalCredentialStore(fileURL: fixture.appendingPathComponent("unused-credentials.json")),
            aiConfigurationStore: AIConfigurationStore(defaults: defaults),
            filterPreferences: defaults
        )
        defer {
            model.index.cancelAllTasks()
            model.ai.cancelAllTasks()
            model.oauth.applicationResignedActive()
        }
        for _ in 0..<100 where model.databaseState != .available {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.databaseState, .available)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJian-TestHost-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            .appendingPathComponent("index.sqlite3")
        let database = try FileIndexDatabase(databaseURL: databaseURL)
        let existingSources = try await database.fetchSources()
        guard existingSources.isEmpty else {
            throw XCTSkip("Snapshot fixture requires a fresh test host; existing test sources are untouched.")
        }
        // 授权仅覆盖本次新建的临时演示目录，用于真实 PDF 预览；不接触用户来源。
        let bookmark = try fixture.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let source = try await database.upsertSource(displayName: "主题演示", path: fixture.path, bookmark: bookmark)
        let previewText = """
        品牌方案 · 秋季更新

        这是一份用于界面验收的演示文档，不包含个人资料。

        01 设计目标
        保留文件原本的语义，让检索结果与内容预览都有明确的层次。此处验证窄栏自动换行、阅读字号、长文件名以及主题颜色。

        02 内容表达
        A 更紧凑，B 留白更多；切换主题不应重置选择或丢失正文。英文 Mixed text、数字 12345 与中文都需要清晰显示。

        03 使用说明
        使用顶部原生按钮打开原文件、快速预览或在 Finder 中显示；低频信息收纳在下方。
        """
        let names = [
            "品牌方案 · 秋季更新.pdf",
            "品牌方案-讨论纪要.md",
            "LayoutExample.swift",
            "品牌视觉规范.txt",
            "官网改版说明.md",
            "品牌提案反馈.md"
        ]
        let files = try names.enumerated().map { offset, name in
            let url = fixture.appendingPathComponent(name)
            let contents = offset == 2 ? "struct Example {\n    let title = \"品牌方案\"\n    func render() {\n        print(title)\n    }\n}\n" : previewText
            if url.pathExtension == "pdf" {
                let pageImage = NSImage(size: NSSize(width: 680, height: 900), flipped: false) { _ in
                    NSColor.white.setFill()
                    NSRect(x: 0, y: 0, width: 680, height: 900).fill()
                    let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 38, weight: .medium), .foregroundColor: NSColor.black]
                    ("秋季品牌方案" as NSString).draw(at: NSPoint(x: 56, y: 780), withAttributes: heading)
                    let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.darkGray]
                    ("让每一次沟通更清晰" as NSString).draw(at: NSPoint(x: 56, y: 730), withAttributes: body)
                    ("01 设计目标\n\n保留品牌识别，简化信息层级。\n重点覆盖官网、提案与日常物料。\n\n\n02 视觉表达\n\n以克制的色彩与留白，建立稳定清晰的视觉秩序。\n通过统一的字体系统与精细排版，提升可读性。\n\n\n这是一份本地验收演示文档。" as NSString)
                        .draw(in: NSRect(x: 56, y: 120, width: 560, height: 520), withAttributes: body)
                    return true
                }
                let document = PDFDocument()
                document.insert(try XCTUnwrap(PDFPage(image: pageImage)), at: 0)
                XCTAssertTrue(document.write(to: url))
            } else {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            return IndexedFile(
                id: "theme-fixture-\(offset)-\(source.id)", sourceID: source.id,
                name: name, path: url.path, fileExtension: url.pathExtension,
                kind: offset == 2 ? .code : .document, size: Int64(contents.utf8.count),
                createdAt: Date(timeIntervalSince1970: 1_783_036_800),
                modifiedAt: Date(timeIntervalSince1970: 1_783_123_200),
                indexedAt: Date(), textContent: contents
            )
        }
        addTeardownBlock {
            try await database.deleteSource(source.id)
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file.url)
            }
            if FileManager.default.fileExists(atPath: fixture.path) {
                try FileManager.default.removeItem(at: fixture)
            }
        }
        try await database.replaceFiles(for: source.id, with: files)
        await model.index.rebuildSearchIndex()
        XCTAssertEqual(model.files.count, files.count)
        let fetchedText = try await model.fetchInspectorPreviewText(forFileID: files[0].id, maximumCharacters: 20_001)
        XCTAssertEqual(fetchedText, previewText)
        model.searchText = "品牌方案"
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0..<100 where model.searchProgressStore.isSearching {
            try await Task.sleep(for: .milliseconds(50))
        }
        model.highlightQuery = "品牌方案"
        try await verifySettingsPageDraftRetention(model: model, defaults: defaults)
        try await verifyCollectionsSearchFocus(model: model)

        for theme in AppVisualTheme.allCases {
            defaults.set(theme.rawValue, forKey: AppVisualTheme.storageKey)
            for scheme in [ColorScheme.light, .dark] {
                let mode = scheme == .dark ? "dark" : "light"
                // 快捷搜索是独立 root：应用外观必须覆盖相反的宿主外观。
                let forcedScheme: ColorScheme = scheme == .dark ? .light : .dark
                defaults.set(forcedScheme == .dark ? "dark" : "light", forKey: AppAppearance.storageKey)
                try await capture(
                    MenuBarSearchView(), model: model, defaults: defaults,
                    theme: theme, scheme: scheme, size: NSSize(width: 340, height: 480),
                    name: "quick-search-\(theme.rawValue)-host-\(mode)", output: output,
                    expectedCornerColor: NSColor(theme.palette(for: forcedScheme).canvas)
                )
                defaults.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)
                for page in SettingsPage.allCases {
                    for width: CGFloat in [480, 900] {
                        try await capture(
                            SettingsView(selectedPage: .constant(page)), model: model, defaults: defaults,
                            theme: theme, scheme: scheme, size: NSSize(width: width, height: 780),
                            name: "settings-\(page.rawValue)-\(theme.rawValue)-\(mode)-\(Int(width))", output: output
                        )
                    }
                }
                for width: CGFloat in [480, 1100] {
                    try await capture(
                        CategoriesView(selectedCategory: nil), model: model, defaults: defaults,
                        theme: theme, scheme: scheme, size: NSSize(width: width, height: 780),
                        name: "categories-\(theme.rawValue)-\(mode)-\(Int(width))", output: output
                    )
                    try await capture(
                        HomeView(openAllFiles: { _ in }, searchAllFiles: { _ in }), model: model, defaults: defaults,
                        theme: theme, scheme: scheme, size: NSSize(width: width, height: 780),
                        name: "home-\(theme.rawValue)-\(mode)-\(Int(width))", output: output
                    )
                }
                try await capture(
                    AISearchSheet(), model: model, defaults: defaults,
                    theme: theme, scheme: scheme, size: NSSize(width: 560, height: 300),
                    name: "ai-search-\(theme.rawValue)-\(mode)", output: output
                )
                try await capture(
                    CategoryEditorSheet(title: "新建分类", submit: { _, _ in }), model: model, defaults: defaults,
                    theme: theme, scheme: scheme, size: NSSize(width: 480, height: 300),
                    name: "category-editor-\(theme.rawValue)-\(mode)", output: output
                )
                try await capture(
                    StorageInsightsView(), model: model, defaults: defaults,
                    theme: theme, scheme: scheme, size: NSSize(width: 620, height: 700),
                    name: "storage-\(theme.rawValue)-\(mode)", output: output
                )
                for width: CGFloat in [280, 420, 620] {
                    model.selectedFileIDs = [files[0].id]
                    try await capture(
                        FileInspectorView(file: files[0], onClose: {}), model: model, defaults: defaults,
                        theme: theme, scheme: scheme, size: NSSize(width: width, height: 780),
                        name: "inspector-\(theme.rawValue)-\(mode)-\(Int(width))", output: output
                    )
                }
                for (name, selectedIDs, file) in [
                    ("empty", Set<String>(), Optional<IndexedFile>.none),
                    ("multiple", Set(files.prefix(2).map(\.id)), Optional(files[0])),
                    ("code", Set([files[2].id]), Optional(files[2]))
                ] {
                    model.selectedFileIDs = selectedIDs
                    try await capture(
                        FileInspectorView(file: file), model: model, defaults: defaults,
                        theme: theme, scheme: scheme, size: NSSize(width: 420, height: 780),
                        name: "inspector-\(name)-\(theme.rawValue)-\(mode)", output: output
                    )
                }
                model.selectedFileIDs = [files[0].id]
                try await capture(
                    AppShellView(), model: model, defaults: defaults,
                    theme: theme, scheme: scheme, size: NSSize(width: 1536, height: 1024),
                    name: "full-window-\(theme.rawValue)-\(mode)", output: output, fullShell: true
                )
                try await capture(
                    AllFilesView(windowWidth: 1024, contentWidth: 780), model: model, defaults: defaults,
                    theme: theme, scheme: scheme, size: NSSize(width: 780, height: 780),
                    name: "all-files-\(theme.rawValue)-\(mode)", output: output
                )
                // 两个真实组件并排验收，不将此夹具冒充 AppShell 的原生工具栏验收。
                for (listWidth, inspectorWidth) in [(CGFloat(500), CGFloat(280)), (CGFloat(820), CGFloat(420))] {
                    let totalWidth = listWidth + inspectorWidth + 1
                    let split = HStack(spacing: 0) {
                        AllFilesView(windowWidth: totalWidth, contentWidth: listWidth)
                            .frame(width: listWidth)
                        Divider()
                        FileInspectorView(file: files[0])
                            .frame(width: inspectorWidth)
                    }
                    try await capture(
                        split, model: model, defaults: defaults, theme: theme, scheme: scheme,
                        size: NSSize(width: totalWidth, height: 780),
                        name: "components-split-\(theme.rawValue)-\(mode)-\(Int(totalWidth))", output: output
                    )
                }
            }
        }
        model.index.cancelAllTasks()
        let bridgeCalls = await bridge.callCount
        XCTAssertEqual(bridgeCalls, 0, "原生主题渲染不得触发 OAuth 或 AI 请求")
        print("THEME_SNAPSHOT_DIRECTORY=\(output.path)")
    }

    @MainActor
    private func verifyCollectionsSearchFocus(model: AppModel) async throws {
        let context = CollectionBrowseContext()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        func show(_ category: FileCategory?) {
            window.contentViewController = NSHostingController(rootView: CategoriesView(selectedCategory: category, browseContext: context)
                .environmentObject(model).environmentObject(model.index.categoryIndexStore))
        }
        show(nil)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        func search(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { search(in: $0) }.first
        }
        try await Task.sleep(for: .milliseconds(300))
        let field = try XCTUnwrap(search(in: window.contentView!))
        field.stringValue = "设计"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        window.makeFirstResponder(nil)
        NotificationCenter.default.post(name: .xunJianFocusSearchField, object: "collections")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(field.currentEditor() === window.firstResponder)
        XCTAssertEqual(field.stringValue, "设计", "聚焦资料集搜索不能清除当前查询")
        let category = try XCTUnwrap(model.categories.first)
        show(category)
        try await Task.sleep(for: .milliseconds(300))
        let detailField = try XCTUnwrap(search(in: window.contentView!))
        detailField.stringValue = "品牌"
        detailField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: detailField))
        context.filters[category.id, default: .init()].kind = .document
        show(nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try XCTUnwrap(search(in: window.contentView!)).stringValue, "设计", "进入资料集再返回必须保留目录查询")
        show(category)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try XCTUnwrap(search(in: window.contentView!)).stringValue, "品牌", "详情视图重新挂载仍保留查询")
        XCTAssertEqual(context.filters[category.id]?.kind, .document)
    }

    @MainActor
    private func verifySettingsPageDraftRetention(model: AppModel, defaults: UserDefaults) async throws {
        let route = SnapshotSettingsRoute()
        let drafts = AIProviderSettingsDraftStore()
        let original = AIProviderSettingsDraft(baseURL: "https://example.invalid/v1", model: "navigation-original", apiKey: "")
        drafts.save(original, for: .codex)
        let updates = AppUpdateCoordinator(bundle: Bundle(for: ThemeLayoutSnapshotTests.self))
        XCTAssertFalse(updates.isConfigured)
        let content = SnapshotSettingsHost(route: route)
            .environmentObject(model).environmentObject(model.oauth).environmentObject(model.ai)
            .environmentObject(drafts).environmentObject(updates).defaultAppStorage(defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 1000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        try await Task.sleep(for: .milliseconds(500))
        let field = try XCTUnwrap(fields(in: window.contentView!).first { $0.stringValue == original.model },
                                  "进入 AI 页应展开并恢复未保存的配置")
        field.stringValue = "navigation-edited"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(100))
        route.page = .general
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(drafts.draft(for: .codex)?.model, "navigation-edited", "离开表单必须保留用户编辑而非旧配置")
        XCTAssertFalse(fields(in: window.contentView!).contains { $0.stringValue == "navigation-edited" },
                       "通用页不能泄漏 AI 表单控件")
        route.page = .ai
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(fields(in: window.contentView!).contains { $0.stringValue == "navigation-edited" },
                      "返回 AI 页必须重新呈现用户草稿")
    }

    @MainActor
    private func capture<Content: View>(
        _ content: Content, model: AppModel, defaults: UserDefaults,
        theme: AppVisualTheme, scheme: ColorScheme, size: NSSize, name: String, output: URL,
        expectedCornerColor: NSColor? = nil,
        fullShell: Bool = false,
        exercise: ((NSView) async throws -> Void)? = nil
    ) async throws {
        let updates = AppUpdateCoordinator(bundle: Bundle(for: ThemeLayoutSnapshotTests.self))
        XCTAssertFalse(updates.isConfigured, "截图夹具不可检查线上更新")
        let themedContent = content
            .environmentObject(model)
            .environmentObject(model.oauth)
            .environmentObject(model.ai)
            .environmentObject(AIProviderSettingsDraftStore())
            .environmentObject(updates)
            .environmentObject(model.index.categoryIndexStore)
            .environmentObject(model.index.searchProgressStore)
            .defaultAppStorage(defaults)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.colorScheme, scheme)
            .xunjianVisualTheme(theme)
        let root = fullShell
            ? AnyView(themedContent.frame(minWidth: 360, minHeight: 600))
            : AnyView(themedContent.frame(width: size.width, height: size.height))
        let controller = NSHostingController(rootView: root)
        let hosting = controller.view
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: (fullShell || exercise != nil) ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        if exercise != nil {
            window.title = "查重验收 · 1000组"
            window.isExcludedFromWindowsMenu = false
        }
        if fullShell {
            window.titleVisibility = .visible
            window.toolbarStyle = .unifiedCompact
        }
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        if fullShell { window.setFrame(NSRect(origin: .zero, size: size), display: true) }
        else { window.setContentSize(size) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer {
            // Each fixture shares model/defaults with the next capture. Detach
            // its SwiftUI graph before closing so a retained native window cannot
            // keep reacting to later appearance/navigation changes off screen.
            window.orderOut(nil)
            controller.rootView = AnyView(EmptyView())
            window.contentViewController = nil
            window.contentView = nil
            window.close()
            XCTAssertNil(window.contentViewController)
            XCTAssertNil(window.contentView)
        }
        try await Task.sleep(for: .milliseconds(400))
        if fullShell {
            NotificationCenter.default.post(name: .xunJianRevealInAllFiles, object: nil)
            try await Task.sleep(for: .milliseconds(250))
            let toolbar = try XCTUnwrap(window.toolbar, "工作区必须使用真实 NSToolbar")
            XCTAssertEqual(toolbar.items.filter { $0.itemIdentifier.rawValue == "workspace.modes" }.count, 0,
                           "不保留旧四段选择器")
            XCTAssertEqual(toolbar.items.filter { $0.itemIdentifier.rawValue == "workspace.destinations" }.count, 1)
            let sidebarItems = toolbar.items.filter {
                let identifier = $0.itemIdentifier.rawValue.lowercased()
                return identifier.contains("sidebar") && identifier.contains("toggle")
            }
            XCTAssertEqual(sidebarItems.count, 1, "仅使用系统导航开关，不再叠加自有按钮")
            XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue == "files.sidebar" })
            XCTAssertEqual(toolbar.items.filter { $0.itemIdentifier.rawValue == "workspace.inspector" }.count, 1,
                           "预览收起时也只注册一个开关，避免 NSToolbar 重复 ID 崩溃")
            NotificationCenter.default.post(name: .xunJianToggleInspector, object: nil)
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertEqual(toolbar.items.filter { $0.itemIdentifier.rawValue == "workspace.inspector" }.count, 1)
            func firstPDF(in view: NSView) -> PDFView? {
                if let pdf = view as? PDFView { return pdf }
                return view.subviews.lazy.compactMap { firstPDF(in: $0) }.first
            }
            // File loading and native split construction complete asynchronously.
            // Require an actual PDF and a stable frame before inspecting its position;
            // otherwise a missing preview could silently bypass every PDF assertion.
            var previousPDFSize: NSSize?
            var stableSamples = 0
            for _ in 0..<30 {
                if let pdf = firstPDF(in: hosting), pdf.document != nil, pdf.bounds.width > 0 {
                    stableSamples = previousPDFSize == pdf.bounds.size ? stableSamples + 1 : 0
                    previousPDFSize = pdf.bounds.size
                    if stableSamples >= 3 { break }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNotNil(firstPDF(in: hosting), "整窗验收必须包含已加载的原生 PDF，不能漏检")
            XCTAssertGreaterThanOrEqual(stableSamples, 3, "预览布局必须在限定时间内稳定")
            func firstSearch(in view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                return view.subviews.lazy.compactMap { firstSearch(in: $0) }.first
            }
            XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue == "files.search" }, "搜索带属于内容列，不再注册到窗口工具栏")
            let searchView = try XCTUnwrap(firstSearch(in: hosting))
            XCTAssertGreaterThanOrEqual(searchView.convert(searchView.bounds, to: nil).minX, 0,
                                     "搜索不得越过窗口边缘")
            XCTAssertLessThanOrEqual(searchView.convert(searchView.bounds, to: nil).minX, 32,
                                     "首次进入搜索不应额外展开资源目录")
            let pdf = try XCTUnwrap(firstPDF(in: hosting))
            XCTAssertFalse(searchView.convert(searchView.bounds, to: nil).intersects(pdf.convert(pdf.bounds, to: nil)),
                           "通栏搜索位于阅读区上方，不能覆盖文档")
            XCTAssertGreaterThan(pdf.bounds.width, 700, "宽窗阅读区必须取得主要宽度，不退回窄详情栏")
            func inspect(_ view: NSView) {
                if let pdf = view as? PDFView {
                    if let inspector = pdf as? InspectorPDFView { print("THEME_PDF_DIAGNOSTICS=\(inspector.initialLayoutDiagnostics)") }
                    print("THEME_PDF_GEOMETRY=\(pdf.bounds); destination=\(String(describing: pdf.currentDestination?.point)); scale=\(pdf.scaleFactor)")
                    if let firstPage = pdf.document?.page(at: 0), let destination = pdf.currentDestination {
                        XCTAssertTrue(destination.page === firstPage)
                        XCTAssertGreaterThanOrEqual(destination.point.y, firstPage.bounds(for: .cropBox).maxY - 8,
                                                    "首次打开原文件必须显示首页顶部，而不是沿用初始布局的中段位置")
                    } else {
                        XCTFail("已显示的原生 PDF 必须完成首页定位")
                    }
                }
                if let split = view as? NSSplitView { print("THEME_SPLIT_WIDTHS=\(split.arrangedSubviews.map { Int($0.frame.width) }); HEIGHT=\(split.bounds.height); SAFE_TOP=\(split.safeAreaInsets.top)") }
                if let table = view as? NSTableView, table.numberOfRows == model.files.count {
                    print("THEME_TABLE_SELECTION=\(table.selectedRowIndexes)")
                    if let delegate = table.delegate,
                       let parent = Mirror(reflecting: delegate).children.first(where: { $0.label == "parent" })?.value as? LargeFileTableView {
                        print("THEME_TABLE_INPUT_SELECTION=\(parent.selection.count); MODEL=\(model.selectedFileIDs.count)")
                    }
                    XCTAssertEqual(table.numberOfSelectedRows, 1)
                }
                view.subviews.forEach(inspect)
            }
            inspect(hosting)
            // Exercise native split sizing, not only the state machine.
            // The inspector belongs to the detail column. Wrapping the whole
            // navigation in another native split can overflow a narrow window.
            for width in [CGFloat(900), CGFloat(720)] {
                window.setContentSize(NSSize(width: width, height: 800))
                try await Task.sleep(for: .milliseconds(500))
                if firstPDF(in: hosting) == nil {
                    NotificationCenter.default.post(name: .xunJianToggleInspector, object: nil)
                    try await Task.sleep(for: .milliseconds(500))
                }
                let narrowPDF = try XCTUnwrap(firstPDF(in: hosting))
                XCTAssertLessThanOrEqual(narrowPDF.convert(narrowPDF.bounds, to: nil).maxX,
                                         window.contentLayoutRect.maxX + 1,
                                         "窄窗手动展开时预览不能溢出窗口右边界")
                let narrowSearch = try XCTUnwrap(firstSearch(in: hosting))
                XCTAssertFalse(narrowSearch.isHiddenOrHasHiddenAncestor, "窄窗展开预览后搜索必须仍可见")
                XCTAssertGreaterThan(narrowSearch.visibleRect.width, 80, "搜索带不能被裁切成不可用区域")
                XCTAssertGreaterThanOrEqual(narrowSearch.convert(narrowSearch.bounds, to: nil).minX, 0)
                XCTAssertFalse(narrowSearch.convert(narrowSearch.bounds, to: nil).intersects(narrowPDF.convert(narrowPDF.bounds, to: nil)),
                               "窄窗通栏搜索仍须位于阅读区之外")
            }
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            try await Task.sleep(for: .milliseconds(500))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        try await exercise?(hosting)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let expectedCornerColor {
            // cacheDisplay 使用屏幕色域（如 Display P3）；colorAt 的原始分量
            // 属于 bitmap.colorSpace，不能按其通用 Calibrated RGB 标签二次转换。
            let actual = try XCTUnwrap(bitmap.colorAt(x: 5, y: 5))
            let expected = try XCTUnwrap(expectedCornerColor.usingColorSpace(bitmap.colorSpace))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.01)
        }
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        let url = output.appendingPathComponent(name).appendingPathExtension("png")
        if fullShell {
            // Native split/inspector controllers are compositor-backed; view
            // cacheDisplay omits those layers. Capture the actual window.
            print("THEME_NATIVE_WINDOW=\(window.windowNumber)|\(url.path)")
            fflush(stdout)
            let captureMode = ProcessInfo.processInfo.environment["XUNJIAN_THEME_INTERACTIVE"]
            if captureMode == "1" || captureMode == "light" {
                if name == "full-window-precision-light" || (captureMode == "1" && name.contains("precision")) {
                    // CUA capture latency varies. Keep this exact native window
                    // alive until its validated screenshot is delivered, bounded
                    // so unattended test runs still terminate without UI access.
                    for _ in 0..<1800 {
                        if FileManager.default.fileExists(atPath: url.path) { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            model.selectedFileIDs = []
            NotificationCenter.default.post(name: .xunJianToggleSidebar, object: nil)
            try await Task.sleep(for: .milliseconds(250))
            func assertWorkspaceHeight(_ view: NSView) {
                if let split = view as? NSSplitView, split.isVertical {
                    XCTAssertGreaterThanOrEqual(split.bounds.height, window.contentLayoutRect.height - 66,
                                                "关闭侧栏不能把整个工作区压缩成内容的最小高度")
                }
                view.subviews.forEach(assertWorkspaceHeight)
            }
            assertWorkspaceHeight(hosting)
            NotificationCenter.default.post(name: .xunJianToggleInspector, object: nil)
            try await Task.sleep(for: .milliseconds(250))
            assertWorkspaceHeight(hosting)
            // Native window chrome is verified interactively through CUA.
            // Do not turn an unavailable compositor screenshot into a skip of
            // the remaining theme/layout assertions, or save an incomplete image.
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("THEME_NATIVE_WINDOW_VISUAL_NOT_CAPTURED=\(name)")
                return
            }
        } else {
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url, options: .atomic)
        }
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("THEME_SNAPSHOT=\(url.path)")
    }
}

@MainActor
private final class SnapshotCommandRoute: ObservableObject {
    @Published var selection: NavigationDestination? = .allFiles
    @Published var settingsPage: SettingsPage = .general
}

private struct SnapshotCommandHost: View {
    @ObservedObject var route: SnapshotCommandRoute
    var commandCenter: NotificationCenter = .default
    var body: some View {
        TextField("Background", text: .constant(""))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(GlobalPresentations(selection: $route.selection, settingsPage: $route.settingsPage,
                                          commandNotificationCenter: commandCenter))
    }
}

@MainActor
private final class SnapshotSettingsRoute: ObservableObject {
    @Published var page: SettingsPage = .ai
}

private struct SnapshotSettingsHost: View {
    @ObservedObject var route: SnapshotSettingsRoute
    var body: some View { SettingsView(selectedPage: $route.page) }
}

private actor SnapshotDeniedOAuthBridge: OAuthBridgeServicing {
    private(set) var callCount = 0
    private func deny() throws -> Never { callCount += 1; throw CancellationError() }
    func authenticationStatus(for provider: OAuthBridgeProvider) async throws -> OAuthBridgeAuthStatus { try deny() }
    func startLogin(for provider: OAuthBridgeProvider, method: OAuthBridgeLoginMethod) async throws -> OAuthBridgeLoginAttempt { try deny() }
    func cancelLogin(for provider: OAuthBridgeProvider, attemptID: UUID) async throws -> OAuthBridgeAuthStatus { try deny() }
    func verifyConnection(_ provider: OAuthBridgeProvider) async throws -> OAuthBridgeAuthStatus { try deny() }
    func listModels(for provider: OAuthBridgeProvider) async throws -> [OAuthBridgeModel] { try deny() }
    func generateText(provider: OAuthBridgeProvider, model: String, systemPrompt: String, userPrompt: String) async throws -> String { try deny() }
    func disconnect(_ provider: OAuthBridgeProvider) async throws -> OAuthBridgeAuthStatus { try deny() }
    func logout(_ provider: OAuthBridgeProvider) async throws -> OAuthBridgeAuthStatus { try deny() }
}
