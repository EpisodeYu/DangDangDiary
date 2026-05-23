import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../config/constants.dart';

class PetClassificationResult {
  const PetClassificationResult({
    required this.isPet,
    required this.score,
    required this.skipped,
  });

  final bool isPet;
  final double score;

  /// True when the classifier was unavailable (model missing, load failed,
  /// or decode failed). Callers should treat skipped results as "allow by
  /// default" so a missing model does not block uploads.
  final bool skipped;
}

/// On-device pet classifier backed by a TFLite ImageNet model.
///
/// Expected bundled model:
///   - Input:  float32 (normalized to [-1, 1]) or uint8, shape [1, H, W, 3]
///   - Output: float32 or uint8, shape [1, N] where N is 1000 or 1001
///
/// "Pet" is the summed probability over ImageNet dog classes (151..268) and
/// cat classes (281..285). When the model emits 1001 outputs the indices are
/// shifted by +1 to account for the leading background class.
class PetClassifier {
  PetClassifier._();

  static final PetClassifier instance = PetClassifier._();

  static const int _dogStart = 151;
  static const int _dogEnd = 268;
  static const int _catStart = 281;
  static const int _catEnd = 285;

  Interpreter? _interpreter;
  bool _loadFailed = false;
  Future<void>? _loadFuture;

  late List<int> _inputShape;
  late TensorType _inputType;
  late List<int> _outputShape;
  late TensorType _outputType;

  Future<void> _ensureLoaded() async {
    if (_interpreter != null || _loadFailed) return;
    _loadFuture ??= _load();
    await _loadFuture;
  }

  Future<void> _load() async {
    try {
      final interpreter = await Interpreter.fromAsset(
        AppConstants.petClassifierModelAsset,
      );
      _inputShape = interpreter.getInputTensor(0).shape;
      _inputType = interpreter.getInputTensor(0).type;
      _outputShape = interpreter.getOutputTensor(0).shape;
      _outputType = interpreter.getOutputTensor(0).type;
      _interpreter = interpreter;
      debugPrint(
        '[PetClassifier] loaded in=$_inputShape($_inputType) '
        'out=$_outputShape($_outputType)',
      );
    } catch (e, st) {
      _loadFailed = true;
      debugPrint('[PetClassifier] model load failed: $e\n$st');
    }
  }

