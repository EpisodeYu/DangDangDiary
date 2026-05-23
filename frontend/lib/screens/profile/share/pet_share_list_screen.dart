import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/theme.dart';
import '../../../models/pet.dart';
import '../../../providers/pet_provider.dart';
import '../../../widgets/app_card.dart';
import '../../../widgets/skeleton.dart';

class PetShareListScreen extends ConsumerWidget {
  const PetShareListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final petListAsync = ref.watch(petListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('宠物档案分享')),
      body: petListAsync.when(
        loading: () => const SkeletonGenericList(rows: 4),
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
        data: (result) {
          final ownedPets = result.pets.where((p) => p.isOwner).toList();
          if (ownedPets.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.ios_share_rounded,
                        size: 64, color: AppTheme.textSecondary),
                    const SizedBox(height: 16),
                    const Text(
                      '还没有自己创建的宠物档案',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 15),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '分享功能仅对您拥有的宠物可用',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                    ),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.read(petListProvider.notifier).refresh(),
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: ownedPets.length,
              itemBuilder: (context, index) =>
                  _buildPetCard(context, ownedPets[index]),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPetCard(BuildContext context, Pet pet) {
    return AppCard(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      onTap: () => context.push('/profile/pets/${pet.id}/share'),
      child: Row(
        children: [
          _buildAvatar(pet),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pet.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                if (pet.shareCodeActive) ...[
                  const SizedBox(height: 4),
                  const Text(
                    '当前有有效分享码',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.primaryColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: AppTheme.textSecondary),
        ],
      ),
    );
  }

  Widget _buildAvatar(Pet pet) {
    final isCat = pet.petType == 'cat';
    if (pet.avatarUrl != null && pet.avatarUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: 24,
        backgroundImage: CachedNetworkImageProvider(pet.avatarUrl!),
      );
    }
    return CircleAvatar(
      radius: 24,
      backgroundColor: AppTheme.secondaryColor.withValues(alpha: 0.3),
      child: Text(
        isCat ? '🐱' : '🐶',
        style: const TextStyle(fontSize: 22),
      ),
    );
  }
}
