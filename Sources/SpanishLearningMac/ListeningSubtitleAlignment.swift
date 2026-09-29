import Foundation

enum SubtitleAlignmentConfidence: String, Sendable {
    case high, medium, low, unmatched
}

enum SubtitleAlignmentShape: String, Sendable {
    case oneToOne, oneToMany, manyToOne
}

struct ListeningSubtitleMatch: Sendable {
    let sentenceRange: Range<Int>
    let cueRange: Range<Int>
    let subtitleText: String
    let similarity: Double
    let confidence: SubtitleAlignmentConfidence
    let shape: SubtitleAlignmentShape
}

struct SpeechSubtitleAlignment: Sendable {
    let matches: [ListeningSubtitleMatch]
    let unmatchedSentenceIndices: [Int]
    let unmatchedCueIndices: [Int]

    func match(forSentenceAt index: Int) -> ListeningSubtitleMatch? {
        matches.first { $0.sentenceRange.contains(index) }
    }
}

enum ListeningSubtitleAligner {
    private struct Step {
        let previousSentence: Int
        let previousCue: Int
        let sentenceCount: Int
        let cueCount: Int
    }

    enum SubtitleTimingAnchorKind: String, Sendable {
        case cueBoundary
        case internalPhrase
    }

    struct SubtitleTimingAnchor: Sendable {
        let cueRange: Range<Int>
        let subtitleTime: Double
        let speechTime: Double
        let similarity: Double
        let kind: SubtitleTimingAnchorKind
        let confidence: ListeningTimingConfidence
    }

    struct SubtitleCalibrationRegion: Sendable {
        let subtitleStart: Double
        let subtitleEnd: Double
        let audioStart: Double
        let audioEnd: Double
        let confidence: ListeningTimingConfidence
    }

    struct SubtitleTimingCalibration: Sendable {
        let sentences: [ListeningSentence]
        let anchors: [SubtitleTimingAnchor]
        let regions: [SubtitleCalibrationRegion]
    }

    enum SubtitleTimingCalibrator {
        private struct Match {
            let speechRange: Range<Int>
            let cueRange: Range<Int>
            let speechText: String
            let cueText: String
            let similarity: Double
            let boundaryMatch: Bool
        }

        private struct MappingPoint {
            let subtitle: Double
            let audio: Double
            let confidence: ListeningTimingConfidence
        }

        private struct MappingSegment {
            let start: MappingPoint
            let end: MappingPoint
            let confidence: ListeningTimingConfidence
        }

        private static let maximumPhraseDuration = 12.0
        private static let maximumSpeechGap = 2.0
        private static let maximumCueGroupSize = 3
        private static let maximumRegionAnchorDistance = 60.0

        static func calibrate(cues: [SubtitleCue], speech: [SpeechTimingAnchor],
                              audioDuration: Double) -> SubtitleTimingCalibration {
            let matches = uniqueMonotonicMatches(cues: cues, speech: speech)
            let anchors = matches.flatMap { makeAnchors($0, cues: cues, speech: speech) }
                .sorted {
                    if $0.subtitleTime != $1.subtitleTime { return $0.subtitleTime < $1.subtitleTime }
                    return $0.speechTime < $1.speechTime
                }
            let points = coalescedPoints(anchors)
            let segments = mappingSegments(points)
            let regions = makeRegions(segments)
            var previousStart = -Double.infinity
            var previousEnd = -Double.infinity
            let sentences = cues.enumerated().map { index, cue -> ListeningSentence in
                var start = cue.startSeconds
                var end = cue.endSeconds
                var source: ListeningTimingSource = .subtitleOriginal
                var confidence: ListeningTimingConfidence = .low
                if let region = regions.first(where: {
                    cue.startSeconds >= $0.subtitleStart && cue.endSeconds <= $0.subtitleEnd
                }),
                   let mappedStart = map(cue.startSeconds, through: segments),
                   let mappedEnd = map(cue.endSeconds, through: segments),
                   mappedStart.isFinite, mappedEnd.isFinite,
                   mappedStart >= 0, mappedEnd > mappedStart, mappedEnd <= audioDuration,
                   mappedStart >= previousStart, mappedEnd >= previousEnd {
                    start = mappedStart
                    end = mappedEnd
                    source = .speechCalibrated
                    confidence = region.confidence
                }
                previousStart = start
                previousEnd = end
                return ListeningSentence(
                    id: UUID(), ordinal: index + 1, startSeconds: start, endSeconds: end,
                    transcript: cue.text, status: .generated, version: 1,
                    timingSource: source, timingConfidence: confidence
                )
            }
            return SubtitleTimingCalibration(sentences: sentences, anchors: anchors, regions: regions)
        }

