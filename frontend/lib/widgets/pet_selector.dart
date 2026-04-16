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
          child: Row(
            children: [
              Text(
                pet.petType == 'cat' ? '🐱' : '🐶',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(width: 8),
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
    final displayText = allSelected
        ? '全部宠物'
        : (selectedPetIds.length == 1
            ? pets.firstWhere((p) => p.id == selectedPetIds.first, orElse: () => pets.first).name
            : '已选 ${selectedPetIds.length} 只');

    return PopupMenuButton<String>(
      onSelected: (value) {
        if (value == 'all') {
          onMultiChanged?.call([]);
          return;
        }
        final petId = int.parse(value);
        final newIds = List<int>.from(selectedPetIds);
        if (newIds.contains(petId)) {
          newIds.remove(petId);
        } else {
          newIds.add(petId);
        }
        if (newIds.length == pets.length) {
          onMultiChanged?.call([]);
        } else {
          onMultiChanged?.call(newIds);
        }
      },
      offset: const Offset(0, 40),
      itemBuilder: (ctx) {
        final items = <PopupMenuEntry<String>>[];
        items.add(
          PopupMenuItem<String>(
            value: 'all',
            child: Row(
              children: [
                Icon(
                  allSelected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 20,
                  color: allSelected ? AppTheme.primaryColor : AppTheme.textSecondary,
                ),
                const SizedBox(width: 8),
                const Text('全部'),
              ],
            ),
          ),
        );
        for (final pet in pets) {
          final checked = allSelected || selectedPetIds.contains(pet.id);
          items.add(
            PopupMenuItem<String>(
              value: pet.id.toString(),
              child: Row(
                children: [
                  Icon(
                    checked ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 20,
                    color: checked ? AppTheme.primaryColor : AppTheme.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Text(pet.petType == 'cat' ? '🐱' : '🐶'),
                  const SizedBox(width: 4),
                  Expanded(child: Text(pet.name)),
                ],
              ),
            ),
          );
        }
        return items;
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
    );
  }
}
