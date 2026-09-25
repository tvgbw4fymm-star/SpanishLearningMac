import Foundation

struct LearningPointRequest: Identifiable, Sendable {
    let id: UUID
    var category: CardCategory
    var prompt: String
}

struct ListeningAnalysisResult: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let category: ListeningAnalysisCategory
        let title: String
        let detail: String
        let evidence: String?
    }

    let explanation: String
    let items: [Item]
}

struct ListeningCardsResult: Decodable, Sendable {
    struct Card: Decodable, Sendable {
        let requestID: String
        let category: CardCategory
        let mergeKey: String
        let question: String
        let answer: String
    }
    let cards: [Card]

    init(cards: [Card]) {
        self.cards = cards
    }
}

private struct ResponsesEnvelope: Decodable {
    struct Output: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
            let refusal: String?
        }
        let type: String
        let content: [Content]?
    }
    let output: [Output]
}

enum AIStudyError: LocalizedError {
    case invalidResponse
    case refused(String)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "AI 返回的学习内容无法读取，请重试。"
        case .refused(let reason): "AI 未能生成内容：\(reason)"
        case .server(let status, let message): "AI 请求失败（\(status)）：\(message)"
        }
    }
}

enum AIStudyService {
    static func analyzeListening(transcript: String, attempt: String,
                                 apiKey: String) async throws -> ListeningAnalysisResult {
        let input = """
        西语原句：\(transcript)
        学习者听写：\(attempt.isEmpty ? "（空白）" : attempt)
        材料口音或地区上下文：未提供；不得仅凭这句话断言具体口音
        """
        return try await AITextClient.request(
            input: input,
            instructions: listeningInstructions,
            schemaName: "listening_analysis",
            schema: listeningAnalysisSchema,
            apiKey: apiKey,
            result: ListeningAnalysisResult.self
        )
    }

    static func generateListeningCards(transcript: String,
                                       points: [LearningPointRequest],
                                       apiKey: String) async throws -> ListeningCardsResult {
        let requested = points.map { "- ID=\($0.id.uuidString) [\($0.category.rawValue)] \($0.prompt)" }.joined(separator: "\n")
        let input = """
        西语原句：\(transcript)
        用户手工填写的积累要点：
        \(requested.isEmpty ? "（没有填写任何要点）" : requested)
        """
        let result = try await AITextClient.request(
            input: input,
            instructions: listeningCardsInstructions,
            schemaName: "listening_cards",
            schema: listeningCardsSchema(),
            apiKey: apiKey,
            result: ListeningCardsResult.self
        )
        let requestedIDs = Set(points.map { $0.id.uuidString })
        let returnedIDs = Set(result.cards.map { $0.requestID })
        guard requestedIDs == returnedIDs, result.cards.count == points.count else {
            throw AIStudyError.invalidResponse
        }
        return result
    }

    static let listeningAnalysisSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "explanation": ["type": "string", "description": "简洁解释学习者可能没有听出的原因，包括可能的连读、弱读、口音、音素混淆或词组识别。没有音频证据时明确使用可能、通常等措辞。"],
                "items": [
                    "type": "array",
                    "description": "只返回真正有证据且对当前句有帮助的听力分析，不要机械填满类别。",
                    "items": [
                        "type": "object",
                        "properties": [
                            "category": ["type": "string", "enum": ["difficulty", "connectedSpeech", "reduction", "accent", "attemptDifference"]],
                            "title": ["type": "string"],
                            "detail": ["type": "string"],
                            "evidence": ["type": ["string", "null"]]
                        ],
                        "required": ["category", "title", "detail", "evidence"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["explanation", "items"],
            "additionalProperties": false
        ]

    static func listeningCardsSchema(cardCategories: [String] = CardCategory.allCases.map(\.rawValue)) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "cards": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "requestID": ["type": "string", "description": "复制对应要点的 ID"],
                            "category": ["type": "string", "enum": cardCategories],
                            "mergeKey": ["type": "string", "description": "稳定的语义键：分类|西语词元、结构或知识主题|具体义项。相同内容必须复用；同一词不同义项必须不同。"],
                            "question": ["type": "string"],
                            "answer": ["type": "string"]
                        ],
                        "required": ["requestID", "category", "mergeKey", "question", "answer"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["cards"],
            "additionalProperties": false
        ]
    }

