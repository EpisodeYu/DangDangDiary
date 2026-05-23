import 'package:dio/dio.dart';

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
