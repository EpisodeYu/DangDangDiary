import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'app.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The default Flutter image cache (100 MiB / 1000 entries) is far too small
  // once we mix many timeline thumbnails with full-resolution originals: a
  // single decoded original can be 30–60 MiB, so even two of them wipe out
  // every thumbnail and force re-decodes on every scroll. Bumping the budget
  // keeps both kinds of images warm so scrolling and switching between
  // calendar/immersive views stops triggering visible reloads.
  PaintingBinding.instance.imageCache
    ..maximumSize = 600
    ..maximumSizeBytes = 512 * 1024 * 1024; // 512 MiB

  // Opt into the Android 13+ Photo Picker — it's the only Android gallery
  // path that actually enforces `pickMultiImage(limit: ...)`. The legacy
  // ACTION_GET_CONTENT intent (default) silently ignores the limit.
  if (defaultTargetPlatform == TargetPlatform.android) {
    final impl = ImagePickerPlatform.instance;
    if (impl is ImagePickerAndroid) {
      impl.useAndroidPhotoPicker = true;
    }
  }

  await NotificationService.instance.init();
  runApp(
    const ProviderScope(
      child: DangDangDiaryApp(),
    ),
  );
}
