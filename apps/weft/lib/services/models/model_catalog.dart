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
  /// Gecko rather than EmbeddingGemma: the only LiteRT build of EmbeddingGemma
  /// lives in a gated repository, so unauthenticated downloads 401. Gecko is
  /// Apache-2.0, ungated, 768 dimensions, and a third smaller. English-first —
  /// a real trade, and far better than a model that cannot be downloaded.
  static const ModelSpec gecko = ModelSpec(
    id: 'gecko-110m-en',
    displayName: 'Gecko 110M (search)',
    description:
        'Semantic search fully on this device — message text never leaves it. '
        'Tuned for English; other languages work, less precisely.',
    capability: ModelCapability.embedding,
    licence: 'Apache-2.0',
    files: [
      ModelFile(
        name: 'Gecko_512_quant.tflite',
        url:
            'https://huggingface.co/litert-community/Gecko-110m-en/resolve/'
            'main/Gecko_512_quant.tflite',
        sizeBytes: 120432640,
      ),
      ModelFile(
        name: 'sentencepiece.model',
        url:
            'https://huggingface.co/litert-community/Gecko-110m-en/resolve/'
            'main/sentencepiece.model',
        sizeBytes: 794346,
      ),
    ],
  );

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

  static const List<ModelSpec> all = [gecko, whisperBase, whisperSmall];

  static ModelSpec? byId(String id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return null;
  }
}