    private static let listeningInstructions = """
        你是严谨的西班牙语听力教师。只分析这句话为什么在真实听力中不容易听懂，不做普通词汇、语法或表达教学。重点关注连读、音节连接、弱读、吞音、省音、自然语流音变、单词边界、音素混淆、语速节奏、明确上下文支持的口音听辨特点，以及学习者听写与原句的差异。你没有真正听到音频，不能假装听过；只能根据原句、听写和文字上下文作有依据的分析。不确定时使用“可能”“通常”“这里可能”等措辞。材料口音或地区上下文未提供时，不得断言具体口音。只返回确实与听辨直接相关且有价值的 items，不要返回普通词汇知识、普通语法知识、固定搭配、值得积累的表达或制卡建议。
        """

    private static let listeningCardsInstructions = """
        你是严谨的西班牙语学习卡片教师。只根据用户手工填写的积累要点，为每个要点生成一张学习卡。不要分析听辨困难，不要生成或修改 Listening analysis，不要自行增加用户没有填写的学习点。原样复制每个要点的 ID 到 requestID，每个要点必须且只能对应一张卡。卡片问题简洁，答案适合以后复习。遇到动词时，先说明本质语义，再解释原句中的具体作用，并给出一到两个不同语境的西语例句及中文说明。每张卡必须生成稳定的 mergeKey。
        """

}

struct CardRevisionResult: Decodable, Sendable {
    let category: CardCategory
    let question: String
    let answer: String
}

extension AIStudyService {
    static func reviseCard(question: String, answer: String, category: CardCategory,
                           feedback: String, sourceQuote: String?, apiKey: String) async throws -> CardRevisionResult {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "category": ["type": "string", "enum": CardCategory.allCases.map(\.rawValue)],
                "question": ["type": "string"],
                "answer": ["type": "string"]
            ],
            "required": ["category", "question", "answer"],
            "additionalProperties": false
        ]
        let input = """
        当前分类：\(category.rawValue)
        当前问题：\(question)
        当前答案：\(answer)
        原句：\(sourceQuote ?? "（无）")
        修改意见：\(feedback)
        """
        let result = try await AITextClient.request(input: input,
                                                     instructions: "用中文按照修改意见重写学习卡，直接返回修改后的完整内容。保留与原句的联系。若核心是动词，先解释本质语义，再解释原句作用，最后给一到两个不同语境的西语例句和中文说明。不要在卡片里提及修改过程。",
                                                     schemaName: "revised_study_card", schema: schema,
                                                     apiKey: apiKey, result: CardRevisionResult.self)
        return result
    }

}

struct TranscriptProofreadingResult: Decodable, Sendable {
    let suggestedText: String
    let explanation: String
}

extension AIStudyService {
    static func proofreadTranscript(_ transcript: String, speechRecognition: String?, apiKey: String) async throws -> TranscriptProofreadingResult {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "suggestedText": ["type": "string"],
                "explanation": ["type": "string"]
            ],
            "required": ["suggestedText", "explanation"],
            "additionalProperties": false
        ]
        let result = try await AITextClient.request(
            input: "字幕原文：\n\(transcript)\n\n本机语音识别参考：\n\(speechRecognition ?? "（未提供）")",
            instructions: "你是严谨的西班牙语文字校对员。对照字幕文本与可选的本机语音识别参考，修正明显的拼写、重音符号、标点、大小写和有充分证据的语法错误。语音识别结果也可能出错，分歧不确定时保留字幕并在解释中指出。保留原意、口语表达、专名与原来的句数；不能声称自己听过音频，也不能凭猜测补出未提供的内容。suggestedText 返回完整西语句子；explanation 用简短中文说明改动，若无需修改则说明无需修改。",
            schemaName: "transcript_proofreading", schema: schema,
            apiKey: apiKey, result: TranscriptProofreadingResult.self)
        guard !result.suggestedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIStudyError.invalidResponse
        }
        return result
    }
}
