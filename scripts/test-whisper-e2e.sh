#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
WHISPER_AUDIO="${WHISPER_AUDIO:-}"
WHISPER_SRT="${WHISPER_SRT:-}"
WHISPER_MODEL_CACHE="${WHISPER_MODEL_CACHE:-}"

if [[ -z "$WHISPER_AUDIO" || -z "$WHISPER_SRT" || -z "$WHISPER_MODEL_CACHE" ]]; then
  echo "Set WHISPER_AUDIO, WHISPER_SRT, and WHISPER_MODEL_CACHE to run this explicit integration test." >&2
  exit 2
fi
for input in "$WHISPER_AUDIO" "$WHISPER_SRT" \
  "$WHISPER_MODEL_CACHE/models/openai/whisper-small/tokenizer.json"; do
  if [[ ! -e "$input" ]]; then
    echo "Missing local E2E input: $input" >&2
    exit 2
  fi
done
MODEL_FOLDER="$WHISPER_MODEL_CACHE/models/argmaxinc/whisperkit-coreml/openai_whisper-small"
for model in AudioEncoder MelSpectrogram TextDecoder; do
  if [[ ! -e "$MODEL_FOLDER/$model.mlmodelc" && ! -e "$MODEL_FOLDER/$model.mlpackage" ]]; then
    echo "Missing installed Whisper model asset: $MODEL_FOLDER/$model" >&2
    exit 2
  fi
done

WHISPERKIT_PACKAGE="$PROJECT_ROOT/.build/checkouts/argmax-oss-swift"
if [[ ! -d "$WHISPERKIT_PACKAGE" ]]; then
  echo "Resolve the pinned WhisperKit dependency with swift build before running this test." >&2
  exit 2
fi

TEST_ROOT="$(mktemp -d /private/tmp/spanish-whisper-store-e2e.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/Sources/WhisperStoreIntegration"
cat > "$TEST_ROOT/Package.swift" <<PACKAGE
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperStoreIntegration",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "$WHISPERKIT_PACKAGE")],
    targets: [
        .executableTarget(
            name: "WhisperStoreIntegration",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        )
    ],
    swiftLanguageModes: [.v5]
)
PACKAGE

SOURCE_DIR="$PROJECT_ROOT/Sources/SpanishLearningMac"
TARGET_DIR="$TEST_ROOT/Sources/WhisperStoreIntegration"
for source in \
  Models.swift APIKeyStore.swift AIProvider.swift AIStudyService.swift WritingAIService.swift \
  ReadingAIService.swift CardQuality.swift TitleGenerationService.swift FSRSScheduler.swift \
  AudioChunker.swift TranscriptionService.swift ListeningSubtitleAlignment.swift \
  WhisperListeningPipeline.swift WhisperKitTranscriptionService.swift SubtitleImporter.swift \
  StudyStore.swift BackupManager.swift; do
  cp "$SOURCE_DIR/$source" "$TARGET_DIR/"
done
for source in "$SOURCE_DIR"/FSRSVendor_*.swift; do
  cp "$source" "$TARGET_DIR/"
done
cp "$PROJECT_ROOT/Tests/WhisperStoreIntegration.swift" "$TARGET_DIR/main.swift"

cd "$TEST_ROOT"
swift run WhisperStoreIntegration "$WHISPER_AUDIO" "$WHISPER_SRT" "$WHISPER_MODEL_CACHE"
