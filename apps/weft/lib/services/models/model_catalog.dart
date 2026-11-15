/// The on-device models Weft can install.
///
/// URLs and sizes are pinned to specific files rather than "latest", so an
/// install is reproducible and a size check means something. Everything here
/// must be downloadable without authentication — a gated repository turns
/// into a 401 for every user and a feature that can never switch on.
library;

/// What a model is for.
enum ModelCapability { embedding, speechToText }

/// One file belonging to a model.
class ModelFile {
  const ModelFile({
    required this.name,
    required this.url,
    required this.sizeBytes,
  });

  final String name;
  final String url;
  final int sizeBytes;
}

/// A model the user can install.
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.displayName,
    required this.description,
    required this.capability,
    required this.files,
    this.licence,
  });

  final String id;
  final String displayName;
  final String description;
  final ModelCapability capability;
  final List<ModelFile> files;
  final String? licence;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);
}

abstract final class ModelCatalog {
  /// Embedding model for on-device semantic search.
  ///
  /// MiniLM as quantised ONNX rather than the earlier Gecko `.tflite`: Weft's
  /// embedding runtime is ONNX Runtime, which every platform Sennit builds on
  /// can load — the Gecko file needed a LiteRT runtime and a SentencePiece
  /// tokeniser this app never had, so it downloaded and then did nothing.
  /// Apache-2.0, ungated, 384 dimensions, WordPiece vocabulary. English-first —
  /// a real trade, and far better than a model that cannot run.
  static const ModelSpec miniLm = ModelSpec(
    id: 'minilm-l6-v2',
    displayName: 'MiniLM L6 (search)',
    description:
        'Semantic search fully on this device — message text never leaves it. '
        'Tuned for English; other languages work, less precisely.',
    capability: ModelCapability.embedding,
    licence: 'Apache-2.0',
    files: [
      ModelFile(
        name: 'model_quantized.onnx',
        url:
            'https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/'
            'main/onnx/model_quantized.onnx',
        sizeBytes: 22972370,
      ),
      ModelFile(
        name: 'vocab.txt',
        url:
            'https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/'
            'main/vocab.txt',
        sizeBytes: 231508,
      ),
    ],
  );

  /// Vector length [miniLm] emits, needed wherever its vectors are stored.
  static const int miniLmDimensions = 384;

  /// Whisper for on-device voice transcription, quantised.
  ///
  /// `base` covers most voice notes at a 60 MB download; `small` is markedly
  /// better on accents and noise at three times the size.
  static const ModelSpec whisperBase = ModelSpec(
    id: 'whisper-base-q5',
    displayName: 'Whisper Base (voice)',
    description:
        'Transcribes voice messages on this device. Good for clear speech; '
        'multilingual.',
    capability: ModelCapability.speechToText,
    licence: 'MIT',
    files: [
      ModelFile(
        name: 'ggml-base-q5_1.bin',
        url:
            'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
            'main/ggml-base-q5_1.bin',
        sizeBytes: 59707625,
      ),
    ],
  );

  static const ModelSpec whisperSmall = ModelSpec(
    id: 'whisper-small-q5',
    displayName: 'Whisper Small (voice)',
    description:
        'Noticeably better on accents, background noise and mixed languages. '
        'Three times the download of Base.',
    capability: ModelCapability.speechToText,
    licence: 'MIT',
    files: [
      ModelFile(
        name: 'ggml-small-q5_1.bin',
        url:
            'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
            'main/ggml-small-q5_1.bin',
        sizeBytes: 190085487,
      ),
    ],
  );

  static const List<ModelSpec> all = [miniLm, whisperBase, whisperSmall];

  static ModelSpec? byId(String id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return null;
  }
}
