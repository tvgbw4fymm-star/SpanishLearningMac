import Foundation

struct LearningPointRequest: Identifiable, Sendable {
    let id: UUID
    var category: CardCategory
    var prompt: String
}

struct ListeningAIResult: Decodable, Sendable {
    struct Card: Decodable, Sendable {
        let requestID: String
        let category: CardCategory
        let mergeKey: String
        let question: String
        let answer: String
    }
    let explanation: String
    let cards: [Card]
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
    static func explainListening(transcript: String, attempt: String,
                                 points: [LearningPointRequest], apiKey: String) async throws -> ListeningAIResult {
        let requested = points.map { "- ID=\($0.id.uuidString) [\($0.category.rawValue)] \($0.prompt)" }.joined(separator: "\n")
        let input = """
        西语原句：\(transcript)
        学习者听写：\(attempt.isEmpty ? "（空白）" : attempt)
        学习者希望积累的要点：
        \(requested.isEmpty ? "（没有指定要点；只解释听写困难）" : requested)
        """
        let categories = CardCategory.allCases.map(\.rawValue)
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "explanation": ["type": "string", "description": "简洁解释学习者可能没有听出的原因，包括可能的连读、弱读、口音、音素混淆或词组识别。没有音频证据时明确使用可能、通常等措辞。"],
                "cards": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "requestID": ["type": "string", "description": "复制对应要点的 ID"],
                            "category": ["type": "string", "enum": categories],
                            "mergeKey": ["type": "string", "description": "稳定的语义键：分类|西语词元、结构或知识主题|具体义项。相同内容必须复用；同一词不同义项必须不同。"],
                            "question": ["type": "string"],
                            "answer": ["type": "string"]
                        ],
                        "required": ["requestID", "category", "mergeKey", "question", "answer"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["explanation", "cards"],
            "additionalProperties": false
        ]
        let instructions = """
        你是严谨的西班牙语教师。用中文回答。先比较听写与原句，简洁解释可能的听辨困难；不能假装听过未提供的音频。随后严格按用户实际填写的每个要点生成一张详细学习卡，原样复制该要点的 ID 到 requestID，不自行增加低价值卡片。卡片问题简洁，答案适合以后复习。遇到动词时，先说明其本质语义，再解释原句中的具体作用，并给出一到两个不同语境的西语例句及中文说明。固定搭配、语法、文化知识分别放入最合适的分类。文化或事实性问题只解释稳定知识，不编造实时信息。每张卡必须生成稳定的 mergeKey，格式为“分类|规范化西语词元、结构或知识主题|具体义项”；同一内容即使提问措辞不同也复用同一个键，同一单词的不同义项必须使用不同键。
        """
        let result = try await AITextClient.request(input: input, instructions: instructions,
                                                     schemaName: "listening_study_result", schema: schema,
                                                     apiKey: apiKey, result: ListeningAIResult.self)
        let requestedIDs = Set(points.map { $0.id.uuidString })
        let returnedIDs = Set(result.cards.map(\.requestID))
        guard requestedIDs == returnedIDs, result.cards.count == points.count else {
            throw AIStudyError.invalidResponse
        }
        return result
    }

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
