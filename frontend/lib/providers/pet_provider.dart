import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/pet.dart';
import '../services/pet_service.dart';

const _selectedPetIdKey = 'selected_pet_id';

final petServiceProvider = Provider<PetService>((ref) => PetService());

final petListProvider =
    AsyncNotifierProvider<PetListNotifier, PetListResult>(PetListNotifier.new);

class PetListNotifier extends AsyncNotifier<PetListResult> {
  @override
  Future<PetListResult> build() async {
    final service = ref.read(petServiceProvider);
    return await service.getPets(page: 1, pageSize: 100);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(petServiceProvider);
      return await service.getPets(page: 1, pageSize: 100);
    });
  }
}

final selectedPetIdProvider =
    StateNotifierProvider<SelectedPetIdNotifier, int?>(
  (ref) => SelectedPetIdNotifier(),
);

class SelectedPetIdNotifier extends StateNotifier<int?> {
  SelectedPetIdNotifier() : super(null) {
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_selectedPetIdKey);
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> select(int? petId) async {
    state = petId;
    final prefs = await SharedPreferences.getInstance();
    if (petId != null) {
      await prefs.setInt(_selectedPetIdKey, petId);
    } else {
      await prefs.remove(_selectedPetIdKey);
    }
  }
}

final selectedPetProvider = Provider<Pet?>((ref) {
  final selectedId = ref.watch(selectedPetIdProvider);
  final petListAsync = ref.watch(petListProvider);
  final pets = petListAsync.valueOrNull?.pets ?? const <Pet>[];

  if (pets.isEmpty) return null;

  if (selectedId != null) {
    for (final pet in pets) {
      if (pet.id == selectedId) return pet;
    }
  }

  return pets.first;
});

final selectedTimelinePetIdsProvider = StateProvider<List<int>>((ref) => []);
