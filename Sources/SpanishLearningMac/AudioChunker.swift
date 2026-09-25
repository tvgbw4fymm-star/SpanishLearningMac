import Foundation
import AVFoundation

struct AudioChunk: Sendable {
    let url: URL
    let offset: Double
    let duration: Double
}

enum AudioChunkerError: LocalizedError {
    case unsupportedFormat
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "这段音频暂时无法转换为转写所需格式。"
        case .emptyAudio: "音频文件没有可读取的内容。"
        }
    }
}

enum AudioChunker {
    // Create one short WAV at a time, so long recordings do not fill the disk with temporary audio.
    static func next(_ source: URL, after offset: Double, into directory: URL) throws -> AudioChunk? {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, format.sampleRate > 0,
              format.channelCount > 0 else { throw AudioChunkerError.unsupportedFormat }
        guard file.length > 0 else { throw AudioChunkerError.emptyAudio }
        let start = AVAudioFramePosition((offset * format.sampleRate).rounded())
        guard start < file.length else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let maxSeconds = min(35.0, 20_000_000.0 / (format.sampleRate * Double(format.channelCount) * 4.0))
        let maxFrames = max(AVAudioFramePosition(format.sampleRate), AVAudioFramePosition(maxSeconds * format.sampleRate))
        let target = min(file.length, start + maxFrames)
        let end = target == file.length ? target : quietBoundary(in: file, around: target, after: start)
        guard end > start else { throw AudioChunkerError.unsupportedFormat }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved
        ]
        let url = directory.appendingPathComponent("chunk-\(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: url, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        file.framePosition = start
        var remaining = end - start
        while remaining > 0 {
            let capacity = AVAudioFrameCount(min(remaining, 65_536))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw AudioChunkerError.unsupportedFormat
            }
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0 else { throw AudioChunkerError.unsupportedFormat }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return AudioChunk(url: url, offset: Double(start) / format.sampleRate,
                          duration: Double(end - start) / format.sampleRate)
    }

    static func slice(_ source: URL, from startSeconds: Double, to endSeconds: Double, into directory: URL) throws -> URL {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        let start = max(0, AVAudioFramePosition((startSeconds * format.sampleRate).rounded()))
        let end = min(file.length, AVAudioFramePosition((endSeconds * format.sampleRate).rounded()))
        guard end > start else { throw AudioChunkerError.emptyAudio }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sentence-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved
        ]
        let output = try AVAudioFile(forWriting: url, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        file.framePosition = start
        var remaining = end - start
        while remaining > 0 {
            let capacity = AVAudioFrameCount(min(remaining, 65_536))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw AudioChunkerError.unsupportedFormat
            }
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0 else { throw AudioChunkerError.unsupportedFormat }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return url
    }

    static func split(_ source: URL, into directory: URL) throws -> [AudioChunk] {
        var result: [AudioChunk] = []
        var offset = 0.0
        while let chunk = try next(source, after: offset, into: directory) {
            result.append(chunk)
            offset = chunk.offset + chunk.duration
        }
        return result
    }

    private static func quietBoundary(in file: AVAudioFile, around target: AVAudioFramePosition,
                                      after start: AVAudioFramePosition) -> AVAudioFramePosition {
        let sampleRate = file.processingFormat.sampleRate
        let radius = AVAudioFramePosition(min(4.0, Double(target - start) / sampleRate * 0.15) * sampleRate)
        let scanStart = max(start + AVAudioFramePosition(4 * sampleRate), target - radius)
        let scanEnd = target
        let count = AVAudioFrameCount(max(0, scanEnd - scanStart))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return target }
        file.framePosition = scanStart
        do { try file.read(into: buffer, frameCount: count) } catch { return target }
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return target }
        let window = max(1, Int(sampleRate / 10))
        let length = Int(buffer.frameLength)
        var bestFrame = Int(target - scanStart)
        var bestEnergy = Double.infinity
        for offset in stride(from: 0, to: max(1, length - window), by: window) {
            var energy = 0.0
            for channel in 0..<Int(file.processingFormat.channelCount) {
                for frame in stride(from: offset, to: min(length, offset + window), by: 16) {
                    energy += Double(abs(channels[channel][frame]))
                }
            }
            if energy < bestEnergy {
                bestEnergy = energy
                bestFrame = offset + window / 2
            }
        }
        return max(start + 1, min(file.length, scanStart + AVAudioFramePosition(bestFrame)))
    }
}
