Map<String, dynamic> exportFixture({int count = 2}) => {
  'schema_version': 1,
  'exported_at': '2026-10-18T00:00:00Z',
  'pet': {
    'id': 7,
    'name': '当当',
    'pet_type': 'cat',
    'breed': '中华田园猫',
    'birthday': '2020-01-01',
    'avatar_url': null,
    'bath_cycle_days': 14,
    'bath_reminder_enabled': true,
    'combined_deworming_cycle_days': 30,
    'combined_reminder_enabled': true,
  },
  'photos': List.generate(
    count,
    (i) => {
      'id': i + 1,
      'pet_id': 7,
      'user_id': 1,
      'storage_key': '7/${i + 1}.${i.isEven ? 'jpg' : 'png'}',
      'taken_at': '2024-01-01',
      'created_at': '2024-01-01T00:00:00',
    },
  ),
  'records': {
    'weights': [
      {'id': 1, 'pet_id': 7, 'weight_kg': '4.25', 'recorded_at': '2024-01-01'},
    ],
    'dewormings': [
      {
        'id': 2,
        'pet_id': 7,
        'deworming_type': 'combined',
        'dewormed_at': '2024-01-02',
      },
    ],
    'vaccinations': [
      {
        'id': 3,
        'pet_id': 7,
        'vaccine_type': '猫三联',
        'vaccinated_at': '2024-01-03',
      },
    ],
    'routines': [
      {
        'id': 4,
        'pet_id': 7,
        'routine_type': 'bath',
        'performed_at': '2024-01-04',
      },
    ],
  },
};
