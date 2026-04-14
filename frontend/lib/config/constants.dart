class AppConstants {
  AppConstants._();

  /// Base URL for API calls — point to Nginx unified entry
  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'http://10.0.2.2', // Android emulator → host machine
  );

  static const String apiPrefix = '/api/v1';

  /// Page size for list APIs
  static const int defaultPageSize = 20;
}
