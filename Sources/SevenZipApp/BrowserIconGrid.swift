import SwiftUI
import AppKit
import ArchiveKit
import UniformTypeIdentifiers

/// A single right-click menu entry, rendered by AppKit `NSMenu` in grid mode and
/// derived from the same source as the list-mode SwiftUI `.contextMenu`, so the two
/// never drift apart.
struct GridMenuAction {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void
}

/// AppKit-backed large-icon grid: a Finder-style alternative to the SwiftUI
/// `Table`, wrapping `NSCollectionView` so selection (rubber-band, ⇧-range,
/// arrow keys), space-QuickLook, double-click, right-click and drag-out all
/// come from the native control instead of hand-rolled gestures.
struct IconGridView: NSViewRepresentable {
    let nodes: [ArchiveNode]
    @Binding var selection: Set<ArchiveNode.ID>
    let previewService: PreviewService
    let iconProvider: (ArchiveNode) -> NSImage
    /// Double-click / Return on a single item (folder → enter, file → open).
    let onPrimaryAction: (ArchiveNode.ID) -> Void
    /// Space on a single selected file → QuickLook (reuses the list-mode path).
    let onQuickLook: () -> Void
    /// Right-click menu for the given target ids (clicked item auto-selected first).
    let menuActions: (Set<ArchiveNode.ID>) -> [GridMenuAction]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 88, height: 84)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let cv = KeyCapturingCollectionView()
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)
        cv.collectionViewLayout = layout
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.register(IconGridItem.self, forItemWithIdentifier: IconGridItem.identifier)
        cv.onQuickLook = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onQuickLook()
        }

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false   // don't swallow single-click selection
        cv.addGestureRecognizer(doubleClick)

        cv.onReturnKey = { [weak coordinator = context.coordinator] in
            coordinator?.primaryActionOnSelection()
        }

        cv.idForIndexPath = { [weak coordinator = context.coordinator] indexPath in
            guard let nodes = coordinator?.parent.nodes, indexPath.item < nodes.count else { return nil }
            return nodes[indexPath.item].id
        }
        cv.currentSelectionIDs = { [weak coordinator = context.coordinator] in
            coordinator?.parent.selection ?? []
        }
        cv.selectSingle = { [weak cv, weak coordinator = context.coordinator] indexPath in
            guard let cv else { return }
            cv.deselectItems(at: cv.selectionIndexPaths)
            cv.selectItems(at: [indexPath], scrollPosition: [])
            // selectItems doesn't fire the delegate, so mirror into the binding manually.
            coordinator?.syncSelectionAfterProgrammaticChange(cv)
        }
        cv.menuActionsFor = { [weak coordinator = context.coordinator] targets in
            coordinator?.parent.menuActions(targets) ?? []
        }

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let cv = scrollView.documentView as? NSCollectionView else { return }
        context.coordinator.parent = self

        // Reload only when the node set (ids/order) actually changed.
        let newIDs = nodes.map(\.id)
        if context.coordinator.currentIDs != newIDs {
            context.coordinator.currentIDs = newIDs
            cv.reloadData()
        }

        // Push SwiftUI selection → collection view, diffing first so an already-in-
        // sync state is left untouched (prevents a select/deselect feedback loop).
        let desired = Set(GridSelectionMapping.rows(forIDs: selection, in: nodes)
            .map { IndexPath(item: $0, section: 0) })
        if cv.selectionIndexPaths != desired {
            cv.deselectItems(at: cv.selectionIndexPaths.subtracting(desired))
            cv.selectItems(at: desired.subtracting(cv.selectionIndexPaths), scrollPosition: [])
            // selectItems/deselectItems do NOT fire delegate callbacks, so no echo back.
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
                             NSFilePromiseProviderDelegate {
        var parent: IconGridView
        /// Snapshot of the ids currently loaded, to detect when a reload is needed.
        var currentIDs: [String] = []

        /// A dedicated queue for fulfilling file promises off the main thread.
        private let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.name = "IconGrid.filePromise"
            q.qualityOfService = .userInitiated
            return q
        }()

        init(_ parent: IconGridView) { self.parent = parent }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.nodes.count
        }

        func collectionView(_ cv: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = cv.makeItem(withIdentifier: IconGridItem.identifier, for: indexPath) as! IconGridItem
            let node = parent.nodes[indexPath.item]
            item.configure(name: node.name, icon: parent.iconProvider(node))
            return item
        }

        func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionToBinding(cv)
        }

        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionToBinding(cv)
        }

        /// Collection view selection → SwiftUI binding. Guarded by an equality check
        /// so it only writes on a real change.
        private func syncSelectionToBinding(_ cv: NSCollectionView) {
            let rows = cv.selectionIndexPaths.map(\.item)
            let ids = GridSelectionMapping.ids(forRows: rows, in: parent.nodes)
            if parent.selection != ids { parent.selection = ids }
        }

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let cv = gesture.view as? NSCollectionView else { return }
            let point = gesture.location(in: cv)
            guard let indexPath = cv.indexPathForItem(at: point),
                  indexPath.item < parent.nodes.count else { return }
            parent.onPrimaryAction(parent.nodes[indexPath.item].id)
        }

        /// Return key opens the single selected item (matches Finder).
        func primaryActionOnSelection() {
            let rows = parent.selection.isEmpty
                ? []
                : GridSelectionMapping.rows(forIDs: parent.selection, in: parent.nodes)
            guard rows.count == 1 else { return }
            parent.onPrimaryAction(parent.nodes[rows[0]].id)
        }

        /// Mirror a programmatic selection change (e.g. right-click auto-select) into the binding.
        func syncSelectionAfterProgrammaticChange(_ cv: NSCollectionView) {
            let ids = GridSelectionMapping.ids(forRows: cv.selectionIndexPaths.map(\.item), in: parent.nodes)
            if parent.selection != ids { parent.selection = ids }
        }

        // MARK: - Drag out to Finder (NSFilePromiseProvider)

        func collectionView(_ cv: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard indexPath.item < parent.nodes.count else { return nil }
            let node = parent.nodes[indexPath.item]
            let ext = (node.name as NSString).pathExtension
            let fileType = node.isDirectory
                ? UTType.folder.identifier
                : (UTType(filenameExtension: ext) ?? .data).identifier
            let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
            provider.userInfo = node
            return provider
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            promiseQueue
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                 fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? ArchiveNode)?.name ?? "item"
        }

        // AppKit calls this one off the main thread (on `promiseQueue`), per
        // `NSFilePromiseProviderDelegate`'s `NS_SWIFT_NONISOLATED` annotation — unlike
        // the rest of the delegate, which is `@MainActor`. Kept `nonisolated` to match;
        // the actual extraction still hops to `@MainActor` to call `previewService`.
        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                 writePromiseTo url: URL,
                                 completionHandler: @escaping @Sendable (Error?) -> Void) {
            guard let node = filePromiseProvider.userInfo as? ArchiveNode else {
                completionHandler(CocoaError(.fileNoSuchFile)); return
            }
            Task { @MainActor in
                do {
                    let source = try await self.parent.previewService.url(for: node)
                    try FileManager.default.copyItem(at: source, to: url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }
}

/// `NSCollectionView` subclass that intercepts the space bar for QuickLook while
/// letting arrow-key selection fall through to the native implementation.
final class KeyCapturingCollectionView: NSCollectionView {
    var onQuickLook: (() -> Void)?
    var onReturnKey: (() -> Void)?

    /// Returns the current selection ids (collection view is the source of truth).
    var currentSelectionIDs: (() -> Set<ArchiveNode.ID>)?
    /// Makes the clicked item the sole selection when it's outside the current one.
    var selectSingle: ((IndexPath) -> Void)?
    /// Builds the menu entries for a set of target ids.
    var menuActionsFor: ((Set<ArchiveNode.ID>) -> [GridMenuAction])?
    /// Maps a hit index path to its node id.
    var idForIndexPath: ((IndexPath) -> ArchiveNode.ID?)?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ":
            onQuickLook?()
        case "\r":
            onReturnKey?()
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point),
              let clickedID = idForIndexPath?(indexPath) else { return nil }

        // Finder behaviour: right-clicking an item outside the selection selects just it.
        let current = currentSelectionIDs?() ?? []
        let targets: Set<ArchiveNode.ID>
        if current.contains(clickedID) {
            targets = current
        } else {
            selectSingle?(indexPath)
            targets = [clickedID]
        }

        guard let actions = menuActionsFor?(targets), !actions.isEmpty else { return nil }
        let menu = NSMenu()
        for action in actions {
            let item = NSMenuItem(title: action.title,
                                  action: #selector(GridMenuTarget.fire(_:)),
                                  keyEquivalent: "")
            item.isEnabled = action.isEnabled
            let target = GridMenuTarget(action.perform)
            item.representedObject = target
            item.target = target
            menu.addItem(item)
            objc_setAssociatedObject(menu, Unmanaged.passUnretained(item).toOpaque(),
                                     target, .OBJC_ASSOCIATION_RETAIN)
        }
        return menu
    }
}

/// One grid cell: a 48pt system icon above a centered, two-line-truncated name,
/// with an accent-tinted rounded background when selected.
final class IconGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconGridItem")

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        self.view = container

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.font = .preferredFont(forTextStyle: .callout)
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.wraps = true
        nameLabel.cell?.isScrollable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        container.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
        ])
    }

    func configure(name: String, icon: NSImage) {
        iconView.image = icon
        nameLabel.stringValue = name
    }

    override var isSelected: Bool {
        didSet { updateSelectionHighlight() }
    }

    private func updateSelectionHighlight() {
        guard let layer = view.layer else { return }
        layer.cornerRadius = 8
        layer.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor
    }
}

/// Retains and fires a `GridMenuAction.perform` closure for an `NSMenuItem`.
private final class GridMenuTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action; super.init() }
    @objc func fire(_ sender: NSMenuItem) { action() }
}
