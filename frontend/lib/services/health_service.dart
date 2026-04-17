import 'package:dio/dio.dart';

import '../models/health.dart';
import 'api_client.dart';

class HealthService {
  final Dio _dio = ApiClient().dio;

  // ---------------- Weight ----------------

  Future<WeightListResult> getWeights(int petId, {int page = 1, int pageSize = 50}) async {
    final resp = await _dio.get(
      '/pets/$petId/weights',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    return WeightListResult.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<WeightRecord> createWeight(int petId, {
    required double weightKg,
    required String recordedAt,
  }) async {
    final resp = await _dio.post(
      '/pets/$petId/weights',
      data: {
        'weight_kg': weightKg,
        'recorded_at': recordedAt,
      },
    );
    return WeightRecord.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<WeightRecord> updateWeight(int weightId, {
    required double weightKg,
    required String recordedAt,
  }) async {
    final resp = await _dio.put(
      '/weights/$weightId',
      data: {
        'weight_kg': weightKg,
        'recorded_at': recordedAt,
      },
    );
    return WeightRecord.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<void> deleteWeight(int weightId) async {
    await _dio.delete('/weights/$weightId');
  }

  // ---------------- Deworming ----------------

  Future<DewormingListResult> getDewormings(int petId, {int page = 1, int pageSize = 50}) async {
    final resp = await _dio.get(
      '/pets/$petId/dewormings',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    return DewormingListResult.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<DewormingRecord> createDeworming(int petId, {
    required DewormingTypeE dewormingType,
    required String dewormedAt,
  }) async {
    final resp = await _dio.post(
      '/pets/$petId/dewormings',
      data: {
        'deworming_type': dewormingType.apiValue,
        'dewormed_at': dewormedAt,
      },
    );
    return DewormingRecord.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<DewormingRecord> updateDeworming(int dewormingId, {
    required DewormingTypeE dewormingType,
    required String dewormedAt,
  }) async {
    final resp = await _dio.put(
      '/dewormings/$dewormingId',
      data: {
        'deworming_type': dewormingType.apiValue,
        'dewormed_at': dewormedAt,
      },
    );
    return DewormingRecord.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<void> deleteDeworming(int dewormingId) async {
    await _dio.delete('/dewormings/$dewormingId');
  }

  Future<DewormingCycleConfig> updateDewormingCycle(int petId, {
    int? internalCycleDays,
    int? externalCycleDays,
    int? combinedCycleDays,
    bool? internalReminderEnabled,
    bool? externalReminderEnabled,
    bool? combinedReminderEnabled,
  }) async {
    final body = <String, dynamic>{};
    if (internalCycleDays != null) body['internal_cycle_days'] = internalCycleDays;
    if (externalCycleDays != null) body['external_cycle_days'] = externalCycleDays;
    if (combinedCycleDays != null) body['combined_cycle_days'] = combinedCycleDays;
    if (internalReminderEnabled != null) body['internal_reminder_enabled'] = internalReminderEnabled;
    if (externalReminderEnabled != null) body['external_reminder_enabled'] = externalReminderEnabled;
    if (combinedReminderEnabled != null) body['combined_reminder_enabled'] = combinedReminderEnabled;

    final resp = await _dio.put('/pets/$petId/deworming-cycle', data: body);
    return DewormingCycleConfig.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<DewormingStatus> getDewormingStatus(int petId) async {
    final resp = await _dio.get('/pets/$petId/deworming-status');
    return DewormingStatus.fromJson(resp.data as Map<String, dynamic>);
  }

  // ---------------- Vaccination ----------------

  Future<VaccinationListResult> getVaccinations(int petId, {int page = 1, int pageSize = 50}) async {
    final resp = await _dio.get(
      '/pets/$petId/vaccinations',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    return VaccinationListResult.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<VaccinationRecord> createVaccination(int petId, {
    required String vaccineType,
    required String vaccinatedAt,
  }) async {
    final resp = await _dio.post(
      '/pets/$petId/vaccinations',
      data: {
        'vaccine_type': vaccineType,
        'vaccinated_at': vaccinatedAt,
      },
    );
    return VaccinationRecord.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<VaccinationRecord> updateVaccination(int vaccinationId, {
    required String vaccineType,
    required String vaccinatedAt,
  }) async {
    final resp = await _dio.put(
      '/vaccinations/$vaccinationId',
      data: {
        'vaccine_type': vaccineType,
        'vaccinated_at': vaccinatedAt,
      },
    );
    return VaccinationRecord.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<void> deleteVaccination(int vaccinationId) async {
    await _dio.delete('/vaccinations/$vaccinationId');
  }

  Future<List<String>> getVaccineTypes(String petType) async {
    final resp = await _dio.get(
      '/vaccine-types',
      queryParameters: {'pet_type': petType},
    );
    final data = resp.data as Map<String, dynamic>;
    return (data['preset_types'] as List<dynamic>).map((e) => e as String).toList();
  }

  // ---------------- Routine ----------------

  Future<RoutineListResult> getRoutines(int petId, {int page = 1, int pageSize = 50}) async {
    final resp = await _dio.get(
      '/pets/$petId/routines',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    return RoutineListResult.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<RoutineRecord> createRoutine(int petId, {
    required RoutineTypeE routineType,
    required String performedAt,
  }) async {
    final resp = await _dio.post(
      '/pets/$petId/routines',
      data: {
        'routine_type': routineType.apiValue,
        'performed_at': performedAt,
      },
    );
    return RoutineRecord.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<RoutineRecord> updateRoutine(int routineId, {
    required RoutineTypeE routineType,
    required String performedAt,
  }) async {
    final resp = await _dio.put(
      '/routines/$routineId',
      data: {
        'routine_type': routineType.apiValue,
        'performed_at': performedAt,
      },
    );
    return RoutineRecord.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<void> deleteRoutine(int routineId) async {
    await _dio.delete('/routines/$routineId');
  }

  Future<RoutineCycleConfig> updateRoutineCycle(int petId, {
    int? bathCycleDays,
    int? nailTrimCycleDays,
    int? groomingCycleDays,
    bool? bathReminderEnabled,
    bool? nailTrimReminderEnabled,
    bool? groomingReminderEnabled,
  }) async {
    final body = <String, dynamic>{};
    if (bathCycleDays != null) body['bath_cycle_days'] = bathCycleDays;
    if (nailTrimCycleDays != null) body['nail_trim_cycle_days'] = nailTrimCycleDays;
    if (groomingCycleDays != null) body['grooming_cycle_days'] = groomingCycleDays;
    if (bathReminderEnabled != null) body['bath_reminder_enabled'] = bathReminderEnabled;
    if (nailTrimReminderEnabled != null) body['nail_trim_reminder_enabled'] = nailTrimReminderEnabled;
    if (groomingReminderEnabled != null) body['grooming_reminder_enabled'] = groomingReminderEnabled;

    final resp = await _dio.put('/pets/$petId/routine-cycle', data: body);
    return RoutineCycleConfig.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<RoutineStatus> getRoutineStatus(int petId) async {
    final resp = await _dio.get('/pets/$petId/routine-status');
    return RoutineStatus.fromJson(resp.data as Map<String, dynamic>);
  }
}
