class WeightRecord {
  final int id;
  final int petId;
  final int userId;
  final double weightKg;
  final String recordedAt;
  final String createdAt;

  const WeightRecord({
    required this.id,
    required this.petId,
    required this.userId,
    required this.weightKg,
    required this.recordedAt,
    required this.createdAt,
  });

  factory WeightRecord.fromJson(Map<String, dynamic> json) {
    final raw = json['weight_kg'];
    final value = raw is num ? raw.toDouble() : double.parse(raw.toString());
    return WeightRecord(
      id: json['id'] as int,
      petId: json['pet_id'] as int,
      userId: json['user_id'] as int,
      weightKg: value,
      recordedAt: json['recorded_at'] as String,
      createdAt: json['created_at'] as String,
    );
  }
}

class WeightListResult {
  final List<WeightRecord> weights;
  final int total;
  final int page;
  final int pageSize;
  final int totalPages;

  const WeightListResult({
    required this.weights,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.totalPages,
  });

  factory WeightListResult.fromJson(Map<String, dynamic> json) {
    return WeightListResult(
      weights: (json['weights'] as List<dynamic>)
          .map((e) => WeightRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int,
      page: json['page'] as int,
      pageSize: json['page_size'] as int,
      totalPages: json['total_pages'] as int,
    );
  }
}

enum DewormingTypeE { internal, external, combined }

extension DewormingTypeX on DewormingTypeE {
  String get apiValue {
    switch (this) {
      case DewormingTypeE.internal:
        return 'internal';
      case DewormingTypeE.external:
        return 'external';
      case DewormingTypeE.combined:
        return 'combined';
    }
  }

  String get label {
    switch (this) {
      case DewormingTypeE.internal:
        return '内驱';
      case DewormingTypeE.external:
        return '外驱';
      case DewormingTypeE.combined:
        return '内外同驱';
    }
  }

  static DewormingTypeE fromString(String raw) {
    switch (raw) {
      case 'internal':
        return DewormingTypeE.internal;
      case 'external':
        return DewormingTypeE.external;
      case 'combined':
        return DewormingTypeE.combined;
      default:
        throw ArgumentError('Unknown deworming type: $raw');
    }
  }
}

class DewormingRecord {
  final int id;
  final int petId;
  final int userId;
  final DewormingTypeE dewormingType;
  final String dewormedAt;
  final String createdAt;

  const DewormingRecord({
    required this.id,
    required this.petId,
    required this.userId,
    required this.dewormingType,
    required this.dewormedAt,
    required this.createdAt,
  });

  factory DewormingRecord.fromJson(Map<String, dynamic> json) {
    return DewormingRecord(
      id: json['id'] as int,
      petId: json['pet_id'] as int,
      userId: json['user_id'] as int,
      dewormingType: DewormingTypeX.fromString(json['deworming_type'] as String),
      dewormedAt: json['dewormed_at'] as String,
      createdAt: json['created_at'] as String,
    );
  }
}

class DewormingListResult {
  final List<DewormingRecord> dewormings;
  final int total;
  final int page;
  final int pageSize;
  final int totalPages;

  const DewormingListResult({
    required this.dewormings,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.totalPages,
  });

  factory DewormingListResult.fromJson(Map<String, dynamic> json) {
    return DewormingListResult(
      dewormings: (json['dewormings'] as List<dynamic>)
          .map((e) => DewormingRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int,
      page: json['page'] as int,
      pageSize: json['page_size'] as int,
      totalPages: json['total_pages'] as int,
    );
  }
}

class DewormingCycleConfig {
  final int? internalCycleDays;
  final int? externalCycleDays;
  final int? combinedCycleDays;
  final bool internalReminderEnabled;
  final bool externalReminderEnabled;
  final bool combinedReminderEnabled;

  const DewormingCycleConfig({
    this.internalCycleDays,
    this.externalCycleDays,
    this.combinedCycleDays,
    required this.internalReminderEnabled,
    required this.externalReminderEnabled,
    required this.combinedReminderEnabled,
  });

  factory DewormingCycleConfig.fromJson(Map<String, dynamic> json) {
    return DewormingCycleConfig(
      internalCycleDays: json['internal_cycle_days'] as int?,
      externalCycleDays: json['external_cycle_days'] as int?,
      combinedCycleDays: json['combined_cycle_days'] as int?,
      internalReminderEnabled: json['internal_reminder_enabled'] as bool,
      externalReminderEnabled: json['external_reminder_enabled'] as bool,
      combinedReminderEnabled: json['combined_reminder_enabled'] as bool,
    );
  }
}

class DewormingStatusItem {
  final bool reminderEnabled;
  final String? lastDewormedAt;
  final int? cycleDays;
  final String? nextDueAt;
  final int? daysRemaining;
  final bool? isOverdue;

  const DewormingStatusItem({
    required this.reminderEnabled,
    this.lastDewormedAt,
    this.cycleDays,
    this.nextDueAt,
    this.daysRemaining,
    this.isOverdue,
  });

  factory DewormingStatusItem.fromJson(Map<String, dynamic> json) {
    return DewormingStatusItem(
      reminderEnabled: json['reminder_enabled'] as bool,
      lastDewormedAt: json['last_dewormed_at'] as String?,
      cycleDays: json['cycle_days'] as int?,
      nextDueAt: json['next_due_at'] as String?,
      daysRemaining: json['days_remaining'] as int?,
      isOverdue: json['is_overdue'] as bool?,
    );
  }
}

class DewormingStatus {
  final DewormingStatusItem internal;
  final DewormingStatusItem external;
  final DewormingStatusItem combined;

  const DewormingStatus({
    required this.internal,
    required this.external,
    required this.combined,
  });

  factory DewormingStatus.fromJson(Map<String, dynamic> json) {
    return DewormingStatus(
      internal: DewormingStatusItem.fromJson(json['internal'] as Map<String, dynamic>),
      external: DewormingStatusItem.fromJson(json['external'] as Map<String, dynamic>),
      combined: DewormingStatusItem.fromJson(json['combined'] as Map<String, dynamic>),
    );
  }

  DewormingStatusItem itemOf(DewormingTypeE type) {
    switch (type) {
      case DewormingTypeE.internal:
        return internal;
      case DewormingTypeE.external:
        return external;
      case DewormingTypeE.combined:
        return combined;
    }
  }
}

class VaccinationRecord {
  final int id;
  final int petId;
  final int userId;
  final String vaccineType;
  final String vaccinatedAt;
  final String createdAt;

  const VaccinationRecord({
    required this.id,
    required this.petId,
    required this.userId,
    required this.vaccineType,
    required this.vaccinatedAt,
    required this.createdAt,
  });

  factory VaccinationRecord.fromJson(Map<String, dynamic> json) {
    return VaccinationRecord(
      id: json['id'] as int,
      petId: json['pet_id'] as int,
      userId: json['user_id'] as int,
      vaccineType: json['vaccine_type'] as String,
      vaccinatedAt: json['vaccinated_at'] as String,
      createdAt: json['created_at'] as String,
    );
  }
}

class VaccinationListResult {
  final List<VaccinationRecord> vaccinations;
  final int total;
  final int page;
  final int pageSize;
  final int totalPages;

  const VaccinationListResult({
    required this.vaccinations,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.totalPages,
  });

  factory VaccinationListResult.fromJson(Map<String, dynamic> json) {
    return VaccinationListResult(
      vaccinations: (json['vaccinations'] as List<dynamic>)
          .map((e) => VaccinationRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int,
      page: json['page'] as int,
      pageSize: json['page_size'] as int,
      totalPages: json['total_pages'] as int,
    );
  }
}
