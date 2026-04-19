import 'package:dio/dio.dart';

import '../models/pet.dart';
import '../models/share.dart';
import 'api_client.dart';

class ShareService {
  final Dio _dio = ApiClient().dio;

  Future<ShareCode> generateCode(int petId) async {
    final resp = await _dio.post('/pets/$petId/share-code');
    return ShareCode.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<ShareCode?> getActiveCode(int petId) async {
    final resp = await _dio.get(
      '/pets/$petId/share-code',
      options: Options(validateStatus: (s) => s == 200 || s == 204),
    );
    if (resp.statusCode == 204 || resp.data == null) return null;
    return ShareCode.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<void> revokeCode(int petId) async {
    await _dio.delete('/pets/$petId/share-code');
  }

  Future<Pet> redeemCode(String code) async {
    final resp = await _dio.post('/pets/redeem', data: {'code': code});
    return Pet.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<List<SharedMember>> listMembers(int petId) async {
    final resp = await _dio.get('/pets/$petId/members');
    final list = (resp.data as Map<String, dynamic>)['members'] as List<dynamic>;
    return list
        .map((e) => SharedMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<SharedMember> updateMemberRole(
    int petId,
    int userId,
    PetRole role,
  ) async {
    final resp = await _dio.patch(
      '/pets/$petId/members/$userId',
      data: {'role': petRoleApiValue(role)},
    );
    return SharedMember.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<void> removeMember(int petId, int userId) async {
    await _dio.delete('/pets/$petId/members/$userId');
  }
}

/// Maps share-related backend errors to user-friendly Chinese messages.
String shareErrorToMessage(Object error) {
  if (error is DioException && error.response?.data is Map) {
    final code = (error.response!.data as Map)['code'] as String?;
    switch (code) {
      case 'SHARE_CODE_NOT_FOUND':
        return '分享码不存在';
      case 'SHARE_CODE_EXPIRED':
        return '分享码已过期';
      case 'SHARE_CODE_USED':
        return '分享码已被使用';
      case 'SHARE_CODE_REVOKED':
        return '分享码已被撤回';
      case 'SHARE_CODE_SELF_REDEEM':
        return '不能添加自己的宠物档案';
      case 'SHARE_ALREADY_MEMBER':
        return '您已是该档案的共享成员';
      case 'SHARE_MEMBER_NOT_FOUND':
        return '该成员已不存在，请刷新重试';
      case 'SHARE_ROLE_INVALID':
        return '不允许此角色变更';
      case 'PET_OWNER_REQUIRED':
        return '仅档案所有者可执行此操作';
      case 'PET_EDITOR_REQUIRED':
        return '当前权限不足，无法执行';
      case 'SHARE_CODE_GENERATION_FAILED':
        return '分享码生成失败，请重试';
    }
  }
  return '操作失败，请稍后重试';
}
