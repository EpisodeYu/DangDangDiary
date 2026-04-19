class AppConstants {
  AppConstants._();

  /// Base URL for API calls — point to Nginx unified entry
  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'http://REDACTED_IP', // Android emulator → host machine
  );

  static const String apiPrefix = '/api/v1';

  /// Page size for list APIs
  static const int defaultPageSize = 20;

  /// When true, run an on-device TFLite model to check that the uploaded
  /// image contains a cat or dog before sending it to the server.
  /// Set to false to fall back to server-side recognition (see
  /// backend setting ENABLE_SERVER_PET_RECOGNITION).
  static const bool enableClientPetRecognition = true;

  /// TFLite model bundled under assets/models/. Expected to be a
  /// MobileNet-family ImageNet classifier (float32, 1x224x224x3 input,
  /// 1x1000 or 1x1001 output).
  static const String petClassifierModelAsset =
      'assets/models/pet_classifier.tflite';

  /// Minimum summed probability over ImageNet cat+dog classes required to
  /// accept an image as a pet. We prefer false positives over false
  /// negatives: a user whose cat photo is rejected has a worse experience
  /// than one whose non-pet photo is accepted. Reference points on this
  /// model: random noise ≈0.008, uniform gray ≈0.06, a clear cat ≈0.7.
  /// Real-world pet photos (odd angles, partial occlusion, low light) often
  /// land in the 0.08–0.15 range, so 0.08 recovers those cases while still
  /// sitting above the non-pet noise floor (~0.06).
  static const double petClassifierThreshold = 0.08;

  /// Float32 input normalization for the bundled model.
  ///   'zero_to_one'      -> px / 255            (TF Hub classification signature)
  ///   'minus_one_to_one' -> (px / 127.5) - 1    (Keras preprocess_input)
  static const String petClassifierNormalization = 'zero_to_one';
}
