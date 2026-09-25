import Foundation

enum TitleGenerationService {
    private struct Result: Decodable { let title: String }

    static func generate(from text: String, kind: String) async throws -> String {
        guard let key = try AIProviderSettings.textKey(), !key.isEmpty else {
            throw AIProviderError.missingKey
        }
        let excerpt = String(text.prefix(4000))
        let result: Result = try await AITextClient.request(
            input: "素材类型：\(kind)\n内容：\(excerpt)",
            instructions: "为西班牙语学习素材拟一个准确、简短的中文标题，最多 12 个汉字。不要引用原文长句，不要书名号、引号、序号或附加解释。",
            schemaName: "study_material_title",
            schema: ["type": "object", "properties": ["title": ["type": "string"]],
                     "required": ["title"], "additionalProperties": false],
            apiKey: key, result: Result.self
        )
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AIStudyError.invalidResponse }
        return String(title.prefix(16))
    }
}