        private static func uniqueMonotonicMatches(cues: [SubtitleCue],
                                                    speech: [SpeechTimingAnchor]) -> [Match] {
            guard !cues.isEmpty, !speech.isEmpty else { return [] }
            var candidates: [Match] = []
            for phraseLength in 1...min(8, speech.count) {
                for phraseStart in 0...(speech.count - phraseLength) {
                    let phraseRange = phraseStart..<(phraseStart + phraseLength)
                    let phraseSegments = Array(speech[phraseRange])
                    guard phraseSegments.allSatisfy({
                        $0.startSeconds.isFinite && $0.endSeconds.isFinite &&
                            $0.startSeconds >= 0 && $0.endSeconds > $0.startSeconds &&
                            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }),
                          let first = phraseSegments.first, let last = phraseSegments.last,
                          last.endSeconds - first.startSeconds <= maximumPhraseDuration,
                          zip(phraseSegments, phraseSegments.dropFirst()).allSatisfy({
                              $0.1.startSeconds - $0.0.endSeconds <= maximumSpeechGap
                          }) else { continue }
                    let phraseText = phraseSegments.map(\.text).joined(separator: " ")
                    let phraseTokens = tokens(phraseText)
                    guard phraseTokens.count >= 2 && phraseTokens.count <= 8 else { continue }

                    for cueStart in cues.indices {
                        for cueCount in 1...min(maximumCueGroupSize, cues.count - cueStart) {
                            let cueRange = cueStart..<(cueStart + cueCount)
                            let cueText = cues[cueRange].map(\.text).joined(separator: " ")
                            let cueTokens = tokens(cueText)
                            guard cueTokens.count >= phraseTokens.count else { continue }
                            var bestSimilarity = 0.0
                            var bestWindow: [String] = []
                            let minWindow = max(2, phraseTokens.count - 1)
                            let maxWindow = min(cueTokens.count, phraseTokens.count + 1)
                            guard minWindow <= maxWindow else { continue }
                            for windowLength in minWindow...maxWindow {
                                for windowStart in 0...(cueTokens.count - windowLength) {
                                    let window = Array(cueTokens[windowStart..<(windowStart + windowLength)])
                                    let score = tokenSimilarity(phraseTokens, window)
                                    if score > bestSimilarity {
                                        bestSimilarity = score
                                        bestWindow = window
                                    }
                                }
                            }
                            guard bestSimilarity >= 0.92,
                                  isUnique(bestWindow, atCue: cueStart, cues: cues) else { continue }
                            let boundaryMatch = bestWindow == cueTokens
                            candidates.append(Match(
                                speechRange: phraseRange, cueRange: cueRange, speechText: phraseText,
                                cueText: cueText, similarity: bestSimilarity, boundaryMatch: boundaryMatch
                            ))
                        }
                    }
                }
            }

            candidates.sort {
                if $0.speechRange.lowerBound != $1.speechRange.lowerBound {
                    return $0.speechRange.lowerBound < $1.speechRange.lowerBound
                }
                if $0.boundaryMatch != $1.boundaryMatch { return $0.boundaryMatch }
                if $0.speechRange.count != $1.speechRange.count {
                    return $0.speechRange.count > $1.speechRange.count
                }
                if $0.cueRange.lowerBound != $1.cueRange.lowerBound {
                    return $0.cueRange.lowerBound < $1.cueRange.lowerBound
                }
                if $0.cueRange.count != $1.cueRange.count {
                    return $0.cueRange.count < $1.cueRange.count
                }
                return $0.similarity > $1.similarity
            }
            var selected: [Match] = []
            for candidate in candidates {
                if selected.contains(where: {
                    $0.speechRange.overlaps(candidate.speechRange) ||
                        $0.cueRange.overlaps(candidate.cueRange)
                }) { continue }
                guard let prior = selected.last else {
                    selected.append(candidate)
                    continue
                }
                let previousSpeechEnd = speech[prior.speechRange.upperBound - 1].endSeconds
                let currentSpeechStart = speech[candidate.speechRange.lowerBound].startSeconds
                guard candidate.cueRange.lowerBound >= prior.cueRange.upperBound,
                      currentSpeechStart >= previousSpeechEnd else { continue }
                selected.append(candidate)
            }
            return selected
        }

