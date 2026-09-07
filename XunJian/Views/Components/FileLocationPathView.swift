import AppKit
import SwiftUI

/// 原生路径显示；窄栏优先显示文件名，上层路径保留在系统弹出菜单中。
struct FileLocationPathView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPathControl {
        let control = FileLocationPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.backgroundColor = .clear
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 13)
        control.unregisterDraggedTypes()
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.target = context.coordinator
        control.doubleAction = #selector(Coordinator.reveal(_:))
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        if control.url != url { control.url = url }
        (control as? FileLocationPathControl)?.updatePathPresentation()
        control.toolTip = url.path
        control.setAccessibilityLabel(AppLanguage.localized("文件位置", english: "File Location"))
        control.setAccessibilityValue(url.path)
    }

    @MainActor
    final class Coordinator: NSObject {
        @objc func reveal(_ sender: NSPathControl) {
            guard let url = sender.clickedPathItem?.url, url.isFileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// Resolve the component under the secondary click, rather than the control's
/// terminal URL. Empty track space deliberately has no misleading file menu.
@MainActor
final class FileLocationPathControl: NSPathControl {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePathPresentation()
    }

    func updatePathPresentation() {
        guard !pathItems.isEmpty, bounds.width > 0 else { return }
        let textFont = font ?? .systemFont(ofSize: 13)
        let fullPathWidth = pathItems.reduce(CGFloat(12)) { width, item in
            width + (item.title as NSString).size(withAttributes: [.font: textFont]).width
                + (item.image == nil ? 0 : 20) + 16
        }
        let nextStyle: NSPathControl.Style = fullPathWidth > bounds.width ? .popUp : .standard
        if pathStyle != nextStyle { pathStyle = nextStyle }
        // A choice in the native popup refers to its actual ancestor URL;
        // standard breadcrumbs retain their existing double-click behavior.
        action = nextStyle == .popUp ? doubleAction : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let pathCell = cell as? NSPathCell,
              let url = pathCell.pathComponentCell(at: point, withFrame: bounds, in: self)?.url,
              url.isFileURL else { return nil }
        return contextMenu(for: url)
    }

    func contextMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        let actions: [(String, Selector)] = [
            (AppLanguage.localized("打开", english: "Open"), #selector(openComponent(_:))),
            (AppLanguage.localized("在 Finder 中显示", english: "Show in Finder"), #selector(revealComponent(_:))),
            (AppLanguage.localized("复制路径", english: "Copy Path"), #selector(copyComponent(_:)))
        ]
        for (title, action) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, url.isFileURL else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func revealComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, url.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func copyComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, url.isFileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}
