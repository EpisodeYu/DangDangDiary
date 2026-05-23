import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../config/theme.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/app_card.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Uint8List? _pendingAvatarBytes;
  double? _uploadProgress;

  String _maskedPhone(String phone) {
    if (phone.length >= 7) {
      return '${phone.substring(0, 3)}****${phone.substring(7)}';
    }
    return phone;
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final user = authState.user;

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          AppCard(
            lifted: true,
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _uploadProgress != null ? null : _pickAndUploadAvatar,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 32,
                        backgroundColor:
                            AppTheme.secondaryColor.withValues(alpha: 0.3),
                        backgroundImage: _pendingAvatarBytes != null
                            ? MemoryImage(_pendingAvatarBytes!)
                            : (user?.avatarUrl != null
                                ? CachedNetworkImageProvider(user!.avatarUrl!)
                                : null) as ImageProvider?,
                        child: _pendingAvatarBytes == null &&
                                user?.avatarUrl == null
                            ? Icon(
                                Icons.person_rounded,
                                size: 32,
                                color: AppTheme.primaryColor,
                              )
                            : null,
                      ),
                      if (_uploadProgress != null)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black.withValues(alpha: 0.5),
                            ),
                            child: Center(
                              child: SizedBox(
                                width: 32,
                                height: 32,
                                child: CircularProgressIndicator(
                                  value: _uploadProgress,
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.3),
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryColor,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: Icon(
                              Icons.camera_alt_rounded,
                              size: 12,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () => _showEditNicknameDialog(
                            context, ref, user?.nickname),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                user?.nickname ?? '未设置昵称',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.edit_rounded,
                                size: 16, color: AppTheme.textSecondary),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        user != null ? _maskedPhone(user.phone) : '',
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _buildMenuItem(
                  context,
                  icon: Icons.pets_rounded,
                  title: '宠物档案管理',
                  onTap: () => context.push('/profile/pets'),
                ),
                const Divider(height: 1, indent: 56),
                _buildMenuItem(
                  context,
                  icon: Icons.ios_share_rounded,
                  title: '宠物档案分享',
                  onTap: () => context.push('/profile/pets/share'),
                ),
                const Divider(height: 1, indent: 56),
                _buildMenuItem(
                  context,
                  icon: Icons.logout_rounded,
                  title: '切换账号',
                  onTap: () => _showLogoutDialog(context, ref),
                ),
                const Divider(height: 1, indent: 56),
                _buildMenuItem(
                  context,
                  icon: Icons.info_outline_rounded,
                  title: '关于',
                  onTap: () {},
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.primaryColor),
      title: Text(title, style: const TextStyle(color: AppTheme.textPrimary)),
      trailing: Icon(Icons.chevron_right_rounded, color: AppTheme.textSecondary),
      onTap: onTap,
    );
  }

  Future<({Uint8List bytes, String filename})?> _compressAvatar(
      XFile xfile) async {
    final dir = await getTemporaryDirectory();
    final outPath =
        '${dir.path}/user_avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final result = await FlutterImageCompress.compressAndGetFile(
      xfile.path,
      outPath,
      minWidth: 400,
      minHeight: 400,
      format: CompressFormat.jpeg,
      quality: 80,
    );
    if (result == null) {
      final raw = await xfile.readAsBytes();
      return (bytes: raw, filename: xfile.name);
    }
    final bytes = await File(result.path).readAsBytes();
    return (bytes: bytes, filename: 'avatar.jpg');
  }

  Future<void> _pickAndUploadAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;

    final compressed = await _compressAvatar(file);
    if (compressed == null || !mounted) return;

    setState(() {
      _pendingAvatarBytes = compressed.bytes;
      _uploadProgress = 0;
    });

    final success = await ref.read(authProvider.notifier).uploadAvatar(
      compressed.bytes,
      compressed.filename,
      onSendProgress: (sent, total) {
        if (mounted && total > 0) {
          setState(() => _uploadProgress = sent / total);
        }
      },
    );

    if (!mounted) return;
    setState(() {
      _uploadProgress = null;
      if (success) _pendingAvatarBytes = null;
    });

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('头像上传失败，请重试')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('头像上传成功'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _showEditNicknameDialog(
      BuildContext context, WidgetRef ref, String? currentNickname) {
    final controller = TextEditingController(text: currentNickname ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改昵称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: InputDecoration(
            hintText: '请输入昵称',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final nickname = controller.text.trim();
              if (nickname.isEmpty) return;
              Navigator.of(ctx).pop();
              final success =
                  await ref.read(authProvider.notifier).updateNickname(nickname);
              if (!success && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('昵称修改失败，请重试')),
                );
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showLogoutDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换账号'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ref.read(authProvider.notifier).logout();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}
