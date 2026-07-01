import Foundation
import ArchiveKit

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
    var stateID: Int {
        switch state {
        case .loading: return 0
        case .loaded: return 1
        case .needsPassword: return 2
        case .error: return 3
        }
    }
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
