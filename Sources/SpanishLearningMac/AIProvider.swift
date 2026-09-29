import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case deepSeek = "deepseek"
    case openAI = "openai"
    case compatible = "compatible"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI"
        case .compatible: "兼容接口"
        }
    }
    var defaultModel: String {
        switch self {
        case .deepSeek: "deepseek-flash"
        case .openAI: "gpt-5-mini"
        case .compatible: ""
        }
    }
}

enum AIProviderSettings {
    private static let providerKey = "textAIProvider"
    private static let modelPrefix = "textAIModel."
    private static let endpointKey = "textAICompatibleEndpoint"

    // This app currently sends every text AI request to DeepSeek.
    static var selected: AIProvider { .deepSeek }

    static func model(for provider: AIProvider) -> String {
        UserDefaults.standard.string(forKey: modelPrefix + provider.rawValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? provider.defaultModel
    }

    static func setModel(_ model: String, for provider: AIProvider) {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelPrefix + provider.rawValue)
    }

    static var compatibleEndpoint: String {
        get { UserDefaults.standard.string(forKey: endpointKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: endpointKey) }
    }

    static func endpoint(for provider: AIProvider) throws -> URL {
        switch provider {
        case .deepSeek: return URL(string: "https://api.deepseek.com/responses")!
        case .openAI: return URL(string: "https://api.openai.com/v1/responses")!
        case .compatible:
            guard let url = URL(string: compatibleEndpoint),
                  url.scheme == "https", url.host != nil,
                  url.path.hasSuffix("/chat/completions") else {
                throw AIProviderError.invalidEndpoint
            }
            return url
        }
    }

    static func textKey() throws -> String? { try APIKeyStore.read(for: selected) }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

enum AIProviderError: LocalizedError {
    case invalidEndpoint
    case missingModel
    case missingKey

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "兼容接口地址必须是 HTTPS，且以 /chat/completions 结尾。"
        case .missingModel: "请在设置中填写兼容接口的模型名称。"
        case .missingKey: "请先在设置中保存所选文字 AI 服务的 API 密钥。"
        }
    }
}

enum AITextClient {
    /// Test-only seam: when non-nil, network requests are routed through these URLProtocol
    /// classes instead of hitting the real network. Always nil in production.
    static var testProtocolClassesOverride: [AnyClass]?

    static func request<T: Decodable>(input: String, instructions: String,
                                      schemaName: String, schema: [String: Any],
                                      apiKey: String, result: T.Type) async throws -> T {
        let provider = AIProviderSettings.selected
        let model = AIProviderSettings.model(for: provider)
        guard !model.isEmpty else { throw AIProviderError.missingModel }
        let endpoint = try AIProviderSettings.endpoint(for: provider)
        let body: [String: Any]
        if provider == .compatible {
            let schemaText = String(data: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
            body = ["model": model,
                    "messages": [["role": "system", "content": instructions + "\n只返回符合以下 JSON Schema 的 JSON 对象，不要附加说明：\n" + schemaText],
                                 ["role": "user", "content": input]],
                    "response_format": ["type": "json_object"]]
        } else {
            body = ["model": model, "instructions": instructions, "input": input,
                    "text": ["format": ["type": "json_schema", "name": schemaName,
                                        "strict": true, "schema": schema]]]
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw AIProviderError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(["Be" + "arer", trimmedKey].joined(separator: " "), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 180
        if let overrides = testProtocolClassesOverride { configuration.protocolClasses = overrides }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIStudyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (object?["error"] as? [String: Any])?["message"] as? String
            throw AIStudyError.server(http.statusCode, message ?? "请检查接口地址、模型、密钥和账户额度。")
        }
        let text: String?
        if provider == .compatible {
            let envelope = try JSONDecoder().decode(ChatEnvelope.self, from: data)
            text = envelope.choices.first?.message.content
        } else {
            let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
            for output in envelope.output where output.type == "message" {
                for content in output.content ?? [] {
                    if let refusal = content.refusal { throw AIStudyError.refused(refusal) }
                }
            }
            text = envelope.output.flatMap { $0.content ?? [] }.first { $0.type == "output_text" }?.text
        }
        guard let text, let payload = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(T.self, from: payload) else {
            throw AIStudyError.invalidResponse
        }
        return decoded
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

    private struct ChatEnvelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }
}
