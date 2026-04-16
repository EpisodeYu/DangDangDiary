import 'dart:io';

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';

class ExifHelper {
  ExifHelper._();

  static Future<DateTime?> extractDate(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final data = await readExifFromBytes(bytes);
      if (data.isEmpty) return null;

      for (final tag in ['EXIF DateTimeOriginal', 'EXIF DateTimeDigitized', 'Image DateTime']) {
        final value = data[tag];
        if (value != null) {
          final parsed = _parseExifDateTime(value.toString());
          if (parsed != null) return parsed;
        }
      }
      return null;
    } catch (e) {
      debugPrint('[EXIF] Failed to read EXIF from ${imageFile.path}: $e');
      return null;
    }
  }

  static Future<DateTime?> extractFirstValidDate(List<File> files) async {
    for (final file in files) {
      final date = await extractDate(file);
      if (date != null) return date;
    }
    return null;
  }

  /// Parses EXIF datetime strings like "2024:01:15 10:30:00"
  static DateTime? _parseExifDateTime(String raw) {
    try {
      final cleaned = raw.trim();
      if (cleaned.isEmpty || cleaned == '0000:00:00 00:00:00') return null;

      // EXIF uses "YYYY:MM:DD HH:MM:SS"
      final parts = cleaned.split(' ');
      if (parts.isEmpty) return null;

      final dateParts = parts[0].split(':');
      if (dateParts.length < 3) return null;

      final year = int.parse(dateParts[0]);
      final month = int.parse(dateParts[1]);
      final day = int.parse(dateParts[2]);

      if (year < 1900 || month < 1 || month > 12 || day < 1 || day > 31) return null;

      return DateTime(year, month, day);
    } catch (_) {
      return null;
    }
  }
}
