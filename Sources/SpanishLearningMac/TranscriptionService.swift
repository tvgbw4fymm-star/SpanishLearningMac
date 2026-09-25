import Foundation
import Speech

struct WhisperResponse: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }
    let segments: [Segment]
}

enum TranscriptionError: LocalizedError {
    case authorizationDenied
    case missingUsageDescription
    case onDeviceUnavailable
    case badResponse

    var errorDescription: String? {
        switch self {
        case .authorizationDenied: "请在系统设置中允许本应用使用语音识别。"
        case .missingUsageDescription: "当前 Xcode 运行配置缺少语音识别权限说明，请使用带权限配置的应用构建。"
        case .onDeviceUnavailable: "这台 Mac 暂时没有可用的西语本地语音识别，请检查系统语音资源后重试。"
        case .badResponse: "本机语音识别没有返回有效文字，请检查音频后重试。"
        }
    }
}

enum SentenceSegmenter {
    static func sentences(from segment: WhisperResponse.Segment, offset: Double) -> [ListeningSentence] {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, segment.end > segment.start else { return [] }
        let pattern = #"(?<=[.!?])\s+(?=[¿¡A-ZÁÉÍÓÚÜÑ])"#
        let parts = text.components(separatedBy: try! NSRegularExpression(pattern: pattern))
        let cleaned = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let total = Double(cleaned.reduce(0) { $0 + $1.count })
        var cursor = segment.start + offset
        return cleaned.enumerated().map { index, part in
            let share = Double(part.count) / max(1, total)
            let end = index == cleaned.count - 1 ? segment.end + offset : cursor + (segment.end - segment.start) * share
            let sentence = ListeningSentence(id: UUID(), ordinal: 0, startSeconds: cursor,
                                             endSeconds: end, transcript: part, status: .generated, version: 1)
            cursor = end
            return sentence
        }
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let range = NSRange(startIndex..., in: self)
        let matches = regex.matches(in: self, range: range)
        var result: [String] = []
        var cursor = startIndex
        for match in matches {
            guard let splitRange = Range(match.range, in: self) else { continue }
            result.append(String(self[cursor..<splitRange.lowerBound]))
            cursor = splitRange.upperBound
        }
        result.append(String(self[cursor...]))
        return result
    }
}

enum TranscriptionService {
    static func recognizeSentence(audioURL: URL, start: Double, end: Double) async throws -> String {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw TranscriptionError.missingUsageDescription
        }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw TranscriptionError.authorizationDenied }
        let supported = SFSpeechRecognizer.supportedLocales()
        let locale = ["es-ES", "es-MX"].compactMap { candidate in
            supported.first { $0.identifier.caseInsensitiveCompare(candidate) == .orderedSame }
        }.first
        guard let locale, let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceUnavailable
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("SpanishSentence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let clip = try AudioChunker.slice(audioURL, from: start, to: end, into: work)
        let result = try await recognize(clip, with: recognizer)
        return result.bestTranscription.formattedString
    }

    static func transcribe(audioURL: URL, startingAt start: Double = 0,
                           onChunk: @escaping @Sendable ([ListeningSentence], Double) async throws -> Void) async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw TranscriptionError.missingUsageDescription
        }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw TranscriptionError.authorizationDenied }
        let supported = SFSpeechRecognizer.supportedLocales()
        let locale = ["es-ES", "es-MX"].compactMap { candidate in
            supported.first { $0.identifier.caseInsensitiveCompare(candidate) == .orderedSame }
        }.first
        guard let locale, let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceUnavailable
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("SpanishTranscription-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var offset = start
        while let chunk = try AudioChunker.next(audioURL, after: offset, into: work) {
            try Task.checkCancellation()
            let result = try await recognize(chunk.url, with: recognizer)
            try Task.checkCancellation()
            let sentences = sentences(from: result, offset: chunk.offset)
            let through = chunk.offset + chunk.duration
            try await onChunk(sentences, through)
            try? FileManager.default.removeItem(at: chunk.url)
            offset = through
        }
    }

    private static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> SFSpeechRecognitionResult {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private static func sentences(from result: SFSpeechRecognitionResult, offset: Double) -> [ListeningSentence] {
        let words = result.bestTranscription.segments
        guard !words.isEmpty else { return [] }
        var sentences: [ListeningSentence] = []
        var group: [SFTranscriptionSegment] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let text = group.map(\.substring).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                sentences.append(ListeningSentence(id: UUID(), ordinal: 0,
                    startSeconds: offset + first.timestamp,
                    endSeconds: offset + last.timestamp + last.duration,
                    transcript: text, status: .generated, version: 1))
            }
            group.removeAll()
        }
        for word in words {
            group.append(word)
            let end = word.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if end.hasSuffix(".") || end.hasSuffix("?") || end.hasSuffix("!") ||
                (word.timestamp + word.duration - (group.first?.timestamp ?? 0)) >= 18 {
                flush()
            }
        }
        flush()
        return sentences
    }
}
