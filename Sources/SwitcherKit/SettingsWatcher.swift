import Foundation

/// Watches `settings.json` and reports that it changed.
///
/// Three things make this harder than it looks:
///
/// 1. **Atomic writes destroy the watched inode.** Switcher, Claude Code and the
///    airiad agent all write via temp-file + rename, so the descriptor being
///    watched stops referring to the live file. The watcher re-arms on
///    `.delete` / `.rename`.
/// 2. **One logical write emits several events.** Callbacks are debounced.
/// 3. **`~/.claude` is busy.** A plain directory watch would fire constantly, so
///    the directory is only used as a backstop: its events are ignored unless the
///    file's inode actually changed or the file watch is currently dead.
public final class SettingsWatcher: @unchecked Sendable {
    private let url: URL
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable () -> Void

    private let queue = DispatchQueue(label: "ai.airia.switcher.watcher")
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var watchedInode: ino_t = 0
    private var started = false

    public init(url: URL,
                debounce: TimeInterval = 0.3,
                onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.debounceInterval = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            armFile()
            armDirectory()
        }
    }

    public func stop() {
        queue.sync { [self] in
            started = false
            pending?.cancel(); pending = nil
            fileSource?.cancel(); fileSource = nil
            directorySource?.cancel(); directorySource = nil
            watchedInode = 0
        }
    }

    // MARK: - Arming

    private func inode(of path: String) -> ino_t {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_ino : 0
    }

    private func armFile() {
        fileSource?.cancel()
        fileSource = nil

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // File absent right now (mid-rename, or never created). The directory
            // watch will bring us back when it appears.
            watchedInode = 0
            return
        }
        watchedInode = inode(of: url.path)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue)

        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // The file we were watching was replaced — follow the new inode.
                self.armFile()
            }
            self.scheduleNotify()
        }
        source.setCancelHandler { close(descriptor) }
        fileSource = source
        source.resume()
    }

    /// Backstop only: catches the file being created or replaced while we had no
    /// valid descriptor. Deliberately quiet — `~/.claude` sees constant churn.
    private func armDirectory() {
        guard directorySource == nil else { return }
        let directory = url.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write], queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let current = self.inode(of: self.url.path)
            guard current != 0 else { return }
            // Only react when the file we care about actually changed identity,
            // or when we lost our file watch entirely.
            guard current != self.watchedInode || self.fileSource == nil else { return }
            self.armFile()
            self.scheduleNotify()
        }
        source.setCancelHandler { close(descriptor) }
        directorySource = source
        source.resume()
    }

    // MARK: - Debounce

    private func scheduleNotify() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
