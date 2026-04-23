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
        // We record 16kHz mono PCM wav because the server's primary
        // STT path (DashScope `fun-asr-realtime` over WebSocket) expects
        // the raw bytes to be parseable as 16-bit mono PCM — other
        // formats silently fall through to the slower async-file
        // fallback. See `backend/app/services/stt.py`.
        contentType: _wavMediaType(),
      ),
      'client_request_id': clientRequestId,
      'default_pet_id': ?defaultPetId,
    });

    // Backend benchmark on 2026-04-23 (3.1s clip × N=10) shows the
    // realtime WS path at p50 1.3s / p90 1.6s, plus ~2.5s LLM intent
    // extraction. 30s of receive still leaves plenty of headroom for
    // the async-file fallback (~5-12s) if SG WS is unreachable.
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
