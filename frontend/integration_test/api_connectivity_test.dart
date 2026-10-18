import 'package:dangdang_diary/config/constants.dart';
import 'package:dangdang_diary/services/api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Opt-in live connectivity check. Uses the app's real HTTP client and Android
// network configuration, without a user token, SMS request or server writes.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('configured backend responds to an unauthenticated Android GET', (
    tester,
  ) async {
    expect(const String.fromEnvironment('BASE_URL'), isNotEmpty);
    SharedPreferences.setMockInitialValues({});

    final response = await ApiClient().dio.get<Map<String, dynamic>>(
      '/auth/me',
      options: Options(validateStatus: (_) => true),
    );

    expect(
      response.realUri.toString(),
      '${AppConstants.baseUrl}${AppConstants.apiPrefix}/auth/me',
    );
    expect(response.statusCode, 401);
    expect(response.data?['code'], 'INVALID_ACCESS_TOKEN');
    expect(response.data?['message'], '未提供访问令牌');
  });
}
