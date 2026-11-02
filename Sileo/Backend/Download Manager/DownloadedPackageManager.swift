import Foundation
import UIKit
import Evander

struct DownloadedPackage {
    let fileURL: URL
    let package: Package?
    let size: Int64
    let downloadedAt: Date
    let metadataLoaded: Bool

    var id: String { fileURL.path }
}

final class DownloadedPackageManager {
    static let shared = DownloadedPackageManager()
    static let changedNotification = Notification.Name("DownloadedPackagesChanged")

    private let directory: URL
    private let cacheURL: URL
    private let fileQueue = DispatchQueue(label: "Sileo.DownloadedPackages", qos: .utility)
    private var recordCache: [String: DownloadedPackage] = [:]
    private var visibleRecords: [String: DownloadedPackage] = [:]
    private var cacheDirty = false
    private var activeID: UUID?
    private var task: EvanderDownloader?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var completion: ((Result<DownloadedPackage, Swift.Error>) -> Void)?

    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct CachedRecord: Codable {
        let filename: String
        let size: Int64
        let downloadedAt: Date
        let control: [String: String]?
        let tags: Int
    }

    init(directory: URL = FileManager.default.documentDirectory.appendingPathComponent("DownloadedPackages", isDirectory: true),
         cacheURL: URL = EvanderNetworking._cacheDirectory.appendingPathComponent("DownloadedPackages.plist")) {
        self.directory = directory
        self.cacheURL = cacheURL
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? PropertyListDecoder().decode([CachedRecord].self, from: data) {
            for entry in cached where entry.filename == (entry.filename as NSString).lastPathComponent {
                let url = directory.appendingPathComponent(entry.filename)
                let package = entry.control.flatMap {
                    PackageListManager.package(packageEnum: ($0, PackageTags(rawValue: entry.tags)))
                }
                recordCache[entry.filename] = DownloadedPackage(fileURL: url, package: package, size: entry.size,
                                                     downloadedAt: entry.downloadedAt, metadataLoaded: true)
            }
            visibleRecords = recordCache
        }
        loadRecords { _ in }
    }

    private var files: [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        return entries.filter { url in
            guard url.pathExtension.lowercased() == "deb",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return true
        }
    }

    var count: Int { files.count }

