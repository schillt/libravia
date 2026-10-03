import Foundation
import JavaScriptCore

/// Uses the exact JSZip version required by Jellyfin Web's EPUB stack.
/// JavaScriptCore uses the main run loop for Promise jobs; no WebKit view or network is involved.
enum ArchiveExtractor {
    static func extract(_ source: URL, to destination: URL, scriptURL: URL? = nil) async throws {
        let job = ArchiveJob(source: source, destination: destination, scriptURL: scriptURL)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in job.start { continuation.resume(with: $0) } }
        } onCancel: { job.cancel() }
    }
}
private final class ArchiveJob: @unchecked Sendable {
    let source: URL
    let destination: URL
    let scriptURL: URL?
    let queue = DispatchQueue.main
    private let lock = NSLock()
    private var cancelled = false
    private var context: JSContext?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var total: UInt64 = 0
    private var paths = Set<String>()
    private var sizes: [String: Int] = [:]
    init(source: URL, destination: URL, scriptURL: URL?) { self.source = source; self.destination = destination; self.scriptURL = scriptURL }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func finish(_ result: Result<Void, Error>) { guard let completion else { return }; self.completion = nil; context = nil; completion(result) }
    func start(_ completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.completion = completion
            self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish(.failure(ReaderError.message("Archive extraction took too long."))) }
            do {
                guard !self.isCancelled else { throw CancellationError() }
                let size = try self.source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 128 * 1024 * 1024 else { throw ReaderError.message("EPUB and CBZ archives must be smaller than 128 MB.") }
                guard let script = self.scriptURL ?? Bundle.main.url(forResource: "jszip.min", withExtension: "js", subdirectory: "Archive"), let context = JSContext() else { throw ReaderError.message("The archive reader is unavailable.") }
                self.context = context
                let schedule: @convention(block) (JSValue) -> Void = { [weak self] callback in
                    self?.queue.async { [weak self] in guard let self, self.completion != nil else { return }; if self.isCancelled { self.finish(.failure(CancellationError())) } else { callback.call(withArguments: []) } }
                }
                let validate: @convention(block) (String, Double, Bool) -> Bool = { [weak self] path, size, symlink in
                    guard let self, !self.isCancelled, size.isFinite, size >= 0, size <= Double(128 * 1024 * 1024) else { return false }
                    do {
                        self.total += UInt64(size)
                        try BookCache.validateEntry(path: path, size: UInt64(size), total: self.total, count: self.paths.count + 1)
                        guard !symlink, self.paths.insert(path.lowercased()).inserted else { return false }
                        self.sizes[path] = Int(size)
                        return true
                    } catch { return false }
                }
                let save: @convention(block) (String, String) -> Bool = { [weak self] path, base64 in
                    guard let self, !self.isCancelled, let expected = self.sizes[path], let data = Data(base64Encoded: base64), data.count == expected else { return false }
                    let file = self.destination.appendingPathComponent(path).standardizedFileURL
                    guard file.path.hasPrefix(self.destination.standardizedFileURL.path + "/") else { return false }
                    do { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try PrivateBookFiles.write(data, to: file); return true } catch { return false }
                }
                let done: @convention(block) (Bool) -> Void = { [weak self] success in guard let self else { return }; self.finish(success ? .success(()) : .failure(self.isCancelled ? CancellationError() : ReaderError.message("This archive is damaged, encrypted, unsafe, or exceeds extraction limits."))) }
                context.setObject(schedule, forKeyedSubscript: "nativeSchedule" as NSString)
                context.setObject(validate, forKeyedSubscript: "nativeValidate" as NSString)
                context.setObject(save, forKeyedSubscript: "nativeSave" as NSString)
                context.setObject(done, forKeyedSubscript: "nativeDone" as NSString)
                context.exceptionHandler = { [weak self] _, _ in self?.finish(.failure(ReaderError.message("The archive could not be decoded."))) }
                context.evaluateScript("var global = this; var self = this; function setTimeout(fn, delay, ...args) { nativeSchedule(function() { fn(...args); }); } function setImmediate(fn, ...args) { nativeSchedule(function() { fn(...args); }); }")
                context.evaluateScript(try String(contentsOf: script, encoding: .utf8))
                context.setObject(try Data(contentsOf: self.source).base64EncodedString(), forKeyedSubscript: "archiveData" as NSString)
                context.evaluateScript("""
                (async function () {
                  try {
                    const zip = await JSZip.loadAsync(archiveData, {base64:true}); archiveData = null;
                    const entries = Object.values(zip.files);
                    if (entries.length > 10000) throw new Error();
                    // JSZip's pinned compressed-data metadata lets us reject oversized output before inflation.
                    for (const entry of entries) {
                      const path = entry.unsafeOriginalName || entry.name;
                      const size = entry.dir ? 0 : entry._data.uncompressedSize;
                      if (!nativeValidate(path, size, (entry.unixPermissions & 61440) === 40960)) throw new Error();
                    }
                    for (const entry of entries) {
                      if (!entry.dir && !nativeSave(entry.unsafeOriginalName || entry.name, await entry.async('base64'))) throw new Error();
                    }
                    nativeDone(true);
                  } catch (_) { nativeDone(false); }
                })();
                """)
            } catch { self.finish(.failure(error)) }
        }
    }
}
