import Foundation
import ZharpCore

/// The app's output as logs: everything written to stdout and stderr — `print`, `debugPrint`,
/// `dump`, `NSLog` (which writes to stderr), `FileHandle.standardError`, C's `printf`/`fputs`,
/// logging libraries that print — that `Zharp.log` and the swift-log handler didn't already send.
///
/// Neither `print` nor `NSLog` can be intercepted in-process, so this is a net under the exact
/// captures: file descriptors 1 and 2 are pointed at pipes, a background thread reads them,
/// writes every byte straight back to where the output went before (the Xcode console, a file,
/// `/dev/null`) and hands a copy to `OutputCollector`. The app's output is unchanged.
///
/// A piped line carries the session, user, screen and tags of the moment it is read, but not
/// the span it was printed in: by the time the reader sees it, the printing thread has moved
/// on. `Zharp.log` and the swift-log handler keep the span.
enum OutputCapture {
    private static let lock = NSLock()
    private static var installed: [OutputRedirect] = []

    /// Redirects stdout and stderr. Once per process.
    static func install(collector: OutputCollector) {
        lock.lock()
        defer { lock.unlock() }
        guard installed.isEmpty else { return }
        // Whatever stdio is holding goes out first, to where it was headed.
        fflush(stdout)
        fflush(stderr)
        // Line by line, whatever stdout points at: C's stdio buffers 4 KB at a time when it isn't
        // a terminal, which would hold print() output back until the buffer fills.
        setvbuf(stdout, nil, _IOLBF, 0)
        let targets: [(Int32, OutputStreamName)] = [(STDOUT_FILENO, .stdout), (STDERR_FILENO, .stderr)]
        for (fd, stream) in targets {
            if let redirect = OutputRedirect(fd: fd, onData: { [weak collector] bytes in
                collector?.ingest(bytes, from: stream)
            }) {
                installed.append(redirect)
            }
        }
        if installed.isEmpty { Diagnostics.debug("Couldn't redirect stdout or stderr; print and NSLog won't be sent.") }
    }
}

/// One file descriptor pointed at a pipe, with a thread that reads the pipe, writes everything
/// back to the original destination and passes a copy on.
///
/// Safety: the reader only reads, writes and copies bytes (no locks the app could hold, no
/// logging of its own), so the app's writes never wait on Zharp beyond the time a pipe takes. If
/// reading ever fails, the descriptor is pointed back where it was, so the app can never block
/// on a full pipe nobody reads.
final class OutputRedirect: @unchecked Sendable {
    let fd: Int32
    /// A duplicate of where `fd` pointed before.
    private let original: Int32
    private let readEnd: Int32
    /// Kept open so the pipe never sees end-of-file, and to recognise it in `fd` later.
    private let writeEnd: Int32
    private let onData: (Data) -> Void

    init?(fd: Int32, onData: @escaping (Data) -> Void) {
        let original = dup(fd)
        guard original >= 0 else { return nil }
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else {
            close(original)
            return nil
        }
        for end in [original, ends[0], ends[1]] { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        guard dup2(ends[1], fd) >= 0 else {
            close(original)
            close(ends[0])
            close(ends[1])
            return nil
        }
        self.fd = fd
        self.original = original
        readEnd = ends[0]
        writeEnd = ends[1]
        self.onData = onData

        let thread = Thread { [self] in self.run() }
        thread.name = "io.zharp.output-\(fd)"
        // Prompt, so a burst of output doesn't fill the pipe and make the writer wait.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func run() {
        let size = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while true {
            let count = read(readEnd, buffer, size)
            if count > 0 {
                OutputRedirect.writeAll(original, buffer, count)
                onData(Data(bytes: buffer, count: count))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        restore()
    }

    /// Points `fd` back at the original destination, unless the app has pointed it somewhere
    /// else of its own since (`freopen` to a log file, say).
    private func restore() {
        var current = stat()
        var ours = stat()
        guard fstat(fd, &current) == 0, fstat(writeEnd, &ours) == 0,
              current.st_dev == ours.st_dev, current.st_ino == ours.st_ino
        else { return }
        _ = dup2(original, fd)
    }

    /// Every byte, through short writes and interruptions; given up on any other error (the
    /// destination is gone — the bytes would have been lost without Zharp too).
    static func writeAll(_ fd: Int32, _ bytes: UnsafePointer<UInt8>, _ count: Int) {
        var offset = 0
        while offset < count {
            let written = write(fd, bytes + offset, count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}

/// Turns output bytes into log records, on a queue of its own: cut into lines (an unfinished one
/// is sent after 200 ms), read for level and message, checked against what the exact captures
/// just sent, then logged. If the app prints faster than this keeps up, the copy is dropped
/// beyond 1 MB waiting — the output itself is never held back.
final class OutputCollector: @unchecked Sendable {
    static let flushDelay: TimeInterval = 0.2
    static let maxBacklog = 1024 * 1024

    private let queue = DispatchQueue(label: "io.zharp.output", qos: .utility)
    private let recent: RecentLines
    private let emit: (CapturedLine, OutputStreamName) -> Void

    private let lock = NSLock()
    private var backlog = 0

    // On `queue`.
    private var buffers: [OutputStreamName: LineBuffer] = [:]
    private var flushScheduled: Set<OutputStreamName> = []

    init(recent: RecentLines, emit: @escaping (CapturedLine, OutputStreamName) -> Void) {
        self.recent = recent
        self.emit = emit
    }

    /// Bytes read from an output. Never blocks.
    func ingest(_ bytes: Data, from stream: OutputStreamName) {
        lock.lock()
        guard backlog + bytes.count <= OutputCollector.maxBacklog else {
            lock.unlock()
            return
        }
        backlog += bytes.count
        lock.unlock()
        queue.async { [self] in
            process(bytes, from: stream)
            lock.lock()
            backlog -= bytes.count
            lock.unlock()
        }
    }

    /// Waits until everything ingested so far has been logged, unfinished lines included. Tests.
    func drain() {
        queue.sync {
            for stream in [OutputStreamName.stdout, .stderr] { flushPending(stream) }
        }
    }

    private func process(_ bytes: Data, from stream: OutputStreamName) {
        var buffer = buffers[stream] ?? LineBuffer()
        let lines = buffer.append(bytes)
        let pending = buffer.hasPending
        buffers[stream] = buffer
        for line in lines { handle(line, from: stream) }
        if pending && !flushScheduled.contains(stream) {
            flushScheduled.insert(stream)
            queue.asyncAfter(deadline: .now() + OutputCollector.flushDelay) { [weak self] in
                self?.flushPending(stream)
            }
        }
    }

    private func flushPending(_ stream: OutputStreamName) {
        flushScheduled.remove(stream)
        guard var buffer = buffers[stream], let line = buffer.flush() else { return }
        buffers[stream] = buffer
        handle(line, from: stream)
    }

    private func handle(_ line: String, from stream: OutputStreamName) {
        guard let parsed = OutputLineParser.parse(line, stream: stream),
              !recent.alreadySent(OutputLineParser.stripANSI(line))
        else { return }
        emit(parsed, stream)
    }
}
