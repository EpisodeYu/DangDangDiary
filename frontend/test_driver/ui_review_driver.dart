import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      final dir = Directory('build/ui-native-review');
      await dir.create(recursive: true);
      await File('${dir.path}/$name.png').writeAsBytes(bytes);
      return true;
    },
  );
}
