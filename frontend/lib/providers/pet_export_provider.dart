import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/pet_export_service.dart';

final petExportServiceProvider = Provider<PetExportService>(
  (ref) => PetExportService(),
);
