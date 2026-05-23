import 'package:dio/dio.dart';

import '../models/pet.dart';

/// Returns `true` when [error] represents a permission denial — either
/// because the backend returned one of the structured share-permission
/// error codes (`PET_EDITOR_REQUIRED`, `PET_OWNER_REQUIRED`) or because
/// the HTTP status is plain `403`.
///
/// Centralised here so every write path can do the same "soft refresh
/// + tell the user to retry" recovery without each screen re-deriving
/// the same condition. Added in Optimization Step 4.
bool isPermissionError(Object error) {
  if (error is! DioException) return false;
  final data = error.response?.data;
  if (data is Map) {
    final code = data['code'];
    if (code == 'PET_EDITOR_REQUIRED' || code == 'PET_OWNER_REQUIRED') {
      return true;
    }
  }
  return error.response?.statusCode == 403;
}

/// Pick the right user-facing copy after a write-path 403.
///
/// Call this **after** awaiting `petListProvider.silentRefresh()` so
/// [roleAfterRefresh] reflects the server-truth role, not the stale
/// role the original click was made under.
///
/// - When the post-refresh role can write (`owner` / `editor`) the 403
///   was a transient race (e.g. the owner had just demoted and
///   re-promoted the user in the time between fetching the photo and
///   clicking delete). Returning "权限已更新，请重试" tells the user
///   that another attempt should now succeed.
/// - When the post-refresh role is `viewer` (or the pet is no longer
///   accessible at all and [roleAfterRefresh] is `null`), the user
///   genuinely can't perform the action — return [deniedLabel], which
///   the caller customises per action ("无删除权限" / "无编辑权限"
///   / "无上传权限") so the user understands what's blocked.
///
/// Added in the realdevice-fix follow-up to step 4 — the original
/// implementation hard-coded "权限已更新，请重试" for both cases, which
/// looked stuck to viewers since every retry still 403'd.
String permissionErrorMessage(
  PetRole? roleAfterRefresh, {
  required String deniedLabel,
}) {
  if (roleAfterRefresh == PetRole.owner ||
      roleAfterRefresh == PetRole.editor) {
    return '权限已更新，请重试';
  }
  return deniedLabel;
}
