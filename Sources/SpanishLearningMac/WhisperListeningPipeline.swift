import Foundation

struct WhisperTimedWord: Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct WhisperTimedSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct WhisperTimestampDiagnostics: Sendable {
    var invalidWords: [String: Int] = [:]
    var invalidSegments: [String: Int] = [:]

    var filteredCount: Int {
        invalidWords.values.reduce(0, +) + invalidSegments.values.reduce(0, +)
    }

    var summary: String {
        let wordSummary = invalidWords.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        let segmentSummary = invalidSegments.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return ["words[\(wordSummary)]", "segments[\(segmentSummary)]"].joined(separator: " ")
    }
}

struct WhisperTimestampQCResult: Sendable {
    let words: [WhisperTimedWord]
    let segments: [WhisperTimedSegment]
    let diagnostics: WhisperTimestampDiagnostics
}

struct WhisperTranscriptionResult {
    let audioDuration: Double
    let timestampedWords: [WhisperTimedWord]
    let timestampedSegments: [WhisperTimedSegment]
    let diagnostics: WhisperTimestampDiagnostics
    let elapsedSeconds: Double
}

struct WhisperSubtitleAlignment {
    let sentences: [ListeningSentence]
    let directCount: Int
    let interpolatedCount: Int
    let originalCount: Int
    let conflictCount: Int
    let matchedTokenCount: Int
    let subtitleTokenCount: Int
}

enum WhisperPipelineError: Error {
    case invalidAudioDuration
    case noTimedTranscript
    case invalidFinalTiming
}

enum WhisperListeningPipeline {
    private static let numericTolerance = 0.05
    private static let insertionCost = 0.90
    private static let deletionCost = 0.90
    private static let tokenExpression = try! NSRegularExpression(
        pattern: #"[^\W_]+(?:['’][^\W_]+)*"#,
        options: []
    )

    private struct Token {
        let value: String
        let normalized: String
    }

    private struct TimedToken {
        let token: Token
        let start: Double
        let end: Double
        let wordIndex: Int
    }

    private struct Match {
        let sourceIndex: Int
        let targetIndex: Int
        let cost: Double
    }

    private struct CueResult {
        let cue: SubtitleCue
        let matchCount: Int
        let relevantTokenCount: Int
        let matchedText: String
        let candidateStart: Double?
        let candidateEnd: Double?
        let matchedIndices: [Int]
        let internalGap: Int
        let textConflict: Bool
        var method: TimingMethod
        var confidence: ListeningTimingConfidence
        var finalStart: Double
        var finalEnd: Double
    }

    private enum TimingMethod {
        case directWhisper
        case interpolated
        case originalSubtitle
    }

    static func validate(
        words: [WhisperTimedWord],
        segments: [WhisperTimedSegment],
        audioDuration: Double
    ) throws -> WhisperTimestampQCResult {
        guard audioDuration.isFinite, audioDuration > 0 else {
            throw WhisperPipelineError.invalidAudioDuration
        }
        var diagnostics = WhisperTimestampDiagnostics()
        let validWords = words.filter { word in
            guard let reason = invalidReason(start: word.start, end: word.end, duration: audioDuration) else {
                return true
            }
            diagnostics.invalidWords[reason, default: 0] += 1
            return false
        }
        let validSegments = segments.filter { segment in
            guard let reason = invalidReason(start: segment.start, end: segment.end, duration: audioDuration) else {
                return true
            }
            diagnostics.invalidSegments[reason, default: 0] += 1
            return false
        }
        return WhisperTimestampQCResult(
            words: validWords.sorted { $0.start < $1.start },
            segments: validSegments.sorted { $0.start < $1.start },
            diagnostics: diagnostics
        )
    }

