import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/pet.dart';

/// Compact chip that shows the auto-assigned pet for one photo, with a
/// tap-to-change affordance that opens a `PopupMenuButton` of every
/// pet the caller can write to (owner/editor).
///
/// States:
///   * [isRecognizing] = true  → spinner + 「识别中」 (non-interactive)
///   * [selected]      = null  → grey 「选择宠物」 pill
///   * [selected]      != null → avatar + name + caret
///
/// The chip background subtly marks whether the value is model-driven
/// ([wasAutoAssigned] = true → peach tint) or user-driven (grey) so
/// long lists of photos can be scanned at a glance.
class PetChipDropdown extends StatelessWidget {
  final List<Pet> pets;
  final Pet? selected;
  final bool isRecognizing;
  final bool wasAutoAssigned;
  final ValueChanged<Pet> onChanged;
  final bool enabled;

  const PetChipDropdown({
    super.key,
    required this.pets,
    required this.selected,
    required this.isRecognizing,
    required this.wasAutoAssigned,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (isRecognizing) {
      return _wrap(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            SizedBox(width: 6),
            Text(
              '识别中',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    final body = _wrap(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected != null) ...[
            _buildAvatar(selected!, 18),
            const SizedBox(width: 6),
            Text(
              selected!.name,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary,
              ),
            ),
          ] else
            const Text(
              '选择宠物',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
          const SizedBox(width: 2),
          const Icon(
            Icons.arrow_drop_down,
            size: 18,
            color: AppTheme.textSecondary,
          ),
        ],
      ),
    );

    if (!enabled || pets.isEmpty) {
      return Opacity(opacity: enabled ? 1 : 0.6, child: body);
    }

    return PopupMenuButton<int>(
      tooltip: '选择宠物',
      onSelected: (id) {
        final pet = pets.firstWhere(
          (p) => p.id == id,
          orElse: () => pets.first,
        );
        onChanged(pet);
      },
      itemBuilder: (ctx) => pets
          .map(
            (p) => PopupMenuItem<int>(
              value: p.id,
              child: Row(
                children: [
                  _buildAvatar(p, 22),
                  const SizedBox(width: 8),
                  Text(p.name),
                  if (selected?.id == p.id)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(
                        Icons.check,
                        size: 16,
                        color: AppTheme.primaryColor,
                      ),
                    ),
                ],
              ),
            ),
          )
          .toList(),
      child: body,
    );
  }

  Widget _wrap({required Widget child}) {
    final Color bg = wasAutoAssigned && selected != null
        ? AppTheme.primaryColor.withValues(alpha: 0.12)
        : Colors.grey.shade200;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  Widget _buildAvatar(Pet p, double size) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.secondaryColor.withValues(alpha: 0.3),
      ),
      alignment: Alignment.center,
      child: Text(
        p.petType == 'cat' ? '🐱' : '🐶',
        style: TextStyle(fontSize: size * 0.6),
      ),
    );
    final url = p.avatarUrl;
    if (url == null || url.isEmpty) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}
