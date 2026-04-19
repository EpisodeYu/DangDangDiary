enum PetRole { owner, editor, viewer }

PetRole petRoleFromString(String s) {
  switch (s) {
    case 'owner':
      return PetRole.owner;
    case 'editor':
      return PetRole.editor;
    case 'viewer':
      return PetRole.viewer;
  }
  throw ArgumentError('Unknown pet role: $s');
}

String petRoleLabel(PetRole r) {
  switch (r) {
    case PetRole.owner:
      return '拥有';
    case PetRole.editor:
      return '编辑';
    case PetRole.viewer:
      return '查看';
  }
}

String petRoleApiValue(PetRole r) {
  switch (r) {
    case PetRole.owner:
      return 'owner';
    case PetRole.editor:
      return 'editor';
    case PetRole.viewer:
      return 'viewer';
  }
}

class Pet {
  final int id;
  final String name;
  final String petType;
  final String? breed;
  final String? birthday;
  final String? avatarUrl;
  final String? inviteCode;
  final int? internalDewormingCycleDays;
  final int? externalDewormingCycleDays;
  final int? combinedDewormingCycleDays;
  final bool internalReminderEnabled;
  final bool externalReminderEnabled;
  final bool combinedReminderEnabled;
  final int? bathCycleDays;
  final int? nailTrimCycleDays;
  final int? groomingCycleDays;
  final bool bathReminderEnabled;
  final bool nailTrimReminderEnabled;
  final bool groomingReminderEnabled;
  final bool isOwner;
  final String myRole;
  final bool shareCodeActive;
  final String createdAt;
  final String updatedAt;

  PetRole get role => petRoleFromString(myRole);
  String get roleLabel => petRoleLabel(role);

  const Pet({
    required this.id,
    required this.name,
    required this.petType,
    this.breed,
    this.birthday,
    this.avatarUrl,
    this.inviteCode,
    this.internalDewormingCycleDays,
    this.externalDewormingCycleDays,
    this.combinedDewormingCycleDays,
    required this.internalReminderEnabled,
    required this.externalReminderEnabled,
    required this.combinedReminderEnabled,
    this.bathCycleDays,
    this.nailTrimCycleDays,
    this.groomingCycleDays,
    required this.bathReminderEnabled,
    required this.nailTrimReminderEnabled,
    required this.groomingReminderEnabled,
    required this.isOwner,
    required this.myRole,
    this.shareCodeActive = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Pet.fromJson(Map<String, dynamic> json) {
    return Pet(
      id: json['id'] as int,
      name: json['name'] as String,
      petType: json['pet_type'] as String,
      breed: json['breed'] as String?,
      birthday: json['birthday'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      inviteCode: json['invite_code'] as String?,
      internalDewormingCycleDays: json['internal_deworming_cycle_days'] as int?,
      externalDewormingCycleDays: json['external_deworming_cycle_days'] as int?,
      combinedDewormingCycleDays: json['combined_deworming_cycle_days'] as int?,
      internalReminderEnabled: (json['internal_reminder_enabled'] as bool?) ?? false,
      externalReminderEnabled: (json['external_reminder_enabled'] as bool?) ?? false,
      combinedReminderEnabled: (json['combined_reminder_enabled'] as bool?) ?? false,
      bathCycleDays: json['bath_cycle_days'] as int?,
      nailTrimCycleDays: json['nail_trim_cycle_days'] as int?,
      groomingCycleDays: json['grooming_cycle_days'] as int?,
      bathReminderEnabled: (json['bath_reminder_enabled'] as bool?) ?? false,
      nailTrimReminderEnabled: (json['nail_trim_reminder_enabled'] as bool?) ?? false,
      groomingReminderEnabled: (json['grooming_reminder_enabled'] as bool?) ?? false,
      isOwner: json['is_owner'] as bool,
      myRole: json['my_role'] as String,
      shareCodeActive: (json['share_code_active'] as bool?) ?? false,
      createdAt: json['created_at'] as String,
      updatedAt: json['updated_at'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'pet_type': petType,
      'breed': breed,
      'birthday': birthday,
      'avatar_url': avatarUrl,
      'invite_code': inviteCode,
      'internal_deworming_cycle_days': internalDewormingCycleDays,
      'external_deworming_cycle_days': externalDewormingCycleDays,
      'combined_deworming_cycle_days': combinedDewormingCycleDays,
      'internal_reminder_enabled': internalReminderEnabled,
      'external_reminder_enabled': externalReminderEnabled,
      'combined_reminder_enabled': combinedReminderEnabled,
      'bath_cycle_days': bathCycleDays,
      'nail_trim_cycle_days': nailTrimCycleDays,
      'grooming_cycle_days': groomingCycleDays,
      'bath_reminder_enabled': bathReminderEnabled,
      'nail_trim_reminder_enabled': nailTrimReminderEnabled,
      'grooming_reminder_enabled': groomingReminderEnabled,
      'is_owner': isOwner,
      'my_role': myRole,
      'share_code_active': shareCodeActive,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }
}

class PetListResult {
  final int page;
  final int pageSize;
  final int total;
  final List<Pet> pets;

  const PetListResult({
    required this.page,
    required this.pageSize,
    required this.total,
    required this.pets,
  });

  factory PetListResult.fromJson(Map<String, dynamic> json) {
    return PetListResult(
      page: json['page'] as int,
      pageSize: json['page_size'] as int,
      total: json['total'] as int,
      pets: (json['pets'] as List<dynamic>)
          .map((e) => Pet.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
