import Foundation

@MainActor
final class WhisperKitTranscriptionService {
    init(cacheDirectory: URL) {}

    var modelIsInstalled: Bool { false }

    func transcribe(
        audioURL: URL,
        onStatus: @escaping @MainActor (String) -> Void
    ) async throws -> WhisperTranscriptionResult {
        throw WhisperTranscriptionError.transcriptionFailed
    }
}

enum WhisperTranscriptionError: LocalizedError {
    case transcriptionFailed
    var errorDescription: String? { "Whisper test stub is not configured." }
}
