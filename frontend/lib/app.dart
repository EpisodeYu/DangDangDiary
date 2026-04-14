import 'package:flutter/material.dart';

import 'config/theme.dart';
import 'config/router.dart';

class DangDangDiaryApp extends StatelessWidget {
  const DangDangDiaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '当当日记',
      theme: AppTheme.lightTheme,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
