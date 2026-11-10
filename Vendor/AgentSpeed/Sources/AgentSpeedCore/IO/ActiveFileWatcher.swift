import Darwin
import Dispatch

/// Vnode notifications catch appends even when a writer keeps its transcript open.
final class ActiveFileWatcher {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var identities: [String: FileIdentity] = [:]
    private let queue: DispatchQueue
    private let changed: @Sendable (String) -> Void

    init(queue: DispatchQueue, changed: @escaping @Sendable (String) -> Void) {
        self.queue = queue
        self.changed = changed
    }

    func update(paths: [String]) {
        let wanted = Set(paths)
        for path in Array(sources.keys) {
            if !wanted.contains(path) || FileStat.stat(path)?.identity != identities[path] {
                sources.removeValue(forKey: path)?.cancel()
                identities[path] = nil
            }
        }
        for path in paths where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue
            )
            let changed = changed
            source.setEventHandler { changed(path) }
            source.setCancelHandler { close(descriptor) }
            sources[path] = source
            identities[path] = FileStat.fstat(descriptor)?.identity
            source.resume()
        }
    }

    deinit { for source in sources.values { source.cancel() } }
}
