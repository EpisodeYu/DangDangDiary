class User {
  final int id;
  final String phone;
  final String? nickname;
  final String? avatarUrl;

  const User({
    required this.id,
    required this.phone,
    this.nickname,
    this.avatarUrl,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as int,
      phone: json['phone'] as String,
      nickname: json['nickname'] as String?,
      avatarUrl: json['avatar_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'phone': phone,
      'nickname': nickname,
      'avatar_url': avatarUrl,
    };
  }
}