    func currentRecords() -> [DownloadedPackage] {
        precondition(Thread.isMainThread)
        return files.compactMap { try? fileRecord(at: $0, cached: visibleRecords[$0.lastPathComponent]) }
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    func loadRecords(completion: @escaping ([DownloadedPackage]) -> Void) {
        fileQueue.async {
            let files = self.files
            let existingFiles = Set(files.map { $0.lastPathComponent })
            let previousCount = self.recordCache.count
            self.recordCache = self.recordCache.filter { existingFiles.contains($0.key) }
            self.cacheDirty = self.cacheDirty || self.recordCache.count != previousCount
            let records = files.compactMap { try? self.readRecord(at: $0) }
                .sorted { $0.downloadedAt > $1.downloadedAt }
            self.saveCache()
            DispatchQueue.main.async {
                let records = records.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
                self.visibleRecords = self.visibleRecords.filter { FileManager.default.fileExists(atPath: $0.value.fileURL.path) }
                for record in records {
                    self.visibleRecords[record.fileURL.lastPathComponent] = record
                }
                completion(records)
            }
        }
    }

    private func saveCache() {
        guard cacheDirty else { return }
        let records = recordCache.values.map {
            CachedRecord(filename: $0.fileURL.lastPathComponent, size: $0.size, downloadedAt: $0.downloadedAt,
                         control: $0.package?.rawControl, tags: $0.package?.tags.rawValue ?? 0)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            let data = try encoder.encode(records)
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            cacheDirty = false
        } catch {
            return
        }
    }

    private func readPackage(at url: URL) throws -> Package {
        let fields = try DpkgWrapper.rawFields(packageURL: url)
        let control = try ControlFileParser.dictionary(controlFile: fields, isReleaseFile: true)
        guard let package = PackageListManager.package(packageEnum: control),
              !package.package.isEmpty, !package.version.isEmpty else {
            throw DownloadError(message: String(localizationKey: "Downloaded_Packages.Unavailable"))
        }
        return package
    }

    private func fileRecord(at url: URL, cached: DownloadedPackage?) throws -> DownloadedPackage {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let fileSize = values.fileSize, let date = values.contentModificationDate else {
            throw DownloadError(message: String(localizationKey: "Downloaded_Packages.Unavailable"))
        }
        let size = Int64(fileSize)
        if let record = cached, record.size == size, record.downloadedAt == date {
            return record
        }
        return DownloadedPackage(fileURL: url, package: nil, size: size, downloadedAt: date, metadataLoaded: false)
    }

    private func readRecord(at url: URL) throws -> DownloadedPackage {
        let file = try fileRecord(at: url, cached: recordCache[url.lastPathComponent])
        if file.metadataLoaded { return file }
        let package = try? readPackage(at: url)
        let record = DownloadedPackage(fileURL: url, package: package, size: file.size,
                                       downloadedAt: file.downloadedAt, metadataLoaded: true)
        recordCache[url.lastPathComponent] = record
        cacheDirty = true
        return record
    }

    func delete(_ record: DownloadedPackage) throws {
        precondition(Thread.isMainThread)
        try FileManager.default.removeItem(at: record.fileURL)
        visibleRecords.removeValue(forKey: record.fileURL.lastPathComponent)
        fileQueue.async {
            self.recordCache.removeValue(forKey: record.fileURL.lastPathComponent)
            self.cacheDirty = true
            self.saveCache()
        }
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    func fileURL(for record: DownloadedPackage) -> URL {
        record.fileURL
    }

    func loadIcon(for record: DownloadedPackage, completion: @escaping (UIImage) -> Void = { _ in }) -> UIImage {
        guard let package = record.package else { return UIImage(named: "Category_tweak")! }
        let iconURL = package.icon ?? RepoManager.shared.repoList.lazy.compactMap {
            $0.packageDict[package.architecture]?[package.package]?[package.version]?.icon
        }.first
        return EvanderNetworking.image(url: iconURL, size: CGSize(width: 40, height: 40)) { image in
            DispatchQueue.main.async {
                completion(image)
            }
        } ?? package.defaultIcon
    }

    func shareCopy(_ record: DownloadedPackage) throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let copy = temporary.appendingPathComponent(record.fileURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: fileURL(for: record), to: copy)
            return copy
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func download(_ package: Package, progress: @escaping (String) -> Void,
                  completion: @escaping (Result<DownloadedPackage, Swift.Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard activeID == nil else {
            completion(.failure(DownloadError(message: String(localizationKey: "Downloaded_Packages.Busy"))))
            return
        }
        guard package.sourceRepo != nil, package.filename != nil, package.local_deb == nil else {
            completion(.failure(DownloadError(message: String(localizationKey: "Downloaded_Packages.Unavailable"))))
            return
        }
        let id = UUID()
        activeID = id
        self.completion = completion
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard self?.activeID == id else { return }
            self?.cancelDownload()
            completion(.failure(DownloadError(message: String(localizationKey: "Downloaded_Packages.Interrupted"))))
        }
        fileQueue.async {
            let filename = self.filename(for: package)
            var existingRecord: DownloadedPackage?
            for url in self.files where self.matchesFilename(url.lastPathComponent, filename: filename) {
                do {
                    try DownloadManager.verifyPackageFile(package: package, fileURL: url)
                    let record = try self.readRecord(at: url)
                    guard record.package != nil else { continue }
                    existingRecord = record
                    break
                } catch { continue }
            }
            DispatchQueue.main.async {
                guard self.activeID == id else { return }
                if let record = existingRecord, FileManager.default.fileExists(atPath: record.fileURL.path) {
                    self.finish(.success(record))
                } else {
                    self.startDownload(package, id: id, progress: progress)
                }
            }
        }
    }

    private func startDownload(_ package: Package, id: UUID, progress: @escaping (String) -> Void) {
        DownloadManager.shared.resolveDownloadURL(package: package) { error, url in
            DispatchQueue.main.async {
                guard self.activeID == id else { return }
                guard error == nil, let url = url else {
                    self.finish(.failure(DownloadError(message: error ?? String(localizationKey: "Downloaded_Packages.Unavailable"))))
                    return
                }
                self.task = RepoManager.shared.queue(from: url, progress: { _, value in
                    DispatchQueue.main.async {
                        guard self.activeID == id else { return }
                        let size = ByteCountFormatter.string(fromByteCount: value.total, countStyle: .file)
                        progress(value.expected > 0 ? "\(Int(value.fractionCompleted * 100))% · \(size)" : size)
                    }
                }, success: { _, _, fileURL in
                    self.fileQueue.async {
                        let result = Result {
                            try DownloadManager.verifyPackageFile(package: package, fileURL: fileURL)
                            return try self.readPackage(at: fileURL)
                        }
                        DispatchQueue.main.async {
                            defer { try? FileManager.default.removeItem(at: fileURL) }
                            guard self.activeID == id else { return }
                            do {
                                let downloadedPackage = try result.get()
                                let record = try self.save(downloadedPackage, filename: self.filename(for: package), fileURL: fileURL)
                                self.finish(.success(record))
                            } catch {
                                self.finish(.failure(error))
                            }
                        }
                    }
                }, failure: { _, status, error in
                    DispatchQueue.main.async {
                        guard self.activeID == id else { return }
                        let message = error?.localizedDescription ?? String(format: String(localizationKey: "Download_Failing_Status_Code", type: .error), status)
                        self.finish(.failure(DownloadError(message: message)))
                    }
                }, waiting: { _, message in
                    DispatchQueue.main.async {
                        guard self.activeID == id else { return }
                        progress(message)
                    }
                })
                guard let task = self.task else {
                    if self.activeID == id {
                        self.finish(.failure(DownloadError(message: String(localizationKey: "Downloaded_Packages.Unavailable"))))
                    }
                    return
                }
                task.resume()
            }
        }
    }

    func cancelDownload() {
        precondition(Thread.isMainThread)
        activeID = nil
        task?.cancel()
        task = nil
        completion = nil
        endBackgroundTask()
    }

    private func finish(_ result: Result<DownloadedPackage, Swift.Error>) {
        let callback = completion
        cancelDownload()
        callback?(result)
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func filename(for package: Package) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".+-_"))
        return "\(package.package)_\(package.version)_\(package.architecture ?? "unknown")".unicodeScalars.map {
            allowed.contains($0) ? String($0) : "_"
        }.joined() + ".deb"
    }