        private static func isUnique(_ phrase: [String], atCue cueIndex: Int,
                                     cues: [SubtitleCue]) -> Bool {
            var locations = Set<Int>()
            for (index, cue) in cues.enumerated() {
                let cueTokens = tokens(cue.text)
                guard cueTokens.count >= max(2, phrase.count - 1) else { continue }
                let minWindow = max(2, phrase.count - 1)
                let maxWindow = min(cueTokens.count, phrase.count + 1)
                guard minWindow <= maxWindow else { continue }
                for length in minWindow...maxWindow {
                    for start in 0...(cueTokens.count - length) {
                        let window = Array(cueTokens[start..<(start + length)])
                        if tokenSimilarity(phrase, window) >= 0.92 {
                            locations.insert(index)
                            break
                        }
                    }
                }
            }
            return locations == [cueIndex]
        }

        private static func makeAnchors(_ match: Match, cues: [SubtitleCue],
                                        speech: [SpeechTimingAnchor]) -> [SubtitleTimingAnchor] {
            let firstCue = cues[match.cueRange.lowerBound]
            let lastCue = cues[match.cueRange.upperBound - 1]
            let firstSpeech = speech[match.speechRange.lowerBound]
            let lastSpeech = speech[match.speechRange.upperBound - 1]
            if match.boundaryMatch {
                return [
                    SubtitleTimingAnchor(cueRange: match.cueRange,
                                         subtitleTime: firstCue.startSeconds,
                                         speechTime: firstSpeech.startSeconds,
                                         similarity: match.similarity, kind: .cueBoundary, confidence: .high),
                    SubtitleTimingAnchor(cueRange: match.cueRange,
                                         subtitleTime: lastCue.endSeconds,
                                         speechTime: lastSpeech.endSeconds,
                                         similarity: match.similarity, kind: .cueBoundary, confidence: .high)
                ]
            }
            let subtitleMidpoint = (firstCue.startSeconds + lastCue.endSeconds) / 2
            let speechMidpoint = (firstSpeech.startSeconds + lastSpeech.endSeconds) / 2
            return [SubtitleTimingAnchor(cueRange: match.cueRange,
                                         subtitleTime: subtitleMidpoint,
                                         speechTime: speechMidpoint,
                                         similarity: match.similarity, kind: .internalPhrase, confidence: .medium)]
        }

        private static func coalescedPoints(_ anchors: [SubtitleTimingAnchor]) -> [MappingPoint] {
            let sorted = anchors.sorted {
                if $0.subtitleTime != $1.subtitleTime { return $0.subtitleTime < $1.subtitleTime }
                return $0.speechTime < $1.speechTime
            }
            var groups: [[SubtitleTimingAnchor]] = []
            for anchor in sorted {
                if let last = groups.last, abs(last[0].subtitleTime - anchor.subtitleTime) < 0.001 {
                    groups[groups.count - 1].append(anchor)
                } else {
                    groups.append([anchor])
                }
            }
            return groups.map { group in
                MappingPoint(
                    subtitle: group.map(\.subtitleTime).reduce(0, +) / Double(group.count),
                    audio: group.map(\.speechTime).reduce(0, +) / Double(group.count),
                    confidence: group.allSatisfy { $0.confidence == .high } ? .high : .medium
                )
            }
        }

        private static func mappingSegments(_ points: [MappingPoint]) -> [MappingSegment] {
            guard points.count > 1 else { return [] }
            var result: [MappingSegment] = []
            for (left, right) in zip(points, points.dropFirst()) {
                let subtitleDelta = right.subtitle - left.subtitle
                let audioDelta = right.audio - left.audio
                let slope = audioDelta / subtitleDelta
                guard subtitleDelta > 0, subtitleDelta <= maximumRegionAnchorDistance,
                      audioDelta > 0, slope.isFinite, (0.5...1.5).contains(slope) else { continue }
                result.append(MappingSegment(
                    start: left, end: right,
                    confidence: left.confidence == .high && right.confidence == .high ? .high : .medium
                ))
            }
            return result
        }

        private static func makeRegions(_ segments: [MappingSegment]) -> [SubtitleCalibrationRegion] {
            var regions: [SubtitleCalibrationRegion] = []
            for segment in segments {
                if let last = regions.last,
                   abs(last.subtitleEnd - segment.start.subtitle) < 0.001,
                   abs(last.audioEnd - segment.start.audio) < 0.25 {
                    regions[regions.count - 1] = SubtitleCalibrationRegion(
                        subtitleStart: last.subtitleStart, subtitleEnd: segment.end.subtitle,
                        audioStart: last.audioStart, audioEnd: segment.end.audio,
                        confidence: last.confidence == .high && segment.confidence == .high ? .high : .medium
                    )
                } else {
                    regions.append(SubtitleCalibrationRegion(
                        subtitleStart: segment.start.subtitle, subtitleEnd: segment.end.subtitle,
                        audioStart: segment.start.audio, audioEnd: segment.end.audio,
                        confidence: segment.confidence
                    ))
                }
            }
            return regions
        }

