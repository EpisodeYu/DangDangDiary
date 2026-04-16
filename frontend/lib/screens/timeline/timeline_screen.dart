import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/pet_provider.dart';
import '../../widgets/pet_selector.dart';

class TimelineScreen extends ConsumerWidget {
  const TimelineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final petListAsync = ref.watch(petListProvider);
    final selectedPetIds = ref.watch(selectedTimelinePetIdsProvider);
    final pets = petListAsync.valueOrNull?.pets ?? [];

    return Scaffold(
      appBar: AppBar(
        title: PetSelector(
          multiSelect: true,
          pets: pets,
          selectedPetIds: selectedPetIds,
          onMultiChanged: (ids) {
            ref.read(selectedTimelinePetIdsProvider.notifier).state = ids;
          },
        ),
      ),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.timeline, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('时间轴将在 Step 6 实现'),
          ],
        ),
      ),
    );
  }
}