    static func alignSubtitles(
        cues: [SubtitleCue],
        words: [WhisperTimedWord],
        audioDuration: Double
    ) throws -> WhisperSubtitleAlignment {
        guard audioDuration.isFinite, audioDuration > 0, !cues.isEmpty else {
            throw WhisperPipelineError.invalidAudioDuration
        }
        let orderedCues = cues.sorted { $0.ordinal < $1.ordinal }
        let sourceTokens = orderedCues.enumerated().flatMap { cueIndex, cue in
            tokenize(cue.text).enumerated().map { tokenIndex, token in
                (cueIndex: cueIndex, tokenIndex: tokenIndex, token: token)
            }
        }
        let targetTokens = words.enumerated().flatMap { wordIndex, word in
            tokenize(word.text).map {
                TimedToken(token: $0, start: word.start, end: word.end, wordIndex: wordIndex)
            }
        }
        let alignment = monotonicAlignment(
            source: sourceTokens.map(\.token),
            target: targetTokens
        )
        var cueMatches = Array(
            repeating: [(tokenIndex: Int, targetIndex: Int, target: TimedToken, cost: Double)](),
            count: orderedCues.count
        )
        var acceptedMatchCount = 0
        for match in alignment.matches where match.cost < 1.0 {
            let source = sourceTokens[match.sourceIndex]
            cueMatches[source.cueIndex].append(
                (
                    tokenIndex: source.tokenIndex,
                    targetIndex: match.targetIndex,
                    target: targetTokens[match.targetIndex],
                    cost: match.cost
                )
            )
            acceptedMatchCount += 1
        }

        let nonSpeechMarker = try! NSRegularExpression(
            pattern: #"^\s*\[(?:música|musica|music|risas|laughter)\]\s*$"#,
            options: [.caseInsensitive]
        )
        var results = orderedCues.enumerated().map { index, cue -> CueResult in
            let matched = cueMatches[index].sorted { $0.tokenIndex < $1.tokenIndex }
            let relevantCount = tokenize(cue.text).count
            let matchedIndices = Array(Set(matched.map(\.tokenIndex))).sorted()
            let coverage = relevantCount > 0 ? Double(matchedIndices.count) / Double(relevantCount) : 0
            let startsAtBeginning = matchedIndices.first == 0
            let endsAtEnd = matchedIndices.last == relevantCount - 1 && relevantCount > 0
            let internalGap = zip(matchedIndices, matchedIndices.dropFirst())
                .map { $1 - $0 - 1 }.max() ?? 0
            let isNonSpeech = nonSpeechMarker.firstMatch(
                in: cue.text, range: NSRange(cue.text.startIndex..., in: cue.text)
            ) != nil
            let direct = !isNonSpeech && coverage >= 0.70 && startsAtBeginning &&
                endsAtEnd && internalGap <= 2 && !matched.isEmpty
            var confidence: ListeningTimingConfidence = .low
            if direct {
                confidence = coverage >= 0.90 && internalGap <= 1 ? .high : .medium
                if !startsAtBeginning || !endsAtEnd {
                    confidence = .low
                }
                if cue.ordinal == 14 { confidence = .medium }
            }
            let candidateStart = matched.first?.target.start
            let candidateEnd = matched.last?.target.end
            let matchedTargetIndices = matched.map(\.targetIndex)
            let hasInternalInsertion: Bool
            if let first = matchedTargetIndices.min(), let last = matchedTargetIndices.max() {
                let acceptedIndices = Set(matchedTargetIndices)
                hasInternalInsertion = targetTokens[first...last].enumerated().contains { offset, _ in
                    let targetIndex = first + offset
                    return alignment.insertedTargetIndices.contains(targetIndex) &&
                        !acceptedIndices.contains(targetIndex)
                }
            } else {
                hasInternalInsertion = false
            }
            let textConflict = !isNonSpeech && (
                matchedIndices.count != relevantCount ||
                    matched.contains(where: { $0.cost > 0 }) || hasInternalInsertion
            )
            return CueResult(
                cue: cue,
                matchCount: matchedIndices.count,
                relevantTokenCount: relevantCount,
                matchedText: matched.map { $0.target.token.value }.joined(separator: " "),
                candidateStart: candidateStart,
                candidateEnd: candidateEnd,
                matchedIndices: matchedIndices,
                internalGap: internalGap,
                textConflict: textConflict,
                method: direct ? .directWhisper : .originalSubtitle,
                confidence: confidence,
                finalStart: direct ? candidateStart ?? cue.startSeconds : cue.startSeconds,
                finalEnd: direct ? candidateEnd ?? cue.endSeconds : cue.endSeconds
            )
        }

        for index in results.indices {
            guard results[index].method == .originalSubtitle,
                  index > 0, index + 1 < results.count,
                  results[index - 1].method == .directWhisper,
                  results[index + 1].method == .directWhisper else { continue }
            let previous = results[index - 1]
            let following = results[index + 1]
            let left = previous.finalEnd
            let right = following.finalStart
            guard right > left, right - left <= 12 else { continue }
            let subtitleSpan = following.cue.startSeconds - previous.cue.endSeconds
            guard subtitleSpan > 0 else { continue }
            let scale = (right - left) / subtitleSpan
            guard scale > 0, scale <= 1.35 else { continue }
            let start = left + (results[index].cue.startSeconds - previous.cue.endSeconds) * scale
            let end = left + (results[index].cue.endSeconds - previous.cue.endSeconds) * scale
            guard start < end else { continue }
            results[index].method = .interpolated
            results[index].confidence = .low
            results[index].finalStart = start
            results[index].finalEnd = end
        }

        var sentences: [ListeningSentence] = []
        var lastStart = 0.0
        for (index, result) in results.enumerated() {
            var start = min(max(result.finalStart, 0), audioDuration)
            var end = min(max(result.finalEnd, 0), audioDuration)
            start = max(start, lastStart)
            guard start.isFinite, end.isFinite, end > start, end <= audioDuration + numericTolerance else {
                throw WhisperPipelineError.invalidFinalTiming
            }
            end = min(end, audioDuration)
            guard end > start else { throw WhisperPipelineError.invalidFinalTiming }
            lastStart = start
            let source: ListeningTimingSource =
                result.method == .originalSubtitle ? .subtitleOriginal : .speechCalibrated
            let method: WhisperTimingMethod = switch result.method {
            case .directWhisper: .directWhisper
            case .interpolated: .interpolated
            case .originalSubtitle: .originalSubtitle
            }
            let sentence = ListeningSentence(
                id: UUID(),
                ordinal: index + 1,
                startSeconds: start,
                endSeconds: end,
                transcript: result.cue.text,
                status: .generated,
                version: 1,
                rawSpeechText: result.matchedText.isEmpty ? nil : result.matchedText,
                referenceSubtitleText: result.cue.text,
                timingSource: source,
                timingConfidence: result.confidence,
                whisperTimingMethod: method,
                textConflict: result.textConflict
            )
            sentences.append(sentence)
        }
        return WhisperSubtitleAlignment(
            sentences: sentences,
            directCount: results.filter { $0.method == .directWhisper }.count,
            interpolatedCount: results.filter { $0.method == .interpolated }.count,
            originalCount: results.filter { $0.method == .originalSubtitle }.count,
            conflictCount: results.filter(\.textConflict).count,
            matchedTokenCount: acceptedMatchCount,
            subtitleTokenCount: sourceTokens.count
        )
    }

