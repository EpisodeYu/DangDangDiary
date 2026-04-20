import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/pet.dart';

class PetSelector extends StatelessWidget {
  final bool multiSelect;
  final List<Pet> pets;
  final Pet? selectedPet;
  final List<int> selectedPetIds;
  final ValueChanged<Pet?>? onSingleChanged;
  final ValueChanged<List<int>>? onMultiChanged;

  const PetSelector({
    super.key,
    this.multiSelect = false,
    required this.pets,
    this.selectedPet,
    this.selectedPetIds = const [],
    this.onSingleChanged,
    this.onMultiChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (pets.isEmpty) {
      return const SizedBox.shrink();
    }

    if (multiSelect) {
      return _buildMultiSelect(context);
    }
    return _buildSingleSelect(context);
  }

  Widget _buildSingleSelect(BuildContext context) {
    return PopupMenuButton<int>(
      onSelected: (petId) {
        final pet = pets.firstWhere((p) => p.id == petId);
        onSingleChanged?.call(pet);
      },
      offset: const Offset(0, 40),
      itemBuilder: (ctx) => pets.map((pet) {
        final isSelected = selectedPet?.id == pet.id;
        return PopupMenuItem<int>(
          value: pet.id,
          height: 52,
          child: Row(
            children: [
              _buildPetAvatar(pet, 28),
              const SizedBox(width: 10),
              Expanded(child: Text(pet.name)),
              if (isSelected)
                const Icon(Icons.check, size: 18, color: AppTheme.primaryColor),
            ],
          ),
        );
      }).toList(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selectedPet != null) ...[
            _buildPetAvatar(selectedPet!, 24),
            const SizedBox(width: 8),
          ],
          Text(
            selectedPet?.name ?? '选择宠物',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_drop_down, color: AppTheme.textSecondary),
        ],
      ),
    );
  }

  Widget _buildMultiSelect(BuildContext context) {
    final allSelected = selectedPetIds.isEmpty;
    final singlePet = !allSelected && selectedPetIds.length == 1
        ? pets.firstWhere(
            (p) => p.id == selectedPetIds.first,
            orElse: () => pets.first,
          )
        : null;
    final displayText = allSelected
        ? '全部宠物'
        : (singlePet != null
            ? singlePet.name
            : '已选 ${selectedPetIds.length} 只');

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _openMultiSelectMenu(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (singlePet != null) ...[
              _buildPetAvatar(singlePet, 24),
              const SizedBox(width: 8),
            ],
            Text(
              displayText,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }

  Future<void> _openMultiSelectMenu(BuildContext context) async {
    final renderBox = context.findRenderObject();
    final overlayRender =
        Overlay.of(context).context.findRenderObject();
    if (renderBox is! RenderBox || overlayRender is! RenderBox) return;

    final buttonRect = Rect.fromPoints(
      renderBox.localToGlobal(Offset.zero, ancestor: overlayRender),
      renderBox.localToGlobal(
        renderBox.size.bottomRight(Offset.zero),
        ancestor: overlayRender,
      ),
    );
    final position =
        RelativeRect.fromRect(buttonRect, Offset.zero & overlayRender.size);

    // Empty selectedPetIds means "all"; expand to full set for a clear UI state.
    final draft = selectedPetIds.isEmpty
        ? pets.map((p) => p.id).toSet()
        : selectedPetIds.toSet();

    const rowHeight = 52.0;
    final listHeight =
        (pets.length * rowHeight).clamp(rowHeight, rowHeight * 5);

    final result = await showMenu<List<int>>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<List<int>>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: StatefulBuilder(
            builder: (ctx, setStateMenu) {
              final allChecked = draft.length == pets.length;
              void toggleAll() {
                setStateMenu(() {
                  if (allChecked) {
                    draft.clear();
                  } else {
                    draft
                      ..clear()
                      ..addAll(pets.map((p) => p.id));
                  }
                });
              }

              void togglePet(int id) {
                setStateMenu(() {
                  if (draft.contains(id)) {
                    draft.remove(id);
                  } else {
                    draft.add(id);
                  }
                });
              }

              return SizedBox(
                width: 260,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildCheckRow(
                      label: '全部',
                      leading: null,
                      checked: allChecked,
                      onTap: toggleAll,
                    ),
                    const Divider(height: 1),
                    SizedBox(
                      height: listHeight,
                      child: ListView.builder(
                        itemCount: pets.length,
                        itemExtent: rowHeight,
                        itemBuilder: (_, i) {
                          final pet = pets[i];
                          return _buildCheckRow(
                            label: pet.name,
                            leading: _buildPetAvatar(pet, 28),
                            checked: draft.contains(pet.id),
                            onTap: () => togglePet(pet.id),
                          );
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: draft.isEmpty
                                ? null
                                : () {
                                    // API treats empty list as "all"; collapse when every pet is chosen.
                                    final committed =
                                        draft.length == pets.length
                                            ? <int>[]
                                            : draft.toList();
                                    Navigator.of(ctx).pop(committed);
                                  },
                            child: const Text('确定'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );

    if (result != null) {
      onMultiChanged?.call(result);
    }
  }

  Widget _buildCheckRow({
    required String label,
    Widget? leading,
    required bool checked,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 22,
              color: checked ? AppTheme.primaryColor : AppTheme.textSecondary,
            ),
            const SizedBox(width: 12),
            if (leading != null) ...[
              leading,
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPetAvatar(Pet pet, double size) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.secondaryColor.withValues(alpha: 0.3),
      ),
      alignment: Alignment.center,
      child: Text(
        pet.petType == 'cat' ? '🐱' : '🐶',
        style: TextStyle(fontSize: size * 0.6),
      ),
    );
    final url = pet.avatarUrl;
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
