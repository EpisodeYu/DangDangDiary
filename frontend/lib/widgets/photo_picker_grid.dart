import 'dart:io';

import 'package:flutter/material.dart';

import '../config/theme.dart';

class PhotoPickerGrid extends StatelessWidget {
  final List<File> selectedFiles;
  final Map<int, String> failureMessages;
  final int maxCount;
  final bool enabled;
  final VoidCallback onAddTap;
  final ValueChanged<int> onRemoveTap;

  const PhotoPickerGrid({
    super.key,
    required this.selectedFiles,
    this.failureMessages = const {},
    this.maxCount = 5,
    this.enabled = true,
    required this.onAddTap,
    required this.onRemoveTap,
  });

  @override
  Widget build(BuildContext context) {
    final showAddButton = selectedFiles.length < maxCount && enabled;
    final itemCount = selectedFiles.length + (showAddButton ? 1 : 0);

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < selectedFiles.length) {
          return _buildPhotoItem(index);
        }
        return _buildAddButton();
      },
    );
  }

  Widget _buildPhotoItem(int index) {
    final file = selectedFiles[index];
    final failureMsg = failureMessages[index];

    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            file,
            fit: BoxFit.cover,
            cacheWidth: 300,
          ),
        ),
        if (failureMsg != null)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.errorColor.withValues(alpha: 0.85),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
              ),
              child: Text(
                failureMsg,
                style: const TextStyle(color: Colors.white, fontSize: 10),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        if (enabled)
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: () => onRemoveTap(index),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.close_rounded, size: 14, color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAddButton() {
    return GestureDetector(
      onTap: enabled ? onAddTap : null,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade300, width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, size: 32, color: Colors.grey.shade500),
            const SizedBox(height: 4),
            Text(
              '添加照片',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }
}
