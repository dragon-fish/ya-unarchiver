import SwiftUI
import AppKit
import ArchiveKit

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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 88, height: 84)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let cv = KeyCapturingCollectionView()
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

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: IconGridView
        /// Snapshot of the ids currently loaded, to detect when a reload is needed.
        var currentIDs: [String] = []

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
    }
}

/// `NSCollectionView` subclass that intercepts the space bar for QuickLook while
/// letting arrow-key selection fall through to the native implementation.
final class KeyCapturingCollectionView: NSCollectionView {
    var onQuickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onQuickLook?()
        } else {
            super.keyDown(with: event)
        }
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
