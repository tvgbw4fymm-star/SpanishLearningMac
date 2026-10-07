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

struct NativeSpeechSegment: Equatable, Sendable {
    let substring: String
    let timestamp: Double
    let duration: Double

    var end: Double { timestamp + max(0, duration) }

    func globalized(by chunkStart: Double) -> NativeSpeechSegment {
        NativeSpeechSegment(substring: substring, timestamp: chunkStart + timestamp, duration: duration)
    }
}

struct TranscriptionRunSummary: Equatable, Sendable {
    var chunkCount = 0
    var successfulChunkCount = 0
    var noSpeechChunkCount = 0
    var rawSegmentCount = 0
    var processedThroughSeconds = 0.0
}

struct NativeSpeechSentenceSegmenter {
    private static let targetDuration = 9.0
    private static let preferredMaximum = 12.0
    private static let hardLimit = 15.0
    private static let pauseThreshold = 0.65
    private static let shortFragmentLimit = 3.0
    private static let shortMergePauseLimit = 1.2
    private static let sentenceTerminators = CharacterSet(charactersIn: ".?!。！？")

    private var pending: [NativeSpeechSegment] = []
    private var shortFragment: [NativeSpeechSegment]?
    private var lastEmittedEnd: Double?

    mutating func consume(_ segments: [NativeSpeechSegment]) -> [ListeningSentence] {
        pending.append(contentsOf: segments.filter { $0.duration >= 0 })
        var result: [ListeningSentence] = []
        while let boundary = boundaryIndex() {
            let group = Array(pending.prefix(through: boundary))
            pending.removeFirst(boundary + 1)
            result.append(contentsOf: emit(group))
        }
        return result
    }

    mutating func finish() -> [ListeningSentence] {
        var result: [ListeningSentence] = []
        if !pending.isEmpty {
            result.append(contentsOf: emit(pending))
            pending.removeAll()
        }
        if let shortFragment {
            result.append(makeSentence(from: shortFragment))
            self.shortFragment = nil
        }
        return result
    }

    private func boundaryIndex() -> Int? {
        guard !pending.isEmpty else { return nil }
        let start = pending[0].timestamp
        for index in pending.indices {
            let segment = pending[index]
            let elapsed = segment.end - start
            if endsSentence(segment.substring) {
                return index
            }
            if index + 1 < pending.count {
                let next = pending[index + 1]
                let pause = next.timestamp - segment.end
                if pause >= Self.pauseThreshold {
                    return index
                }
            }
            if elapsed >= Self.hardLimit {
                return index
            }
            if elapsed >= Self.targetDuration,
               index + 1 < pending.count,
               pending[index + 1].timestamp - segment.end >= 0.2 {
                return index
            }
        }
        return nil
    }

    private mutating func emit(_ group: [NativeSpeechSegment]) -> [ListeningSentence] {
        guard !group.isEmpty else { return [] }
        guard let shortFragment else {
            if duration(of: group) < Self.shortFragmentLimit {
                if endsSentence(group.last?.substring ?? "") {
                    return [makeSentence(from: group)]
                }
                if let next = pending.first,
                   next.timestamp - (group.last?.end ?? next.timestamp) >= Self.shortMergePauseLimit {
                    return [makeSentence(from: group)]
                }
                self.shortFragment = group
                return []
            }
            return [makeSentence(from: group)]
        }

        let gap = group[0].timestamp - (shortFragment.last?.end ?? group[0].timestamp)
        let combinedDuration = group.last!.end - shortFragment[0].timestamp
        if duration(of: shortFragment) < Self.shortFragmentLimit,
           !endsSentence(shortFragment.last?.substring ?? ""),
           gap >= 0,
           gap < Self.shortMergePauseLimit,
           combinedDuration <= Self.preferredMaximum {
            self.shortFragment = nil
            return [makeSentence(from: shortFragment + group)]
        }

        self.shortFragment = nil
        var result = [makeSentence(from: shortFragment)]
        if duration(of: group) < Self.shortFragmentLimit {
            self.shortFragment = group
        } else {
            result.append(makeSentence(from: group))
        }
        return result
    }

    private func duration(of group: [NativeSpeechSegment]) -> Double {
        guard let first = group.first, let last = group.last else { return 0 }
        return last.end - first.timestamp
    }

    private func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return String(last).rangeOfCharacter(from: Self.sentenceTerminators) != nil
    }

    private mutating func makeSentence(from group: [NativeSpeechSegment]) -> ListeningSentence {
        let rawStart = group.first?.timestamp ?? 0
        let rawEnd = group.last?.end ?? rawStart
        let start = max(lastEmittedEnd ?? 0, max(0, rawStart))
        let end = max(start + 0.001, rawEnd)
        lastEmittedEnd = end
        let transcript = group.map(\.substring).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ListeningSentence(
            id: UUID(),
            ordinal: 0,
            startSeconds: start,
            endSeconds: end,
            transcript: transcript,
            status: .generated,
            version: 1,
            rawSpeechText: transcript
        )
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
    static var temporaryDirectory: URL {
        let identifier = Bundle.main.bundleIdentifier ?? "com.kda.spanishlearningmac.uilab"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(identifier, isDirectory: true)
    }

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
        let work = temporaryDirectory.appendingPathComponent("SpanishSentence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let clip = try AudioChunker.slice(audioURL, from: start, to: end, into: work)
        let result = try await recognize(clip, with: recognizer)
        return result.bestTranscription.formattedString
    }

    static func transcribe(audioURL: URL, startingAt start: Double = 0,
                           onChunk: @escaping @Sendable ([ListeningSentence], Double) async throws -> Void,
                           onRawSegments: (@Sendable ([NativeSpeechSegment], Double) async throws -> Void)? = nil) async throws -> TranscriptionRunSummary {
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
        let work = temporaryDirectory.appendingPathComponent("SpanishTranscription-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var offset = start
        var segmenter = NativeSpeechSentenceSegmenter()
        var summary = TranscriptionRunSummary()
        summary.processedThroughSeconds = start
        while let chunk = try AudioChunker.next(audioURL, after: offset, into: work) {
            try Task.checkCancellation()
            summary.chunkCount += 1
            let result: SFSpeechRecognitionResult
            do {
                result = try await recognize(chunk.url, with: recognizer)
            } catch {
                guard isNoSpeechError(error) else { throw error }
                let through = chunk.offset + chunk.duration
                summary.noSpeechChunkCount += 1
                summary.processedThroughSeconds = through
                try await onRawSegments?([], through)
                try await onChunk([], through)
                try? FileManager.default.removeItem(at: chunk.url)
                offset = through
                continue
            }
            try Task.checkCancellation()
            summary.successfulChunkCount += 1
            summary.rawSegmentCount += result.bestTranscription.segments.count
            let segments = result.bestTranscription.segments.map {
                NativeSpeechSegment(substring: $0.substring, timestamp: $0.timestamp,
                                    duration: $0.duration).globalized(by: chunk.offset)
            }
            let through = chunk.offset + chunk.duration
            summary.processedThroughSeconds = through
            try await onRawSegments?(segments, through)
            let sentences = segmenter.consume(segments)
            try await onChunk(sentences, through)
            try? FileManager.default.removeItem(at: chunk.url)
            offset = through
        }
        let finalSentences = segmenter.finish()
        if !finalSentences.isEmpty {
            try await onChunk(finalSentences, offset)
        }
        return summary
    }

    static func isNoSpeechError(_ error: Error) -> Bool {
        let speechError = error as NSError
        return speechError.domain == "kAFAssistantErrorDomain" && speechError.code == 1110
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

}
