import Foundation
import CryptoKit

struct BackupSummary: Sendable {
    let createdAt: Date
    let audioCount: Int
    let articleCount: Int
    let readingCount: Int
    let writingCount: Int
    let cardCount: Int
    let mediaBytes: Int64
}

private struct BackupFile: Codable {
    let path: String
    let bytes: Int64
    let sha256: String
}

private struct BackupManifest: Codable {
    let formatVersion: Int
    let createdAt: Date
    let files: [BackupFile]
}

enum BackupError: LocalizedError {
    case invalidArchive
    case unsupportedFormat
    case missingMedia(String)
    case brokenSource(String)
    case busy
    case commandFailed(String)
    case recoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "备份文件不完整或已损坏，未更改本机资料。"
        case .unsupportedFormat: "此备份由更新版本的应用创建，请先更新应用。"
        case .missingMedia(let name): "备份缺少音频文件：\(name)。"
        case .brokenSource(let name): "备份中的学习记录无法关联原材料：\(name)。"
        case .busy: "备份或恢复正在进行，请稍后重试。"
        case .commandFailed(let message): "无法处理备份文件：\(message)"
        case .recoveryFailed(let path): "恢复未完成，原资料保留在：\(path)。请勿删除该目录。"
        }
    }
}

enum BackupManager {
    private static let rootName = "SpanishLearningBackup"
    private static let fm = FileManager.default

    static func create(database: Data, mediaDirectory: URL, destination: URL) throws -> BackupSummary {
        let work = fm.temporaryDirectory.appendingPathComponent("SpanishBackup-\(UUID().uuidString)", isDirectory: true)
        let root = work.appendingPathComponent(rootName, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: root.appendingPathComponent("Media", isDirectory: true), withIntermediateDirectories: true)
        try database.write(to: root.appendingPathComponent("study.json"), options: .atomic)
        if fm.fileExists(atPath: mediaDirectory.path) {
            for source in try regularFiles(in: mediaDirectory) {
                let relative = try relativePath(source, from: mediaDirectory)
                let target = root.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
            }
        }
        let files = try regularFiles(in: root).map { file -> BackupFile in
            let relative = try relativePath(file, from: root)
            let digest = try hash(file)
            return BackupFile(path: relative, bytes: digest.bytes, sha256: digest.sha256)
        }.sorted { $0.path < $1.path }
        let manifest = BackupManifest(formatVersion: 1, createdAt: .now, files: files)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        _ = try validate(root: root)

        let archive = work.appendingPathComponent("backup.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.path, archive.path])
        let destinationParent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        let pending = destinationParent.appendingPathComponent(".\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: pending) }
        try fm.copyItem(at: archive, to: pending)
        let verifiedSummary = try inspect(pending)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: pending)
        } else {
            try fm.moveItem(at: pending, to: destination)
        }
        return verifiedSummary
    }

