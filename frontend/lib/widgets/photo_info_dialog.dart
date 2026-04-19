import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/timeline.dart';

Future<void> showPhotoInfoDialog(
  BuildContext context,
  TimelinePhoto photo,
) {
  final uploader = (photo.uploaderNickname?.isNotEmpty ?? false)
      ? photo.uploaderNickname!
      : '用户${photo.uploaderId}';
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('照片详细信息'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('宠物', photo.petName),
          const SizedBox(height: 10),
          _row('来自', uploader),
          const SizedBox(height: 10),
          _row('上传时间', _formatUploadTime(photo.createdAt)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

Widget _row(String label, String value) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 72,
        child: Text(
          '$label：',
          style: const TextStyle(
            fontSize: 14,
            color: AppTheme.textSecondary,
          ),
        ),
      ),
      Expanded(
        child: Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            color: AppTheme.textPrimary,
          ),
        ),
      ),
    ],
  );
}

String _formatUploadTime(DateTime dt) {
  final local = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}