  Future<PetClassificationResult> classify(File jpegFile) async {
    if (!AppConstants.enableClientPetRecognition) {
      return const PetClassificationResult(
        isPet: true, score: 0, skipped: true,
      );
    }

    await _ensureLoaded();
    final interpreter = _interpreter;
    if (interpreter == null) {
      return const PetClassificationResult(
        isPet: true, score: 0, skipped: true,
      );
    }

    try {
      debugPrint(
        '[PetClassifier] classify start file=${jpegFile.path} '
        'size=${await jpegFile.length()}B',
      );
      final bytes = await jpegFile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        debugPrint('[PetClassifier] decode failed; skipping');
        return const PetClassificationResult(
          isPet: true, score: 0, skipped: true,
        );
      }
      debugPrint(
        '[PetClassifier] decoded ${decoded.width}x${decoded.height} '
        'fmt=${decoded.format} numCh=${decoded.numChannels}',
      );

      final h = _inputShape[1];
      final w = _inputShape[2];
      final resized = img.copyResize(
        decoded,
        width: w,
        height: h,
        interpolation: img.Interpolation.average,
      );

      // Sample a handful of pixel values at fixed spots so we can confirm
      // channel order and range match RGB/[0..255] expectations.
      String sample(int px, int py) {
        final p = resized.getPixel(px, py);
        return '($px,$py)=R${p.r.toInt()} G${p.g.toInt()} B${p.b.toInt()}';
      }
      debugPrint(
        '[PetClassifier] resized ${resized.width}x${resized.height} '
        'samples: ${sample(0,0)}, ${sample(w~/2,h~/2)}, ${sample(w-1,h-1)}',
      );

      final input = _buildInput(resized, h, w);
      final output = _buildOutput();
      interpreter.run(input, output);

      final scores = _normalizeOutput(output);
      final petScore = _sumPetProbability(scores);

      final topIdx = _argTop(scores, 5);
      debugPrint(
        '[PetClassifier] petScore=${petScore.toStringAsFixed(4)} '
        'thr=${AppConstants.petClassifierThreshold} '
        'top5=$topIdx raw=${topIdx.map((i) => scores[i].toStringAsFixed(3)).toList()}',
      );

      return PetClassificationResult(
        isPet: petScore >= AppConstants.petClassifierThreshold,
        score: petScore,
        skipped: false,
      );
    } catch (e, st) {
      debugPrint('[PetClassifier] inference failed: $e\n$st');
      return const PetClassificationResult(
        isPet: true, score: 0, skipped: true,
      );
    }
  }

  Object _buildInput(img.Image image, int h, int w) {
    if (_inputType == TensorType.uint8) {
      final buf = Uint8List(h * w * 3);
      var i = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final px = image.getPixel(x, y);
          buf[i++] = px.r.toInt();
          buf[i++] = px.g.toInt();
          buf[i++] = px.b.toInt();
        }
      }
      return buf.reshape([1, h, w, 3]);
    }
    final zeroToOne =
        AppConstants.petClassifierNormalization == 'zero_to_one';
    final buf = Float32List(h * w * 3);
    var i = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final px = image.getPixel(x, y);
        if (zeroToOne) {
          buf[i++] = px.r / 255.0;
          buf[i++] = px.g / 255.0;
          buf[i++] = px.b / 255.0;
        } else {
          buf[i++] = (px.r / 127.5) - 1.0;
          buf[i++] = (px.g / 127.5) - 1.0;
          buf[i++] = (px.b / 127.5) - 1.0;
        }
      }
    }
    return buf.reshape([1, h, w, 3]);
  }

  Object _buildOutput() {
    final n = _outputShape.reduce((a, b) => a * b);
    if (_outputType == TensorType.uint8) {
      return List<int>.filled(n, 0).reshape(_outputShape);
    }
    return List<double>.filled(n, 0.0).reshape(_outputShape);
  }

  List<double> _normalizeOutput(Object output) {
    // Output shape is [1, N]; unwrap batch dim. The inner list's element type
    // depends on how tflite_flutter filled it, so read via `num` and trust the
    // model-declared output type for interpretation.
    final inner = (output as List)[0] as List;
    if (_outputType == TensorType.uint8) {
      return inner.map((v) => (v as num) / 255.0).toList();
    }
    return inner.map((v) => (v as num).toDouble()).toList();
  }

  double _sumPetProbability(List<double> scores) {
    final offset = scores.length == 1001 ? 1 : 0;

    final total = scores.fold<double>(0, (a, b) => a + b);
    final hasNegative = scores.any((s) => s < 0);
    final needsSoftmax = hasNegative || (total - 1.0).abs() > 0.2;
    final probs = needsSoftmax ? _softmax(scores) : scores;

    var sum = 0.0;
    for (var i = _dogStart; i <= _dogEnd; i++) {
      sum += probs[i + offset];
    }
    for (var i = _catStart; i <= _catEnd; i++) {
      sum += probs[i + offset];
    }
    return sum;
  }

  List<int> _argTop(List<double> scores, int k) {
    final idx = List<int>.generate(scores.length, (i) => i);
    idx.sort((a, b) => scores[b].compareTo(scores[a]));
    return idx.take(k).toList();
  }

  List<double> _softmax(List<double> logits) {
    var maxLogit = logits[0];
    for (final v in logits) {
      if (v > maxLogit) maxLogit = v;
    }
    final exps = logits.map((v) => math.exp(v - maxLogit)).toList();
    final denom = exps.fold<double>(0, (a, b) => a + b);
    return exps.map((v) => v / denom).toList();
  }
}
