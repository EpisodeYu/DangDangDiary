import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../models/pet.dart';
import '../../providers/pet_provider.dart';

class PetManageScreen extends ConsumerWidget {
  const PetManageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final petListAsync = ref.watch(petListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('宠物档案管理')),
      body: petListAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('加载失败: $err'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.read(petListProvider.notifier).refresh(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (result) => _buildBody(context, ref, result.pets),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, List<Pet> pets) {
    return Column(
      children: [
        Expanded(
          child: pets.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.pets, size: 64, color: AppTheme.textSecondary),
                      SizedBox(height: 16),
                      Text('还没有宠物档案', style: TextStyle(color: AppTheme.textSecondary)),
                      SizedBox(height: 8),
                      Text('点击下方按钮添加你的第一只宠物', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => ref.read(petListProvider.notifier).refresh(),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: pets.length,
                    itemBuilder: (context, index) => _buildPetCard(context, ref, pets[index]),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: () async {
                final created = await context.push<bool>('/profile/pets/new');
                if (created == true) {
                  ref.read(petListProvider.notifier).refresh();
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('添加宠物'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPetCard(BuildContext context, WidgetRef ref, Pet pet) {
    return Dismissible(
      key: ValueKey(pet.id),
      direction: pet.isOwner ? DismissDirection.endToStart : DismissDirection.none,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppTheme.errorColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) => _deletePet(context, ref, pet.id),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            if (pet.isOwner) {
              final updated = await context.push<bool>('/profile/pets/${pet.id}/edit');
              if (updated == true) {
                ref.read(petListProvider.notifier).refresh();
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _buildAvatar(pet),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              pet.name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ),
                          if (!pet.isOwner)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.textSecondary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                '共享',
                                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      if (pet.breed != null && pet.breed!.isNotEmpty)
                        Text(
                          pet.breed!,
                          style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
                        ),
                      if (_formatAge(pet.birthday) != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _formatAge(pet.birthday)!,
                            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                          ),
                        ),
                    ],
                  ),
                ),
                if (pet.isOwner)
                  const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _formatAge(String? birthday) {
    if (birthday == null || birthday.isEmpty) return null;
    final birth = DateTime.tryParse(birthday);
    if (birth == null) return null;

    final now = DateTime.now();
    if (!now.isAfter(birth)) return '0天';

    int years = now.year - birth.year;
    int months = now.month - birth.month;
    int days = now.day - birth.day;

    if (days < 0) {
      months -= 1;
      // Day 0 of the current month equals the last day of the previous month.
      days += DateTime(now.year, now.month, 0).day;
    }
    if (months < 0) {
      years -= 1;
      months += 12;
    }

    if (years > 0) return '$years年$months个月$days天';
    if (months > 0) return '$months个月$days天';
    return '$days天';
  }

  Widget _buildAvatar(Pet pet) {
    final isCat = pet.petType == 'cat';
    if (pet.avatarUrl != null && pet.avatarUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: 28,
        backgroundImage: NetworkImage(pet.avatarUrl!),
      );
    }
    return CircleAvatar(
      radius: 28,
      backgroundColor: AppTheme.secondaryColor.withValues(alpha: 0.3),
      child: Text(
        isCat ? '🐱' : '🐶',
        style: const TextStyle(fontSize: 24),
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除宠物档案'),
        content: const Text('删除后将清除该宠物的所有数据，包括照片、体重、驱虫和疫苗记录。此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorColor),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _deletePet(BuildContext context, WidgetRef ref, int petId) async {
    try {
      await ref.read(petServiceProvider).deletePet(petId);

      final selectedId = ref.read(selectedPetIdProvider);
      if (selectedId == petId) {
        ref.read(selectedPetIdProvider.notifier).select(null);
      }
      ref.read(petListProvider.notifier).refresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }
}