        private static func map(_ time: Double, through segments: [MappingSegment]) -> Double? {
            guard let segment = segments.first(where: {
                time >= $0.start.subtitle && time <= $0.end.subtitle
            }) else { return nil }
            let fraction = (time - segment.start.subtitle) / (segment.end.subtitle - segment.start.subtitle)
            return segment.start.audio + fraction * (segment.end.audio - segment.start.audio)
        }

        private static func tokens(_ text: String) -> [String] {
            let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                          locale: Locale(identifier: "es_ES"))
            var result: [String] = []
            var token = ""
            for character in normalized {
                if character.isLetter || character.isNumber {
                    token.append(character)
                } else if !token.isEmpty {
                    result.append(token)
                    token = ""
                }
            }
            if !token.isEmpty { result.append(token) }
            return result
        }

        private static func tokenSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
            guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
            var previous = Array(0...rhs.count)
            for (leftIndex, left) in lhs.enumerated() {
                var current = Array(repeating: 0, count: rhs.count + 1)
                current[0] = leftIndex + 1
                for (rightIndex, right) in rhs.enumerated() {
                    current[rightIndex + 1] = min(
                        previous[rightIndex] + (left == right ? 0 : 1),
                        previous[rightIndex + 1] + 1,
                        current[rightIndex] + 1
                    )
                }
                previous = current
            }
            return max(0, 1 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count)))
        }
    }

    private struct Cell {
        var score = -Double.infinity
        var step: Step?
    }

    static func align(sentences: [ListeningSentence], cues: [SubtitleCue]) -> SpeechSubtitleAlignment {
        let sentenceCount = sentences.count
        let cueCount = cues.count
        var table = Array(
            repeating: Array(repeating: Cell(), count: cueCount + 1),
            count: sentenceCount + 1
        )
        table[0][0].score = 0

        for sentenceIndex in 0...sentenceCount {
            for cueIndex in 0...cueCount {
                let current = table[sentenceIndex][cueIndex].score
                guard current.isFinite else { continue }
                if sentenceIndex < sentenceCount {
                    update(&table, sentenceIndex + 1, cueIndex, score: current - 0.15,
                           step: Step(previousSentence: sentenceIndex, previousCue: cueIndex,
                                      sentenceCount: 1, cueCount: 0))
                }
                if cueIndex < cueCount {
                    update(&table, sentenceIndex, cueIndex + 1, score: current - 0.15,
                           step: Step(previousSentence: sentenceIndex, previousCue: cueIndex,
                                      sentenceCount: 0, cueCount: 1))
                }

                guard sentenceIndex < sentenceCount, cueIndex < cueCount else { continue }
                for consumedSentences in 1...min(3, sentenceCount - sentenceIndex) {
                    for consumedCues in 1...min(3, cueCount - cueIndex) {
                        let speechText = sentences[sentenceIndex..<(sentenceIndex + consumedSentences)]
                            .map(\.transcript).joined(separator: " ")
                        let referenceText = cues[cueIndex..<(cueIndex + consumedCues)]
                            .map(\.text).joined(separator: " ")
                        let similarity = textSimilarity(speechText, referenceText)
                        let groupingPenalty = Double(consumedSentences + consumedCues - 2) * 0.025
                        update(&table, sentenceIndex + consumedSentences, cueIndex + consumedCues,
                               score: current + similarity - 0.60 - groupingPenalty,
                               step: Step(previousSentence: sentenceIndex, previousCue: cueIndex,
                                          sentenceCount: consumedSentences, cueCount: consumedCues))
                    }
                }
            }
        }

        var matches: [ListeningSubtitleMatch] = []
        var unmatchedSentences: [Int] = []
        var unmatchedCues: [Int] = []
        var sentenceIndex = sentenceCount
        var cueIndex = cueCount
        while sentenceIndex > 0 || cueIndex > 0 {
            guard let step = table[sentenceIndex][cueIndex].step else { break }
            if step.sentenceCount == 0 {
                unmatchedCues.append(step.previousCue)
            } else if step.cueCount == 0 {
                unmatchedSentences.append(step.previousSentence)
            } else {
                let sentenceRange = step.previousSentence..<(step.previousSentence + step.sentenceCount)
                let cueRange = step.previousCue..<(step.previousCue + step.cueCount)
                let speechText = sentences[sentenceRange].map(\.transcript).joined(separator: " ")
                let referenceText = cues[cueRange].map(\.text).joined(separator: " ")
                let similarity = textSimilarity(speechText, referenceText)
                matches.append(ListeningSubtitleMatch(
                    sentenceRange: sentenceRange,
                    cueRange: cueRange,
                    subtitleText: referenceText,
                    similarity: similarity,
                    confidence: confidence(for: similarity),
                    shape: shape(sentenceCount: step.sentenceCount, cueCount: step.cueCount)
                ))
            }
            sentenceIndex = step.previousSentence
            cueIndex = step.previousCue
        }
        matches.reverse()
        return SpeechSubtitleAlignment(
            matches: matches,
            unmatchedSentenceIndices: unmatchedSentences.reversed(),
            unmatchedCueIndices: unmatchedCues.reversed()
        )
    }

    static func textSimilarity(_ speech: String, _ reference: String) -> Double {
        let speechTokens = tokens(speech, foldAccents: false)
        let referenceTokens = tokens(reference, foldAccents: false)
        guard !speechTokens.isEmpty, !referenceTokens.isEmpty else { return 0 }
        let strict = tokenSimilarity(speechTokens, referenceTokens)
        let accentFolded = tokenSimilarity(tokens(speech, foldAccents: true),
                                           tokens(reference, foldAccents: true))
        return max(strict, accentFolded)
    }

    static func confidence(for similarity: Double) -> SubtitleAlignmentConfidence {
        if similarity >= 0.92 { return .high }
        if similarity >= 0.70 { return .medium }
        return .low
    }

    static func isReferenceReliable(_ alignment: SpeechSubtitleAlignment,
                                    sentenceCount: Int, cueCount: Int) -> Bool {
        guard sentenceCount > 0, cueCount > 0 else { return false }
        let matchedSentenceCount = alignment.matches.reduce(0) { $0 + $1.sentenceRange.count }
        let matchedCueCount = alignment.matches.reduce(0) { $0 + $1.cueRange.count }
        let highOrMediumCount = alignment.matches.filter {
            $0.confidence == .high || $0.confidence == .medium
        }.count
        let lowCount = alignment.matches.filter { $0.confidence == .low }.count
        return matchedSentenceCount * 2 > sentenceCount &&
            matchedCueCount * 2 > cueCount &&
            highOrMediumCount > lowCount
    }

    static func textOnlyCorrection(_ text: String, for sentence: ListeningSentence) -> ListeningSentence {
        var corrected = sentence
        corrected.transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return corrected
    }

    static func locallyReviewed(_ sentence: ListeningSentence, match: ListeningSubtitleMatch?,
                                referenceReliable: Bool) -> ListeningSentence {
        guard referenceReliable, let match, match.confidence == .high,
              match.sentenceRange.count == 1 else { return sentence }
        return textOnlyCorrection(match.subtitleText, for: sentence)
    }

    static func applyingAIReview(_ sentence: ListeningSentence,
                                 review: SpeechTranscriptReview?) -> ListeningSentence {
        guard let review, review.confidence >= 0.85 else { return sentence }
        switch review.decision {
        case .keepSpeech:
            return sentence
        case .useReference, .corrected:
            let text = review.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? sentence : textOnlyCorrection(text, for: sentence)
        }
    }

    private static func update(_ table: inout [[Cell]], _ sentenceIndex: Int, _ cueIndex: Int,
                               score: Double, step: Step) {
        guard score > table[sentenceIndex][cueIndex].score else { return }
        table[sentenceIndex][cueIndex] = Cell(score: score, step: step)
    }

    private static func shape(sentenceCount: Int, cueCount: Int) -> SubtitleAlignmentShape {
        if sentenceCount > 1 && cueCount == 1 { return .manyToOne }
        if sentenceCount == 1 && cueCount > 1 { return .oneToMany }
        return .oneToOne
    }

    private static func tokens(_ text: String, foldAccents: Bool) -> [String] {
        let normalized = foldAccents
            ? text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            : text.lowercased()
        var result: [String] = []
        var token = ""
        for character in normalized {
            if character.isLetter || character.isNumber {
                token.append(character)
            } else if !token.isEmpty {
                result.append(token)
                token = ""
            }
        }
        if !token.isEmpty { result.append(token) }
        return result
    }

    private static func tokenSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, right) in rhs.enumerated() {
                let substitution = previous[rightIndex] + (left == right ? 0 : 1)
                current[rightIndex + 1] = min(
                    substitution,
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1
                )
            }
            previous = current
        }
        return max(0, 1 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count)))
    }
}
