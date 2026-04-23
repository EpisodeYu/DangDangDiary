import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../providers/pet_provider.dart';
import '../../widgets/pet_selector.dart';
import 'deworming_tab.dart';
import 'routine_tab.dart';
import 'vaccination_tab.dart';
import 'weight_tab.dart';

class HealthScreen extends ConsumerStatefulWidget {
  const HealthScreen({super.key});

  @override
  ConsumerState<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends ConsumerState<HealthScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.animation?.addListener(_onTabAnimation);
  }

  void _onTabAnimation() {
    final value = _tabController.animation?.value ?? _tabController.index.toDouble();
    final next = value.round().clamp(0, _tabController.length - 1);
    if (next != _highlightedIndex && mounted) {
      setState(() => _highlightedIndex = next);
    }
  }

  @override
  void dispose() {
    _tabController.animation?.removeListener(_onTabAnimation);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final petListAsync = ref.watch(petListProvider);
    final selectedPet = ref.watch(selectedPetProvider);
    final pets = petListAsync.valueOrNull?.pets ?? [];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        centerTitle: false,
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            PetSelector(
              pets: pets,
              selectedPet: selectedPet,
              onSingleChanged: (pet) {
                if (pet != null) {
                  ref.read(selectedPetIdProvider.notifier).select(pet.id);
                }
              },
            ),
            const Spacer(),
            _buildTopTabs(),
          ],
        ),
      ),
      body: selectedPet == null
          ? _buildEmptyPetsState()
          : TabBarView(
              controller: _tabController,
              children: [
                WeightTab(pet: selectedPet),
                RoutineTab(pet: selectedPet),
                DewormingTab(pet: selectedPet),
                VaccinationTab(pet: selectedPet),
              ],
            ),
      floatingActionButton: selectedPet == null
          ? null
          : FloatingActionButton(
              onPressed: () => _openRecordPage(selectedPet.id),
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildTopTabs() {
    const labels = ['体重', '日常', '驱虫', '疫苗'];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(labels.length, (i) {
        final selected = _highlightedIndex == i;
        return Padding(
          padding: const EdgeInsets.only(left: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              _tabController.animateTo(i);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? AppTheme.primaryColor.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? AppTheme.primaryColor : AppTheme.textSecondary,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  void _openRecordPage(int petId) {
    switch (_tabController.index) {
      case 0:
        context.push('/health/weight/new?petId=$petId');
        break;
      case 1:
        context.push('/health/routine/new?petId=$petId');
        break;
      case 2:
        context.push('/health/deworming/new?petId=$petId');
        break;
      case 3:
        context.push('/health/vaccination/new?petId=$petId');
        break;
    }
  }

  Widget _buildEmptyPetsState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.pets, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          const Text(
            '请先创建宠物档案',
            style: TextStyle(fontSize: 16, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => context.push('/profile/pets/new'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('去创建'),
          ),
        ],
      ),
    );
  }
}
