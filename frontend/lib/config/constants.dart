class AppConstants {
  AppConstants._();

  /// Base URL for API calls — point to Nginx unified entry.
  /// Inject the real address at build time via `--dart-define=BASE_URL=...`.
  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'http://127.0.0.1',
  );

  static const String apiPrefix = '/api/v1';

  /// Page size for list APIs
  static const int defaultPageSize = 20;

  /// When true, run an on-device TFLite model to check that the uploaded
  /// image contains a cat or dog before sending it to the server.
  ///
  /// Disabled by default since Optimization Step 1 (2026-05): users often
  /// upload strongly-related but non-cat-non-dog photos (pet supplies,
  /// group shots, food bowls, vet receipts) and a strict client-side
  /// classifier rejects them, hurting UX. The server-side
  /// `RecognizeScene` path is also off by default (see
  /// `ENABLE_SERVER_PET_RECOGNITION`).
  ///
  /// The flag, [PetClassifier] service, the TFLite asset under
  /// `assets/models/` and the `tflite_flutter` dependency are all kept
  /// so future work can re-enable on-device recognition by flipping
  /// this back to `true`.
  static const bool enableClientPetRecognition = false;

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

  // ---------------- Share-code QR (Optimization Step 3) ----------------

  /// URL prefix used as the QR payload for share codes. Pattern is
  /// `<shareLinkBaseUrl><8-char code>`. The domain itself is a
  /// placeholder until a real one is purchased; `parseShareCode`
  /// validates `host` against [shareLinkHosts] so we can swap the
  /// production host in one place without breaking already-printed
  /// QR codes.
  static const String shareLinkBaseUrl = 'https://dangdangdiary.app/s/';

  /// Hosts we accept while scanning a QR. Anything else is rejected
  /// up-front with a user-facing "这不是一张当当日记的分享码".
  static const Set<String> shareLinkHosts = {
    'dangdangdiary.app',
    'app.dangdangdiary.com',
  };

  /// Server-side share codes are 8 ASCII alphanumerics, matched
  /// case-insensitively but normalized to upper-case before redeem.
  static final RegExp shareCodePattern = RegExp(r'^[A-Z0-9]{8}$');
}
