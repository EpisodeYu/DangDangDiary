import 'pet.dart';

// Backend serializes naive UTC datetimes without a timezone suffix.
// DateTime.parse would otherwise interpret them as local time, which makes
// the share-code countdown start at `24h - local offset`.
DateTime _parseUtcDateTime(String raw) {
  final hasTz =
      raw.endsWith('Z') || RegExp(r'[+\-]\d{2}:?\d{2}$').hasMatch(raw);
  return DateTime.parse(hasTz ? raw : '${raw}Z').toLocal();
}

class ShareCode {
  final String code;
  final DateTime expiresAt;
  final DateTime createdAt;

  const ShareCode({
    required this.code,
    required this.expiresAt,
    required this.createdAt,
  });

  factory ShareCode.fromJson(Map<String, dynamic> json) => ShareCode(
        code: json['code'] as String,
        expiresAt: _parseUtcDateTime(json['expires_at'] as String),
        createdAt: _parseUtcDateTime(json['created_at'] as String),
      );
}

class SharedMember {
  final int userId;
  final String? nickname;
  final String? avatarUrl;
  final PetRole role;
  final DateTime joinedAt;

  const SharedMember({
    required this.userId,
    required this.nickname,
    required this.avatarUrl,
    required this.role,
    required this.joinedAt,
  });

  factory SharedMember.fromJson(Map<String, dynamic> json) => SharedMember(
        userId: json['user_id'] as int,
        nickname: json['nickname'] as String?,
        avatarUrl: json['avatar_url'] as String?,
        role: petRoleFromString(json['role'] as String),
        joinedAt: _parseUtcDateTime(json['joined_at'] as String),
      );
}
