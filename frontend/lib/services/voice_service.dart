import 'dart:io';

import 'package:dio/dio.dart';

import '../models/voice_intake.dart';
import 'api_client.dart';

class VoiceService {
  final Dio _dio = ApiClient().dio;

  /// Upload an audio clip + optional default pet id and get a structured
  /// draft back. The server never throws on business-level failure — STT
  /// failure / intent-unknown / missing fields all come back as 200 with
  /// distinct `status` values. See docs §3.1.
  Future<VoiceIntakeResponse> intake({
    required File audioFile,
    required String clientRequestId,
    int? defaultPetId,
  }) async {
    final form = FormData.fromMap({
      'audio_file': await MultipartFile.fromFile(
        audioFile.path,
        filename: 'clip.wav',
        // We record 16kHz mono PCM wav because DashScope paraformer-
        // realtime-v2 does not accept the m4a/mp4 container.
        contentType: _wavMediaType(),
      ),
      'client_request_id': clientRequestId,
      'default_pet_id': ?defaultPetId,
    });

    // Backend uses DashScope async file-transcription (paraformer-v1),
    // which settles in ~3-5s for a 30s clip plus a few seconds of LLM
    // intent extraction. 30s of receive gives plenty of headroom without
    // letting a stuck upstream hold the UI hostage.
    final resp = await _dio.post(
      '/voice/intake',
      data: form,
      options: Options(
        sendTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    return VoiceIntakeResponse.fromJson(resp.data as Map<String, dynamic>);
  }

  /// Commit a draft to the real write services. `payload` must contain
  /// the intent-specific fields (pet_id + deworming_type + dewormed_at,
  /// etc.); the server re-validates through the existing create schemas.
  Future<VoiceIntakeConfirmResult> confirm({
    required String requestId,
    required VoiceIntent intent,
    required Map<String, dynamic> payload,
  }) async {
    final resp = await _dio.post(
      '/voice/intake/confirm',
      data: {
        'request_id': requestId,
        'intent': voiceIntentApiValue(intent),
        'payload': payload,
      },
    );
    return VoiceIntakeConfirmResult.fromJson(resp.data as Map<String, dynamic>);
  }

  /// Soft-cancel a draft (5-second undo). Only `draft_pending` states
  /// can be cancelled; already-confirmed entries must be deleted via
  /// their own resource endpoint.
  Future<void> cancel(String requestId) async {
    await _dio.delete('/voice/intake/$requestId');
  }
}

/// dio's `http_parser.MediaType` lives under a transitive dep; pass a
/// small shim so callers don't have to import it directly.
DioMediaType _wavMediaType() => DioMediaType('audio', 'wav');
