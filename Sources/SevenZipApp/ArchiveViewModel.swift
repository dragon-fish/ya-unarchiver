import Foundation
import ArchiveKit

// ArchiveKit predates Swift 6 strict-concurrency needs. These types are safe to
// transfer across the actor boundary the view model relies on:
// - SevenZipRunner: immutable (single `let executableURL`).
// - ArchiveEntry: value type of Sendable fields.
// - ArchiveNode: mutated only while ArchiveTree.build constructs it; read-only
//   (internal(set)) to consumers thereafter.
// Declared here to keep this task scoped to the app target.
extension SevenZipRunner: @unchecked Sendable {}
extension ArchiveEntry: @unchecked Sendable {}
extension ArchiveNode: @unchecked Sendable {}

enum ArchiveState {
    case loading
    case loaded(ArchiveNode)
    case needsPassword
    case error(String)
}

@MainActor
final class ArchiveViewModel: ObservableObject {
    let archiveURL: URL
    @Published var state: ArchiveState = .loading
    private(set) var lastEntries: [ArchiveEntry] = []
    private(set) var password: String?

    private let runner: SevenZipRunner

    init(archiveURL: URL, runner: SevenZipRunner = SevenZipLocator.bundledRunner()) {
        self.archiveURL = archiveURL
        self.runner = runner
    }

    func load(password: String? = nil) {
        self.password = password
        state = .loading
        let url = archiveURL
        Task.detached { [runner] in
            do {
                let entries = try runner.list(archive: url, password: password)
                let tree = ArchiveTree.build(from: entries)
                await MainActor.run {
                    self.lastEntries = entries
                    self.state = .loaded(tree)
                }
            } catch ArchiveError.needsPassword {
                await MainActor.run { self.state = .needsPassword }
            } catch {
                await MainActor.run { self.state = .error("\(error)") }
            }
        }
    }
}
