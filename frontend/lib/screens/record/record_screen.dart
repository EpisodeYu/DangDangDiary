import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/pet_provider.dart';
import '../../widgets/pet_selector.dart';

class RecordScreen extends ConsumerWidget {
  const RecordScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final petListAsync = ref.watch(petListProvider);
    final selectedPet = ref.watch(selectedPetProvider);
    final pets = petListAsync.valueOrNull?.pets ?? [];

    return Scaffold(
      appBar: AppBar(
        title: PetSelector(
          pets: pets,
          selectedPet: selectedPet,
          onSingleChanged: (pet) {
            if (pet != null) {
              ref.read(selectedPetIdProvider.notifier).select(pet.id);
            }
          },
        ),
      ),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.camera_alt, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('照片记录将在 Step 4 实现'),
          ],
        ),
      ),
    );
  }
}