    private func matchesFilename(_ candidate: String, filename: String) -> Bool {
        if candidate == filename { return true }
        let prefix = (filename as NSString).deletingPathExtension + " ("
        guard candidate.hasPrefix(prefix), candidate.hasSuffix(").deb") else { return false }
        let suffix = candidate.dropFirst(prefix.count).dropLast(").deb".count)
        guard let number = Int(suffix) else { return false }
        return number >= 2 && String(number) == suffix
    }

    private func save(_ package: Package, filename: String, fileURL: URL) throws -> DownloadedPackage {
        let date = Date()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var destination = directory.appendingPathComponent(filename)
        let basename = (filename as NSString).deletingPathExtension
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(basename) (\(number)).deb")
            number += 1
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
        try FileManager.default.moveItem(at: fileURL, to: destination)
        let savedFile = try fileRecord(at: destination, cached: nil)
        let record = DownloadedPackage(fileURL: destination, package: package,
                                       size: savedFile.size, downloadedAt: savedFile.downloadedAt, metadataLoaded: true)
        visibleRecords[record.fileURL.lastPathComponent] = record
        fileQueue.async {
            self.recordCache[record.fileURL.lastPathComponent] = record
            self.cacheDirty = true
            self.saveCache()
        }
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        return record
    }
}
