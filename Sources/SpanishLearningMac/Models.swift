import Foundation

struct StudyDatabase: Codable {
    var schemaVersion = 1
    var audioMaterials: [AudioMaterial] = []
    var articles: [ReadingArticle] = []
    var readingRecords: [ReadingRecord] = []
    var dictationAttempts: [DictationAttempt] = []
    var writingExercises: [WritingExercise] = []
    var cards: [StudyCard] = []
    var reviewEvents: [ReviewEvent] = []
}

enum ListeningSegmentationSource: String, Codable {
    case subtitle
    case speech
    case subtitleCalibrated
}

enum ListeningTimingSource: String, Codable {
    case subtitleOriginal
    case speechCalibrated
    case speechNative
}

enum WhisperTimingMethod: String, Codable {
    case directWhisper
    case interpolated
    case originalSubtitle
}

enum ListeningTimingConfidence: String, Codable {
    case low, medium, high
}

struct AudioMaterial: Codable, Identifiable {
    var id: UUID
    var title: String
    var fileName: String
    var importedAt: Date
    var sentences: [ListeningSentence] = []
    var transcribedThroughSeconds: Double? = nil
    var transcriptionComplete: Bool? = nil
    var segmentationSource: ListeningSegmentationSource? = nil
    var referenceSubtitleCues: [SubtitleCue]? = nil
    var subtitleReferenceReliable: Bool? = nil
    var speechTimingAnchors: [SpeechTimingAnchor]? = nil
}

struct SubtitleCue: Codable, Identifiable, Sendable {
    var id: UUID
    var ordinal: Int
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}

struct SpeechTimingAnchor: Codable, Sendable {
    var text: String
    var startSeconds: Double
    var endSeconds: Double
}

enum TranscriptStatus: String, Codable {
    case pending, generated, verified, corrected
}

struct ListeningAnalysis: Codable {
    var userAttemptSnapshot: String
    var explanation: String
    var items: [ListeningAnalysisItem]? = nil
    var generatedAt: Date
}

enum ListeningAnalysisCategory: String, Codable {
    case difficulty
    case connectedSpeech
    case reduction
    case accent
    case expression
    case vocabulary
    case attemptDifference
}

struct ListeningAnalysisItem: Codable, Identifiable {
    var id: UUID
    var category: ListeningAnalysisCategory
    var title: String
    var detail: String
    var evidence: String?
}

struct ListeningLearningPoint: Codable, Identifiable {
    var id: UUID
    var category: CardCategory
    var prompt: String
    var cardID: UUID
}

struct ListeningSentence: Codable, Identifiable {
    var id: UUID
    var ordinal: Int
    var startSeconds: Double
    var endSeconds: Double
    var transcript: String
    var status: TranscriptStatus
    var version: Int
    var draftText: String? = nil
    var answerRevealed: Bool? = nil
    var analysis: ListeningAnalysis? = nil
    var learningPoints: [ListeningLearningPoint]? = nil
    var rawSpeechText: String? = nil
    var referenceSubtitleText: String? = nil
    var timingSource: ListeningTimingSource? = nil
    var timingConfidence: ListeningTimingConfidence? = nil
    var whisperTimingMethod: WhisperTimingMethod? = nil
    var textConflict: Bool? = nil
}

struct ReadingArticle: Codable, Identifiable {
    var id: UUID
    var title: String
    var source: String
    var originalText: String
    var importedAt: Date
    var chunks: [ReadingChunk]
}

struct ReadingDiscussionItem: Codable, Identifiable {
    var id: UUID
    var askedAt: Date
    var question: String
    var answer: String
}

struct ReadingChunk: Codable, Identifiable {
    var id: UUID
    var ordinal: Int
    var text: String
    var discussion: [ReadingDiscussionItem]? = nil
}

enum ReadingDifficulty: String, Codable, CaseIterable, Identifiable {
    case understood = "基本读懂"
    case someGaps = "有些地方不懂"
    case difficult = "理解困难"
    case unclear = "几乎没读懂"
    var id: String { rawValue }
}

struct ReadingRecord: Codable, Identifiable {
    var id: UUID
    var articleID: UUID
    var chunkID: UUID
    var completedAt: Date
    var difficulty: ReadingDifficulty
    var questions: [String]
    var note: String
    var discussionIDs: [UUID]? = nil
    var cardIDs: [UUID]? = nil
}

struct DictationAttempt: Codable, Identifiable {
    var id: UUID
    var materialID: UUID
    var sentenceID: UUID
    var submittedAt: Date
    var text: String
    var answerWasShown: Bool
    var answerTextSnapshot: String? = nil
    var answerVersion: Int? = nil
}

enum WritingMode: String, Codable, CaseIterable, Identifiable {
    case material = "材料翻译"
    case free = "自由表达"
    var id: String { rawValue }
}

struct WritingError: Codable, Identifiable {
    var id: UUID
    var original: String
    var correction: String
    var explanation: String
}

struct WritingExercise: Codable, Identifiable {
    var id: UUID
    var sourceID: UUID?
    var chinesePrompt: String
    var versions: [WritingVersion]
    var sourceSegmentID: UUID? = nil
    var sourceQuote: String? = nil
    var referenceSpanish: String? = nil
    var focus: String? = nil
    var createdAt: Date? = nil
    var mode: WritingMode? = nil
}

struct WritingVersion: Codable, Identifiable {
    var id: UUID
    var submittedAt: Date
    var spanishText: String
    var feedback: String?
    var meaningScore: Int?
    var grammarScore: Int?
    var wordingScore: Int?
    var naturalnessScore: Int?
    var correctedSpanish: String? = nil
    var errors: [WritingError]? = nil
    var cardID: UUID? = nil
}

enum CardCategory: String, Codable, CaseIterable, Identifiable {
    case vocabulary = "词汇"
    case grammar = "语法"
    case expression = "表达"
    case knowledge = "知识"
    case correction = "写作纠错"
    var id: String { rawValue }
}

struct SourceReference: Codable {
    var materialID: UUID
    var segmentID: UUID?
    var quote: String?
}

struct StudyCard: Codable, Identifiable {
    var id: UUID
    var category: CardCategory
    var title: String? = nil
    var question: String
    var answer: String
    var sources: [SourceReference]
    var confirmedAt: Date?
    var dueAt: Date?
    var fsrsState: FSRSCardState?
    var createdAt: Date? = nil
    var updatedAt: Date? = nil
    var revisionCount: Int? = nil
    var deletedAt: Date? = nil
    /// Stable semantic identity produced by the study AI. Cards with the same
    /// category and key share one review history while retaining every source.
    var mergeKey: String? = nil
}

struct FSRSCardState: Codable {
    var difficulty: Double
    var stability: Double
    var lastReviewedAt: Date
    var lapses: Int
    /// These optional fields keep databases created before FSRS scheduling
    /// readable while preserving the full FSRS-6 learning state going forward.
    var stateRawValue: Int? = nil
    var scheduledDays: Double? = nil
    var learningSteps: Int? = nil
    var reps: Int? = nil
}

enum ReviewGrade: Int, CaseIterable, Identifiable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .again: "重来"
        case .hard: "困难"
        case .good: "良好"
        case .easy: "简单"
        }
    }
}

struct ReviewEvent: Codable, Identifiable {
    var id: UUID
    var cardID: UUID
    var reviewedAt: Date
    var grade: Int
    var nextDueAt: Date
    var scheduledDays: Double
    var elapsedDays: Double
}