    static func inspect(_ archive: URL) throws -> BackupSummary {
        let work = fm.temporaryDirectory.appendingPathComponent("SpanishInspect-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let root = try extract(archive, into: work)
        let (_, result) = try validate(root: root)
        return result
    }

    // Returns the location of the automatic copy of the previous local data, if one existed.
    static func restore(_ archive: URL, supportDirectory: URL) throws -> URL? {
        let parent = supportDirectory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let work = parent.appendingPathComponent(".SpanishRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let root = try extract(archive, into: work)
        _ = try validate(root: root)

        let hadCurrent = fm.fileExists(atPath: supportDirectory.path)
        let backupFolder = parent.appendingPathComponent(
            "\(supportDirectory.lastPathComponent) Backups", isDirectory: true
        )
        var safetyCopy: URL?
        if hadCurrent {
            try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            let previousDatabase = supportDirectory.appendingPathComponent("study.json")
            if let payload = try? Data(contentsOf: previousDatabase) {
                let safetyArchive = backupFolder.appendingPathComponent("恢复前-\(UUID().uuidString).zip")
                if (try? create(database: payload,
                                mediaDirectory: supportDirectory.appendingPathComponent("Media", isDirectory: true),
                                destination: safetyArchive)) != nil {
                    safetyCopy = safetyArchive
                }
            }
            if safetyCopy == nil {
                // Preserve even a damaged local library before replacing it.
                let safetyDirectory = backupFolder.appendingPathComponent("恢复前-\(UUID().uuidString)", isDirectory: true)
                try fm.copyItem(at: supportDirectory, to: safetyDirectory)
                safetyCopy = safetyDirectory
            }
        }

        let rollback = work.appendingPathComponent("rollback", isDirectory: true)
        if hadCurrent { try fm.moveItem(at: supportDirectory, to: rollback) }
        do {
            try fm.moveItem(at: root, to: supportDirectory)
        } catch {
            if hadCurrent {
                do { try fm.moveItem(at: rollback, to: supportDirectory) }
                catch { throw BackupError.recoveryFailed(safetyCopy?.path ?? rollback.path) }
            }
            throw error
        }
        return safetyCopy
    }

    private static func extract(_ archive: URL, into work: URL) throws -> URL {
        let list = try run("/usr/bin/unzip", ["-Z", "-1", archive.path])
        let entries = list.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !entries.isEmpty, entries.allSatisfy({ entry in
            let trimmed = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            return parts.first == Substring(rootName) && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
                && !entry.contains("\\")
        }) else { throw BackupError.invalidArchive }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path])
        let root = work.appendingPathComponent(rootName, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { throw BackupError.invalidArchive }
        return root
    }

    private static func validate(root: URL) throws -> (StudyDatabase, BackupSummary) {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else { throw BackupError.invalidArchive }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(BackupManifest.self, from: manifestData) else { throw BackupError.invalidArchive }
        guard manifest.formatVersion == 1 else { throw BackupError.unsupportedFormat }
        let actual = try regularFiles(in: root)
        let actualPaths = Set(try actual.map { try relativePath($0, from: root) })
        let listedPaths = Set(manifest.files.map(\.path))
        guard listedPaths.count == manifest.files.count,
              listedPaths.union(["manifest.json"]) == actualPaths,
              listedPaths.contains("study.json") else { throw BackupError.invalidArchive }
        for file in manifest.files {
            guard file.path == "study.json" || file.path.hasPrefix("Media/") else { throw BackupError.invalidArchive }
            let actualDigest = try hash(root.appendingPathComponent(file.path))
            guard actualDigest.bytes == file.bytes && actualDigest.sha256 == file.sha256 else { throw BackupError.invalidArchive }
        }
        let database = try decode(Data(contentsOf: root.appendingPathComponent("study.json")))
        for material in database.audioMaterials {
            guard material.fileName == URL(fileURLWithPath: material.fileName).lastPathComponent,
                  !material.fileName.isEmpty,
                  listedPaths.contains("Media/\(material.fileName)") else { throw BackupError.missingMedia(material.fileName) }
        }
        try validateSources(database)
        return (database, summary(database: database, manifest: manifest))
    }

    private static func validateSources(_ db: StudyDatabase) throws {
        var articles: [UUID: Set<UUID>] = [:]
        var audio: [UUID: Set<UUID>] = [:]
        var writing: [UUID: Set<UUID>] = [:]
        for article in db.articles {
            guard articles[article.id] == nil else { throw BackupError.invalidArchive }
            articles[article.id] = Set(article.chunks.map(\.id))
        }
        for material in db.audioMaterials {
            guard audio[material.id] == nil else { throw BackupError.invalidArchive }
            audio[material.id] = Set(material.sentences.map(\.id))
        }
        for exercise in db.writingExercises {
            guard writing[exercise.id] == nil else { throw BackupError.invalidArchive }
            writing[exercise.id] = Set(exercise.versions.map(\.id))
        }
        for record in db.readingRecords where articles[record.articleID]?.contains(record.chunkID) != true {
            throw BackupError.brokenSource("阅读记录")
        }
        for attempt in db.dictationAttempts where audio[attempt.materialID]?.contains(attempt.sentenceID) != true {
            throw BackupError.brokenSource("听写记录")
        }
        for exercise in db.writingExercises {
            if let id = exercise.sourceID {
                guard let segments = articles[id] ?? audio[id],
                      exercise.sourceSegmentID == nil || segments.contains(exercise.sourceSegmentID!) else {
                    throw BackupError.brokenSource("写作练习")
                }
            } else if exercise.sourceSegmentID != nil {
                throw BackupError.brokenSource("写作练习")
            }
        }
        for card in db.cards {
            for source in card.sources {
                guard let segments = articles[source.materialID] ?? audio[source.materialID] ?? writing[source.materialID],
                      source.segmentID == nil || segments.contains(source.segmentID!) else { throw BackupError.brokenSource("学习卡片") }
            }
        }
        let cardIDs = Set(db.cards.map(\.id))
        for record in db.readingRecords {
            if let linkedCards = record.cardIDs, !Set(linkedCards).isSubset(of: cardIDs) {
                throw BackupError.brokenSource("阅读卡片")
            }
            if let discussionIDs = record.discussionIDs {
                guard let chunk = db.articles.first(where: { $0.id == record.articleID })?
                    .chunks.first(where: { $0.id == record.chunkID }),
                      Set(discussionIDs).isSubset(of: Set((chunk.discussion ?? []).map(\.id))) else {
                    throw BackupError.brokenSource("精读对话")
                }
            }
        }
        for version in db.writingExercises.flatMap(\.versions) {
            if let cardID = version.cardID, !cardIDs.contains(cardID) { throw BackupError.brokenSource("写作纠错卡片") }
        }
        for event in db.reviewEvents where !cardIDs.contains(event.cardID) { throw BackupError.brokenSource("复习记录") }
    }

    private static func decode(_ payload: Data) throws -> StudyDatabase {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let db = try? decoder.decode(StudyDatabase.self, from: payload) else { throw BackupError.invalidArchive }
        guard db.schemaVersion == 1 else { throw BackupError.unsupportedFormat }
        return db
    }

    private static func summary(database: StudyDatabase, manifest: BackupManifest) -> BackupSummary {
        BackupSummary(createdAt: manifest.createdAt, audioCount: database.audioMaterials.count,
                      articleCount: database.articles.count, readingCount: database.readingRecords.count,
                      writingCount: database.writingExercises.count, cardCount: database.cards.count,
                      mediaBytes: manifest.files.filter { $0.path.hasPrefix("Media/") }.reduce(0) { $0 + $1.bytes })
    }

    private static func relativePath(_ file: URL, from root: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath + "/"
        guard filePath.hasPrefix(prefix) else { throw BackupError.invalidArchive }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func regularFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else {
            throw BackupError.invalidArchive
        }
        var result: [URL] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw BackupError.invalidArchive }
            if values.isRegularFile == true { result.append(file) }
        }
        return result
    }

    private static func hash(_ file: URL) throws -> (bytes: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            bytes += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        return (bytes, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    @discardableResult private static func run(_ command: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command)
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw BackupError.commandFailed(String(data: data, encoding: .utf8) ?? command)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
