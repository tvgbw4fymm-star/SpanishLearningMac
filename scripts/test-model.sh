#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
TEST_BIN="$(mktemp /private/tmp/spanish-model-smoke.XXXXXX)"
trap 'rm -f "$TEST_BIN"' EXIT

CLANG_MODULE_CACHE_PATH=/private/tmp/spanish-learning-clang-cache \
  swiftc -sdk "$SDK_PATH" -module-cache-path /private/tmp/spanish-learning-swift-cache \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/Models.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/APIKeyStore.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/AIProvider.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/AIStudyService.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/WritingAIService.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/ReadingAIService.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/CardQuality.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/TitleGenerationService.swift" \
  "$PROJECT_ROOT"/Sources/SpanishLearningMac/FSRSVendor_*.swift \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/FSRSScheduler.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/AudioChunker.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/TranscriptionService.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/WhisperListeningPipeline.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/ListeningSubtitleAlignment.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/SubtitleImporter.swift" \
  "$PROJECT_ROOT/Tests/WhisperServiceSmokeStub.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/StudyStore.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/BackupManager.swift" \
  "$PROJECT_ROOT/Tests/ModelSmoke.swift" \
  -framework AppKit -framework AVFoundation -framework Speech -framework Security -framework CryptoKit -o "$TEST_BIN"
"$TEST_BIN"

CLANG_MODULE_CACHE_PATH=/private/tmp/spanish-learning-clang-cache \
  swiftc -sdk "$SDK_PATH" -module-cache-path /private/tmp/spanish-learning-swift-cache \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/Models.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/AudioChunker.swift" \
  "$PROJECT_ROOT/Sources/SpanishLearningMac/TranscriptionService.swift" \
  "$PROJECT_ROOT/Tests/AudioPipelineSmoke.swift" \
  -framework AVFoundation -framework Speech -o "$TEST_BIN"
"$TEST_BIN"
