import Foundation

/// Keeps access granted by the system file picker alive for an operation.
/// The app does not retain bookmarks or access after its windows close.
final class SecurityScopedAccess {
    private var opened: [URL] = []

    init(urls: [URL] = []) {
        replace(with: urls)
    }

    func replace(with urls: [URL]) {
        close()
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            if url.startAccessingSecurityScopedResource() { opened.append(url) }
        }
    }

    func close() {
        for url in opened { url.stopAccessingSecurityScopedResource() }
        opened.removeAll()
    }

    deinit { close() }
}