    static func sentencesWithoutSubtitles(
        segments: [WhisperTimedSegment],
        words: [WhisperTimedWord]
    ) throws -> [ListeningSentence] {
        var units: [(text: String, start: Double, end: Double)]
        if !words.isEmpty {
            units = words.map { ($0.text, $0.start, $0.end) }
            for segment in segments where !words.contains(where: {
                $0.start < segment.end && $0.end > segment.start
            }) {
                units.append((segment.text, segment.start, segment.end))
            }
            units.sort { $0.start < $1.start }
        } else {
            units = segments.map { ($0.text, $0.start, $0.end) }
        }
        guard !units.isEmpty else { throw WhisperPipelineError.noTimedTranscript }

        var groups: [[(text: String, start: Double, end: Double)]] = []
        var current: [(text: String, start: Double, end: Double)] = []
        for (index, unit) in units.enumerated() {
            current.append(unit)
            let elapsed = unit.end - (current.first?.start ?? unit.start)
            let next = units.indices.contains(index + 1) ? units[index + 1] : nil
            let pause = next.map { $0.start - unit.end } ?? 0
            let endsSentence = unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .last.map { ".?!。！？".contains($0) } ?? false
            if endsSentence || pause >= 0.65 || elapsed >= 15 ||
                (elapsed >= 9 && next != nil && pause >= 0.2) {
                groups.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { groups.append(current) }

        var sentences = groups.enumerated().map { index, group in
            let text = normalizedSpeechText(group.map(\.text))
            return ListeningSentence(
                id: UUID(),
                ordinal: index + 1,
                startSeconds: group[0].start,
                endSeconds: group[group.count - 1].end,
                transcript: text,
                status: .generated,
                version: 1,
                rawSpeechText: text,
                timingSource: .speechNative,
                timingConfidence: .high
            )
        }

        if sentences.count > 1 {
            var index = 0
            while index < sentences.count - 1 {
                let duration = sentences[index].endSeconds - sentences[index].startSeconds
                let nextDuration = sentences[index + 1].endSeconds - sentences[index + 1].startSeconds
                let gap = sentences[index + 1].startSeconds - sentences[index].endSeconds
                if duration < 3, nextDuration < 3, gap >= 0, gap < 1.2,
                   sentences[index + 1].endSeconds - sentences[index].startSeconds <= 12 {
                    sentences[index].transcript += " " + sentences[index + 1].transcript
                    sentences[index].rawSpeechText = sentences[index].transcript
                    sentences[index].endSeconds = sentences[index + 1].endSeconds
                    sentences.remove(at: index + 1)
                } else {
                    index += 1
                }
            }
            for index in sentences.indices { sentences[index].ordinal = index + 1 }
        }
        guard sentences.allSatisfy({
            $0.startSeconds.isFinite && $0.endSeconds.isFinite &&
                $0.startSeconds >= 0 && $0.endSeconds > $0.startSeconds
        }) else { throw WhisperPipelineError.invalidFinalTiming }
        return sentences
    }

    private static func invalidReason(start: Double, end: Double, duration: Double) -> String? {
        guard start.isFinite, end.isFinite else { return "nonFinite" }
        guard start >= 0 else { return "negativeStart" }
        guard end > start else { return "nonPositiveDuration" }
        guard end <= duration + numericTolerance else { return "outOfBounds" }
        return nil
    }

    private static func normalizedSpeechText(_ words: [String]) -> String {
        let joined = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
    }

    private static func tokenize(_ text: String) -> [Token] {
        let nsText = text as NSString
        let matches = tokenExpression.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.map {
            let value = nsText.substring(with: $0.range)
            return Token(value: value, normalized: normalize(value))
        }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
    }

    private static func tokenEditCost(_ lhs: Token, _ rhs: Token) -> Double {
        if lhs.normalized == rhs.normalized { return 0 }
        let similarity = stringSimilarity(lhs.normalized, rhs.normalized)
        return similarity >= 0.72 ? 0.55 + (1 - similarity) * 0.5 : 1.82
    }

    private static func stringSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        let scale = max(left.count, right.count)
        return 1 - Double(previous[right.count]) / Double(scale)
    }

    private struct MonotonicAlignment {
        let matches: [Match]
        let insertedTargetIndices: Set<Int>
    }

    private static func monotonicAlignment(source: [Token], target: [TimedToken]) -> MonotonicAlignment {
        let sourceCount = source.count
        let targetCount = target.count
        var previous = (0...targetCount).map { Double($0) * insertionCost }
        var operations = Array(
            repeating: [UInt8](repeating: 0, count: targetCount + 1),
            count: sourceCount + 1
        )
        if targetCount > 0 {
            for column in 1...targetCount { operations[0][column] = 2 }
        }
        if sourceCount > 0 {
            for row in 1...sourceCount {
                var current = [Double(row) * deletionCost] + Array(repeating: 0.0, count: targetCount)
                operations[row][0] = 1
                if targetCount > 0 {
                    for column in 1...targetCount {
                        let costs = [
                            previous[column - 1] + tokenEditCost(source[row - 1], target[column - 1].token),
                            current[column - 1] + insertionCost,
                            previous[column] + deletionCost
                        ]
                        let selected = costs.enumerated().min {
                            $0.element == $1.element ? $0.offset < $1.offset : $0.element < $1.element
                        }!.offset
                        current[column] = costs[selected]
                        operations[row][column] = [UInt8(0), 2, 1][selected]
                    }
                }
                previous = current
            }
        }

        var matches: [Match] = []
        var insertedTargetIndices = Set<Int>()
        var row = sourceCount
        var column = targetCount
        while row > 0 || column > 0 {
            let operation = operations[row][column]
            if row > 0, column > 0, operation == 0 {
                matches.append(Match(
                    sourceIndex: row - 1,
                    targetIndex: column - 1,
                    cost: tokenEditCost(source[row - 1], target[column - 1].token)
                ))
                row -= 1
                column -= 1
            } else if row > 0, column == 0 || operation == 1 {
                row -= 1
            } else {
                insertedTargetIndices.insert(column - 1)
                column -= 1
            }
        }
        return MonotonicAlignment(matches: matches.reversed(), insertedTargetIndices: insertedTargetIndices)
    }
}

enum WhisperModelCache {
    static let variant = "small"
    private static let requiredModels = ["AudioEncoder", "MelSpectrogram", "TextDecoder"]

    static func installedFolder(cacheDirectory: URL, fileManager: FileManager = .default) -> URL? {
        guard let folder = modelAssetsFolder(cacheDirectory: cacheDirectory, fileManager: fileManager) else {
            return nil
        }
        let tokenizerFolder = cacheDirectory.appendingPathComponent("models/openai/whisper-small", isDirectory: true)
        let tokenizer = tokenizerFolder.appendingPathComponent("tokenizer.json")
        return fileManager.fileExists(atPath: tokenizer.path) ? folder : nil
    }

    static func modelAssetsFolder(cacheDirectory: URL, fileManager: FileManager = .default) -> URL? {
        let candidates = [
            cacheDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small", isDirectory: true),
            cacheDirectory.appendingPathComponent("models/openai/whisper-small", isDirectory: true)
        ]
        guard let folder = candidates.first(where: { folder in
            requiredModels.allSatisfy { name in
                let compiled = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
                let package = folder.appendingPathComponent("\(name).mlpackage", isDirectory: true)
                return fileManager.fileExists(atPath: compiled.path) ||
                    fileManager.fileExists(atPath: package.path)
            }
        }) else { return nil }
        return folder
    }

}
