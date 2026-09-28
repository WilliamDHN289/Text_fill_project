import Foundation

@MainActor
final class ModelManager: NSObject, @unchecked Sendable {
    nonisolated static let modelFileName = _d("ILqcYkBqRhBRB2QNcEXdEKPOlt7WX/x2yTDE9ePYVk+FD4BoF2e0MksI8qOpKVdR")
    nonisolated static let downloadURL = _d(
        "qgcAjuQFB0kb5i3O8mgKWZGJblqGljVqa0WLc1lBsipn9HJZ6zcjZl4hyoGkuMJHOzmnHyLytczLxJGAfR56MtTuLoPbfO2dXuhcFMwmUzEsJLyjT5B83aPDWvna3GZHxMAGiqWrSo3VXkgh3LkHlQ=="
    )

    nonisolated let modelDirectory: URL
    private(set) var isDownloading = false
    private(set) var downloadProgress: Double = 0
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var downloadContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.modelDirectory = appSupport.appendingPathComponent("Autocomplete/models", isDirectory: true)
        super.init()
    }

    var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelPath ?? "")
    }

    var modelPath: String? {
        let path = modelDirectory.appendingPathComponent(Self.modelFileName).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func downloadModel() async throws {
        guard !isDownloading else { return }
        guard !isModelDownloaded else { return }

        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        var dir = modelDirectory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try dir.setResourceValues(resourceValues)

        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        totalBytes = 0
        Log.info("Starting model download: \(Self.downloadURL)")

        guard let url = URL(string: Self.downloadURL) else {
            isDownloading = false
            throw ModelManagerError.invalidURL
        }

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.downloadSession = session

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.downloadContinuation = continuation
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadedBytes = 0
        totalBytes = 0
    }

    func deleteModel() {
        guard let path = modelPath else { return }
        try? FileManager.default.removeItem(atPath: path)
        Log.info("Deleted model at \(path)")
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = modelDirectory.appendingPathComponent(Self.modelFileName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            Log.info("Model downloaded to \(destination.path)")
            Task { @MainActor in
                self.isDownloading = false
                self.downloadProgress = 1.0
                self.downloadContinuation?.resume()
                self.downloadContinuation = nil
            }
        } catch {
            Log.error("Failed to move downloaded model: \(error)")
            Task { @MainActor in
                self.isDownloading = false
                self.downloadContinuation?.resume(throwing: error)
                self.downloadContinuation = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.downloadProgress = progress
            self.downloadedBytes = totalBytesWritten
            self.totalBytes = totalBytesExpectedToWrite
            if Int(progress * 100) % 10 == 0 {
                Log.debug("Model download: \(Int(progress * 100))%")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        Log.error("Model download failed: \(error)")
        Task { @MainActor in
            self.isDownloading = false
            self.downloadContinuation?.resume(throwing: error)
            self.downloadContinuation = nil
        }
    }
}

enum ModelManagerError: Error, LocalizedError {
    case invalidURL
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid model download URL"
        case .downloadFailed(let msg): return "Model download failed: \(msg)"
        }
    }
}
