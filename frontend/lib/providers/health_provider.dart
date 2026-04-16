import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/health.dart';
import '../services/health_service.dart';

final healthServiceProvider = Provider<HealthService>((ref) => HealthService());

// ---------------- Weight ----------------

final weightListProvider =
    FutureProvider.family.autoDispose<WeightListResult, int>((ref, petId) async {
  final service = ref.watch(healthServiceProvider);
  return service.getWeights(petId);
});

// ---------------- Deworming ----------------

final dewormingListProvider =
    FutureProvider.family.autoDispose<DewormingListResult, int>((ref, petId) async {
  final service = ref.watch(healthServiceProvider);
  return service.getDewormings(petId);
});

final dewormingStatusProvider =
    FutureProvider.family.autoDispose<DewormingStatus, int>((ref, petId) async {
  final service = ref.watch(healthServiceProvider);
  return service.getDewormingStatus(petId);
});

// ---------------- Vaccination ----------------

final vaccinationListProvider =
    FutureProvider.family.autoDispose<VaccinationListResult, int>((ref, petId) async {
  final service = ref.watch(healthServiceProvider);
  return service.getVaccinations(petId);
});

final vaccineTypesProvider =
    FutureProvider.family.autoDispose<List<String>, String>((ref, petType) async {
  final service = ref.watch(healthServiceProvider);
  return service.getVaccineTypes(petType);
});
