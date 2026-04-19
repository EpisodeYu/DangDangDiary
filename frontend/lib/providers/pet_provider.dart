import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/pet.dart';
import '../services/pet_service.dart';
import 'auth_provider.dart';

const _selectedPetIdKey = 'selected_pet_id';

final petServiceProvider = Provider<PetService>((ref) => PetService());

final petListProvider =
    AsyncNotifierProvider<PetListNotifier, PetListResult>(PetListNotifier.new);

class PetListNotifier extends AsyncNotifier<PetListResult> {
  @override
  Future<PetListResult> build() async {
    final authState = ref.watch(authProvider);
    if (authState.status != AuthStatus.authenticated) {
      return PetListResult(page: 1, pageSize: 0, total: 0, pets: []);
    }
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

  // Default to the earliest-added pet so newly created pets don't replace
  // the user's primary pet on the Record / Health pages. The list comes back
  // newest-first per API convention, but we still sort defensively in case
  // the order ever changes.
  Pet earliest = pets.first;
  for (final pet in pets) {
    if (pet.createdAt.compareTo(earliest.createdAt) < 0) {
      earliest = pet;
    }
  }
  return earliest;
});

final selectedTimelinePetIdsProvider = StateProvider<List<int>>((ref) => []);
