import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../providers/pet_provider.dart';
import '../../widgets/pet_selector.dart';
import '../../widgets/app_empty_state.dart';
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
    final value =
        _tabController.animation?.value ?? _tabController.index.toDouble();
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
            Expanded(
              child: PetSelector(
                pets: pets,
                selectedPet: selectedPet,
                onSingleChanged: (pet) {
                  if (pet != null) {
                    ref.read(selectedPetIdProvider.notifier).select(pet.id);
                  }
                },
              ),
            ),
            const SizedBox(width: 16),
            const Text(
              '健康',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            64 * MediaQuery.textScalerOf(context).scale(1),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: _buildTopTabs(),
          ),
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
              tooltip: '添加记录',
              onPressed: () => _openRecordPage(selectedPet.id),
              child: Icon(Icons.add_rounded),
            ),
    );
  }

  Widget _buildTopTabs() {
    const labels = ['体重', '日常', '驱虫', '疫苗'];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.borderColor.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(labels.length, (i) {
          final selected = _highlightedIndex == i;
          return Expanded(
            child: Semantics(
              selected: selected,
              button: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  _tabController.animateTo(i);
                },
                child: AnimatedContainer(
                  duration: AppTheme.motionDuration(context),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? AppTheme.accentColor
                          : AppTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
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
      child: AppEmptyState(
        icon: Icons.pets_rounded,
        title: '请先创建宠物档案',
        message: '从第一份档案开始，陪伴毛孩子健康成长。',
        action: ElevatedButton(
          onPressed: () => context.push('/profile/pets/new'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            foregroundColor: AppTheme.primaryInk,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: const Text('去创建'),
        ),
      ),
    );
  }
}
