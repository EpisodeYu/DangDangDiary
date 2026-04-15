import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';
import 'api_client.dart';

class AuthService {
  final _api = ApiClient();

  Future<void> sendCode(String phone) async {
    await _api.dio.post('/auth/send-code', data: {'phone': phone});
  }

  Future<({String accessToken, String refreshToken, User user})> login(
    String phone,
    String code,
  ) async {
    final resp = await _api.dio.post('/auth/login', data: {
      'phone': phone,
      'code': code,
    });
    final data = resp.data as Map<String, dynamic>;

    final accessToken = data['access_token'] as String;
    final refreshToken = data['refresh_token'] as String;
    final user = User.fromJson(data['user'] as Map<String, dynamic>);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', accessToken);
    await prefs.setString('refresh_token', refreshToken);

    return (accessToken: accessToken, refreshToken: refreshToken, user: user);
  }

  Future<String> refreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    final rt = prefs.getString('refresh_token');
    if (rt == null) throw Exception('No refresh token');

    final resp = await _api.dio.post('/auth/refresh', data: {
      'refresh_token': rt,
    });
    final newAccessToken = resp.data['access_token'] as String;
    await prefs.setString('access_token', newAccessToken);
    return newAccessToken;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    final rt = prefs.getString('refresh_token');
    if (rt != null) {
      try {
        await _api.dio.post('/auth/logout', data: {'refresh_token': rt});
      } catch (_) {
        // best-effort; server may reject if token already expired
      }
    }
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
  }

  Future<User> getMe() async {
    final resp = await _api.dio.get('/auth/me');
    return User.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<User> updateMe({required String nickname}) async {
    final resp = await _api.dio.put('/auth/me', data: {'nickname': nickname});
    return User.fromJson(resp.data as Map<String, dynamic>);
  }
}
