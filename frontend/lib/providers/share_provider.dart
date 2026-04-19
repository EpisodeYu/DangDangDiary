import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/pet.dart';
import '../models/share.dart';
import '../services/share_service.dart';

final shareServiceProvider = Provider<ShareService>((_) => ShareService());

final shareCodeProvider =
    AsyncNotifierProvider.family<ShareCodeNotifier, ShareCode?, int>(
  ShareCodeNotifier.new,
);

class ShareCodeNotifier extends FamilyAsyncNotifier<ShareCode?, int> {
  @override
  Future<ShareCode?> build(int petId) {
    return ref.read(shareServiceProvider).getActiveCode(petId);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() {
      return ref.read(shareServiceProvider).getActiveCode(arg);
    });
  }

  Future<void> regenerate() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      return await ref.read(shareServiceProvider).generateCode(arg);
    });
  }

  Future<void> revoke() async {
    await ref.read(shareServiceProvider).revokeCode(arg);
    state = const AsyncData(null);
  }
}

final sharedMembersProvider =
    AsyncNotifierProvider.family<SharedMembersNotifier, List<SharedMember>, int>(
  SharedMembersNotifier.new,
);

class SharedMembersNotifier
    extends FamilyAsyncNotifier<List<SharedMember>, int> {
  @override
  Future<List<SharedMember>> build(int petId) {
    return ref.read(shareServiceProvider).listMembers(petId);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() {
      return ref.read(shareServiceProvider).listMembers(arg);
    });
  }

  Future<void> updateRole(int userId, PetRole role) async {
    await ref.read(shareServiceProvider).updateMemberRole(arg, userId, role);
    await refresh();
  }

  Future<void> remove(int userId) async {
    await ref.read(shareServiceProvider).removeMember(arg, userId);
    await refresh();
  }
}
