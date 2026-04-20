// Phase 2 Step 2 — voice intake models (docs/phase2-step2-voice-intake.md §3).

enum VoiceIntakeStatus {
  sttFailed,
  intentUnknown,
  draftPending,
}

VoiceIntakeStatus _statusFromString(String s) {
  switch (s) {
    case 'stt_failed':
      return VoiceIntakeStatus.sttFailed;
    case 'intent_unknown':
      return VoiceIntakeStatus.intentUnknown;
    case 'draft_pending':
      return VoiceIntakeStatus.draftPending;
  }
  throw ArgumentError('Unknown voice intake status: $s');
}

enum VoiceIntent {
  deworming,
  vaccination,
  weight,
  routine,
  unknown,
}

VoiceIntent? voiceIntentFromString(String? s) {
  if (s == null) return null;
  switch (s) {
    case 'deworming':
      return VoiceIntent.deworming;
    case 'vaccination':
      return VoiceIntent.vaccination;
    case 'weight':
      return VoiceIntent.weight;
    case 'routine':
      return VoiceIntent.routine;
    case 'unknown':
      return VoiceIntent.unknown;
  }
  return null;
}

String voiceIntentApiValue(VoiceIntent intent) {
  switch (intent) {
    case VoiceIntent.deworming:
      return 'deworming';
    case VoiceIntent.vaccination:
      return 'vaccination';
    case VoiceIntent.weight:
      return 'weight';
    case VoiceIntent.routine:
      return 'routine';
    case VoiceIntent.unknown:
      return 'unknown';
  }
}

String voiceIntentLabel(VoiceIntent intent) {
  switch (intent) {
    case VoiceIntent.deworming:
      return '驱虫';
    case VoiceIntent.vaccination:
      return '疫苗';
    case VoiceIntent.weight:
      return '体重';
    case VoiceIntent.routine:
      return '日常';
    case VoiceIntent.unknown:
      return '未知';
  }
}

/// A structured draft built by the backend from the raw STT/LLM output.
///
/// Every field is optional — missing fields are listed in
/// [VoiceIntakeResponse.missingFields] and the UI prompts for them
/// before calling `confirm`.
class VoiceIntakeDraft {
  final int? petId;
  final String? petName;
  final String? note;

  // deworming
  final String? dewormingType; // internal | external | combined
  final String? dewormedAt;    // YYYY-MM-DD

  // vaccination
  final String? vaccineName;
  final String? vaccinatedAt;

  // weight
  final double? weightKg;
  final String? weighedAt;

  // routine
  final String? routineType; // bath | nail_trim | grooming
  final String? routineAt;

  const VoiceIntakeDraft({
    this.petId,
    this.petName,
    this.note,
    this.dewormingType,
    this.dewormedAt,
    this.vaccineName,
    this.vaccinatedAt,
    this.weightKg,
    this.weighedAt,
    this.routineType,
    this.routineAt,
  });

  factory VoiceIntakeDraft.fromJson(Map<String, dynamic> json) {
    final rawWeight = json['weight_kg'];
    double? weight;
    if (rawWeight is num) {
      weight = rawWeight.toDouble();
    } else if (rawWeight is String) {
      weight = double.tryParse(rawWeight);
    }
    return VoiceIntakeDraft(
      petId: json['pet_id'] as int?,
      petName: json['pet_name'] as String?,
      note: json['note'] as String?,
      dewormingType: json['deworming_type'] as String?,
      dewormedAt: json['dewormed_at'] as String?,
      vaccineName: json['vaccine_name'] as String?,
      vaccinatedAt: json['vaccinated_at'] as String?,
      weightKg: weight,
      weighedAt: json['weighed_at'] as String?,
      routineType: json['routine_type'] as String?,
      routineAt: json['routine_at'] as String?,
    );
  }
}

class VoiceIntakeResponse {
  final String requestId;
  final VoiceIntakeStatus status;
  final String? transcript;
  final VoiceIntent? intent;
  final int? confidence;
  final bool needsConfirm;
  final VoiceIntakeDraft? draft;
  final List<String> missingFields;

  const VoiceIntakeResponse({
    required this.requestId,
    required this.status,
    required this.transcript,
    required this.intent,
    required this.confidence,
    required this.needsConfirm,
    required this.draft,
    required this.missingFields,
  });

  factory VoiceIntakeResponse.fromJson(Map<String, dynamic> json) {
    return VoiceIntakeResponse(
      requestId: json['request_id'] as String,
      status: _statusFromString(json['status'] as String),
      transcript: json['transcript'] as String?,
      intent: voiceIntentFromString(json['intent'] as String?),
      confidence: json['confidence'] as int?,
      needsConfirm: (json['needs_confirm'] as bool?) ?? true,
      draft: json['draft'] == null
          ? null
          : VoiceIntakeDraft.fromJson(json['draft'] as Map<String, dynamic>),
      missingFields: (json['missing_fields'] as List<dynamic>? ?? [])
          .map((e) => e as String)
          .toList(),
    );
  }
}

class VoiceIntakeConfirmResult {
  final String requestId;
  final String entityType;
  final int entityId;
  final Map<String, dynamic> entity;

  const VoiceIntakeConfirmResult({
    required this.requestId,
    required this.entityType,
    required this.entityId,
    required this.entity,
  });

  factory VoiceIntakeConfirmResult.fromJson(Map<String, dynamic> json) {
    return VoiceIntakeConfirmResult(
      requestId: json['request_id'] as String,
      entityType: json['entity_type'] as String,
      entityId: json['entity_id'] as int,
      entity: (json['entity'] as Map).cast<String, dynamic>(),
    );
  }
}
