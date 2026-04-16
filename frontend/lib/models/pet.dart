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
  final bool isOwner;
  final String myRole;
  final String createdAt;
  final String updatedAt;

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
    required this.isOwner,
    required this.myRole,
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
      isOwner: json['is_owner'] as bool,
      myRole: json['my_role'] as String,
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
      'is_owner': isOwner,
      'my_role': myRole,
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
