import 'package:flutter/foundation.dart';
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
  /// True when [silentRefresh] is currently in flight. Used to dedupe
  /// near-simultaneous triggers (e.g. App.resumed + PetEditScreen.init
  /// firing in the same frame). Reset in `finally`.
  bool _silentRefreshInFlight = false;

  @override
  Future<PetListResult> build() async {
    final authState = ref.watch(authProvider);
    if (authState.status != AuthStatus.authenticated) {
      return PetListResult(page: 1, pageSize: 0, total: 0, pets: []);
    }
    final service = ref.read(petServiceProvider);
    return await service.getPets(page: 1, pageSize: 100);
  }

  /// Hard refresh: flip `state` to `AsyncLoading` then fetch. Use this
  /// only for *user-initiated* refreshes (pull-to-refresh, after the
  /// user just saved / deleted a pet, after redeem) where a spinner is
  /// expected and reinforces "I just did something".
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(petServiceProvider);
      return await service.getPets(page: 1, pageSize: 100);
    });
  }

  /// Silent refresh: background fetch that **never enters
  /// `AsyncLoading`**. Only replaces `state` when the fresh result
  /// differs from the current one (see [_petListResultEquals] for the
  /// diff fields), so consumers that depend on `pet.role` /
  /// `share_code_active` / etc. observe an in-place update instead of
  /// a loading→data flicker.
  ///
  /// Triggered by:
  ///   - PetEditScreen.initState (so the role badge reflects the
  ///     newest decision from the owner)
  ///   - PetManageScreen.initState
  ///   - App lifecycle resumed (lib/app.dart)
  ///   - Any write that returns 403 / PET_EDITOR_REQUIRED, via
  ///     `lib/utils/api_error.dart`
  ///
  /// Silent failures are intentional: a network blip should not pop a
  /// SnackBar in the user's face; the next trigger will retry.
  Future<void> silentRefresh() async {
    if (_silentRefreshInFlight) return;
    final authState = ref.read(authProvider);
    if (authState.status != AuthStatus.authenticated) return;
    _silentRefreshInFlight = true;
    try {
      final service = ref.read(petServiceProvider);
      final fresh = await service.getPets(page: 1, pageSize: 100);
      final current = state.valueOrNull;
      if (current == null) {
        // initial build() is still racing — let it finish on its own
        // path rather than over-write with a parallel result.
        return;
      }
      if (_petListResultEquals(current, fresh)) {
        if (kDebugMode) {
          debugPrint('[petListProvider] silentRefresh: no diff');
        }
        return;
      }
      if (kDebugMode) {
        debugPrint('[petListProvider] silentRefresh: applied diff');
      }
      state = AsyncData(fresh);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          '[petListProvider] silentRefresh failed (ignored): $e\n$st',
        );
      }
    } finally {
      _silentRefreshInFlight = false;
    }
  }
}

/// Field-by-field equality used by [PetListNotifier.silentRefresh] to
/// decide whether the new fetch warrants replacing `state`. Only
/// "display-affecting" fields are compared — anything the local user
/// can change without going through the network would be live-updated
/// elsewhere anyway.
///
/// IMPORTANT: keep this list in sync with `Pet.fromJson` whenever a new
/// visible field is added, otherwise silentRefresh will silently miss
/// the change.
bool _petListResultEquals(PetListResult a, PetListResult b) {
  if (a.total != b.total) return false;
  if (a.pets.length != b.pets.length) return false;
  // Backend returns pets in stable order (newest created first); we
  // rely on positional alignment here. If the order ever changes,
  // sort both sides by id before comparing.
  for (var i = 0; i < a.pets.length; i++) {
    final pa = a.pets[i];
    final pb = b.pets[i];
    if (pa.id != pb.id) return false;
    if (pa.name != pb.name) return false;
    if (pa.petType != pb.petType) return false;
    if (pa.breed != pb.breed) return false;
    if (pa.birthday != pb.birthday) return false;
    if (pa.avatarUrl != pb.avatarUrl) return false;
    if (pa.isOwner != pb.isOwner) return false;
    if (pa.myRole != pb.myRole) return false;
    if (pa.shareCodeActive != pb.shareCodeActive) return false;
    if (pa.updatedAt != pb.updatedAt) return false;
    // Reminder cycle fields can change on another device of the same
    // owner; include them so multi-device owners stay in sync.
    if (pa.internalDewormingCycleDays != pb.internalDewormingCycleDays) {
      return false;
    }
    if (pa.externalDewormingCycleDays != pb.externalDewormingCycleDays) {
      return false;
    }
    if (pa.combinedDewormingCycleDays != pb.combinedDewormingCycleDays) {
      return false;
    }
    if (pa.bathCycleDays != pb.bathCycleDays) return false;
    if (pa.nailTrimCycleDays != pb.nailTrimCycleDays) return false;
    if (pa.groomingCycleDays != pb.groomingCycleDays) return false;
    if (pa.internalReminderEnabled != pb.internalReminderEnabled) return false;
    if (pa.externalReminderEnabled != pb.externalReminderEnabled) return false;
    if (pa.combinedReminderEnabled != pb.combinedReminderEnabled) return false;
    if (pa.bathReminderEnabled != pb.bathReminderEnabled) return false;
    if (pa.nailTrimReminderEnabled != pb.nailTrimReminderEnabled) return false;
    if (pa.groomingReminderEnabled != pb.groomingReminderEnabled) return false;
  }
  return true;
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
