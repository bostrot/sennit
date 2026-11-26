/// The on-device models Weft can install.
///
/// URLs and sizes are pinned to specific files rather than "latest", so an
/// install is reproducible and a size check means something. Everything here
/// must be downloadable without authentication — a gated repository turns
/// into a 401 for every user and a feature that can never switch on.
library;

/// What a model is for.
enum ModelCapability { embedding, speechToText, chat }

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

  /// PrismML's 1-bit Bonsai 8B, for the AI features' "On this phone"
  /// provider.
  ///
  /// A Qwen3-8B whose every weight is one bit plus a scale per 128 — GGUF
  /// `Q1_0`, which stock llama.cpp runs on the CPU (NEON) and on Metal. The
  /// best answers the phone can write, at 1.16 GB. Apache-2.0, ungated; the
  /// URL is pinned to a revision, so the size below stays true.
  static const ModelSpec bonsai8b = ModelSpec(
    id: 'bonsai-8b-q1',
    displayName: 'Bonsai 8B',
    description: 'Writes the AI features\' answers on this phone.',
    capability: ModelCapability.chat,
    licence: 'Apache-2.0',
    files: [
      ModelFile(
        name: 'Bonsai-8B-Q1_0.gguf',
        url:
            'https://huggingface.co/prism-ml/Bonsai-8B-gguf/resolve/'
            '48516770dd04643643e9f9019a2a349cf26c5dbd/Bonsai-8B-Q1_0.gguf',
        sizeBytes: 1158654496,
      ),
    ],
  );

  /// Ternary Bonsai 2 2B, the smaller choice for phones with less memory.
  ///
  /// A Qwen3.5-2B with weights of -1, 0 or +1 — GGUF `Q2_0`, the ternary
  /// format stock llama.cpp runs (the smaller `PTQ1_0` file needs PrismML's
  /// fork). Half the download and a fraction of the memory of [bonsai8b],
  /// and three times as fast; plainer answers.
  static const ModelSpec ternaryBonsai2b = ModelSpec(
    id: 'ternary-bonsai-2-2b-q2',
    displayName: 'Ternary Bonsai 2 2B',
    description: 'A smaller, faster model for phones with less memory.',
    capability: ModelCapability.chat,
    licence: 'Apache-2.0',
    files: [
      ModelFile(
        name: 'Ternary-Bonsai-2-2B-Q2_0.gguf',
        url:
            'https://huggingface.co/prism-ml/Ternary-Bonsai-2-2B-gguf/resolve/'
            'a6032a5089ac27e96be3a80c7b42d1ad0bd89887/'
            'Ternary-Bonsai-2-2B-Q2_0.gguf',
        sizeBytes: 546689504,
      ),
    ],
  );

  /// The models the models screen offers: search and voice.
  static const List<ModelSpec> all = [miniLm, whisperBase, whisperSmall];

  /// The models the AI settings offer "On this phone", best first.
  static const List<ModelSpec> chat = [bonsai8b, ternaryBonsai2b];

  static ModelSpec? byId(String id) {
    for (final spec in [...all, ...chat]) {
      if (spec.id == id) return spec;
    }
    return null;
  }
}
