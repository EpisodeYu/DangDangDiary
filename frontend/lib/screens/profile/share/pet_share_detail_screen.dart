import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/theme.dart';
import '../../../models/pet.dart';
import '../../../models/share.dart';
import '../../../providers/pet_provider.dart';
import '../../../providers/share_provider.dart';
import '../../../services/share_service.dart';
import 'share_qr_preview_screen.dart';

class PetShareDetailScreen extends ConsumerStatefulWidget {
  final int petId;
  const PetShareDetailScreen({super.key, required this.petId});

  @override
  ConsumerState<PetShareDetailScreen> createState() =>
      _PetShareDetailScreenState();
}

class _PetShareDetailScreenState extends ConsumerState<PetShareDetailScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-render once a minute so the countdown stays current.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    // Force a fresh fetch on entry — share code / members are authoritative
    // on the server and can be changed from another device.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(shareCodeProvider(widget.petId).notifier).refresh();
      ref.read(sharedMembersProvider(widget.petId).notifier).refresh();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final petListAsync = ref.watch(petListProvider);
    final pet = petListAsync.valueOrNull?.pets
        .where((p) => p.id == widget.petId)
        .firstOrNull;
    final petName = pet?.name ?? '宠物档案';

    final shareCodeAsync = ref.watch(shareCodeProvider(widget.petId));
    final membersAsync = ref.watch(sharedMembersProvider(widget.petId));

    return Scaffold(
      appBar: AppBar(title: Text('$petName · 档案分享')),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            ref.read(shareCodeProvider(widget.petId).notifier).refresh(),
            ref.read(sharedMembersProvider(widget.petId).notifier).refresh(),
          ]);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildShareCodeCard(context, shareCodeAsync),
            const SizedBox(height: 24),
            _buildMembersHeader(membersAsync),
            const SizedBox(height: 8),
            _buildMembersList(context, membersAsync),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ---------------- Share code section ----------------

  Widget _buildShareCodeCard(
    BuildContext context,
    AsyncValue<ShareCode?> async,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: async.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (e, _) => Column(
            children: [
              Text('加载失败：${shareErrorToMessage(e)}'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref
                    .read(shareCodeProvider(widget.petId).notifier)
                    .refresh(),
                child: const Text('重试'),
              ),
            ],
          ),
          data: (code) =>
              code == null ? _buildEmptyCode(context) : _buildActiveCode(context, code),
        ),
      ),
    );
  }

  Widget _buildEmptyCode(BuildContext context) {
    return Column(
      children: [
        const Icon(Icons.qr_code_2, size: 48, color: AppTheme.textSecondary),
        const SizedBox(height: 12),
        const Text(
          '还没有生成分享码',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton.icon(
            onPressed: () => _generate(context),
            icon: const Icon(Icons.add_link),
            label: const Text('生成 8 位分享码'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActiveCode(BuildContext context, ShareCode code) {
    final remaining = code.expiresAt.difference(DateTime.now());
    final remainingText = _formatRemaining(remaining);
    final expired = remaining.isNegative;

    return Column(
      children: [
        SelectableText(
          code.code,
          style: const TextStyle(
            fontSize: 32,
            letterSpacing: 6,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          expired ? '已过期' : '分享码剩余有效期：$remainingText',
          style: TextStyle(
            fontSize: 13,
            color: expired ? AppTheme.errorColor : AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: expired ? null : () => _copy(context, code.code),
                icon: const Icon(Icons.copy),
                label: const Text('复制'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primaryColor,
                  side: const BorderSide(color: AppTheme.primaryColor),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _confirmRegenerate(context),
                icon: const Icon(Icons.refresh),
                label: const Text('重新生成'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            // Disabled when the code is expired so we never push a
            // preview page that would show a useless dead code.
            onPressed: expired ? null : () => _openQrPreview(context, code),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('分享给好友 (QR 码)'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.primaryColor,
              side: const BorderSide(color: AppTheme.primaryColor),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openQrPreview(BuildContext context, ShareCode code) {
    final petListAsync = ref.read(petListProvider);
    final pet = petListAsync.valueOrNull?.pets
        .where((p) => p.id == widget.petId)
        .firstOrNull;
    final petName = pet?.name ?? '我的宠物';
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ShareQrPreviewScreen(
          code: code.code,
          petName: petName,
          expiresAt: code.expiresAt,
        ),
      ),
    );
  }

  String _formatRemaining(Duration d) {
    if (d.isNegative) return '0 分';
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    if (hours > 0) return '$hours 时 $minutes 分';
    return '$minutes 分';
  }

  Future<void> _copy(BuildContext context, String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('分享码已复制到剪贴板'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _generate(BuildContext context) async {
    try {
      await ref.read(shareCodeProvider(widget.petId).notifier).regenerate();
      // Owner badge in pet manage list refreshes via share_code_active.
      ref.read(petListProvider.notifier).refresh();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(shareErrorToMessage(e))),
      );
    }
  }

  Future<void> _confirmRegenerate(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新生成分享码'),
        content: const Text('重新生成会立即作废当前分享码，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _generate(context);
  }

  // ---------------- Members section ----------------

  Widget _buildMembersHeader(AsyncValue<List<SharedMember>> async) {
    final count = async.valueOrNull?.length ?? 0;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        '已分享给（$count 人）',
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppTheme.textPrimary,
        ),
      ),
    );
  }

  Widget _buildMembersList(
    BuildContext context,
    AsyncValue<List<SharedMember>> async,
  ) {
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '加载失败：${shareErrorToMessage(e)}',
          style: const TextStyle(color: AppTheme.errorColor),
        ),
      ),
      data: (members) {
        if (members.isEmpty) {
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 24),
            alignment: Alignment.center,
            child: const Text(
              '还没有用户接受这份档案分享',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          );
        }
        return Card(
          child: Column(
            children: [
              for (var i = 0; i < members.length; i++) ...[
                _buildMemberTile(context, members[i]),
                if (i != members.length - 1)
                  const Divider(height: 1, indent: 72),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildMemberTile(BuildContext context, SharedMember m) {
    return InkWell(
      onLongPress: () => _showMemberSheet(context, m),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: AppTheme.secondaryColor.withValues(alpha: 0.3),
              backgroundImage: m.avatarUrl != null && m.avatarUrl!.isNotEmpty
                  ? NetworkImage(m.avatarUrl!)
                  : null,
              child: (m.avatarUrl == null || m.avatarUrl!.isEmpty)
                  ? const Icon(Icons.person, color: AppTheme.primaryColor)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                m.nickname?.isNotEmpty == true ? m.nickname! : '用户${m.userId}',
                style: const TextStyle(
                  fontSize: 15,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            _roleChip(m.role),
          ],
        ),
      ),
    );
  }

  Widget _roleChip(PetRole role) {
    late final Color bg, fg;
    switch (role) {
      case PetRole.editor:
        bg = const Color(0xFFE5F0FF);
        fg = const Color(0xFF2D6BD6);
        break;
      case PetRole.viewer:
        bg = const Color(0xFFE8F5EA);
        fg = const Color(0xFF3E8E50);
        break;
      case PetRole.owner:
        bg = const Color(0xFFFFE5E5);
        fg = const Color(0xFFD64545);
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        petRoleLabel(role),
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }

  Future<void> _showMemberSheet(BuildContext context, SharedMember m) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  m.nickname?.isNotEmpty == true ? m.nickname! : '用户${m.userId}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text('当前权限：${petRoleLabel(m.role)}'),
              ),
              const Divider(height: 1),
              if (m.role == PetRole.viewer)
                ListTile(
                  leading: const Icon(Icons.edit, color: AppTheme.primaryColor),
                  title: const Text('授予编辑权限'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _changeRole(context, m, PetRole.editor);
                  },
                )
              else if (m.role == PetRole.editor)
                ListTile(
                  leading:
                      const Icon(Icons.lock_open, color: AppTheme.primaryColor),
                  title: const Text('取消编辑权限'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _changeRole(context, m, PetRole.viewer);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.delete, color: AppTheme.errorColor),
                title: const Text(
                  '删除分享权限',
                  style: TextStyle(color: AppTheme.errorColor),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _confirmRemove(context, m);
                },
              ),
              ListTile(
                title: const Center(child: Text('取消')),
                onTap: () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _changeRole(
    BuildContext context,
    SharedMember m,
    PetRole role,
  ) async {
    try {
      await ref
          .read(sharedMembersProvider(widget.petId).notifier)
          .updateRole(m.userId, role);
      // Opt Step 4: keep our own pet list in sync so a multi-device
      // owner sees the latest member role on the other device on
      // resume. Silent — no spinner on this page.
      ref.read(petListProvider.notifier).silentRefresh();
      if (!context.mounted) return;
      final name = m.nickname?.isNotEmpty == true ? m.nickname! : '该成员';
      final msg = role == PetRole.editor
          ? '已授予 $name 编辑权限'
          : '已取消 $name 的编辑权限';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(shareErrorToMessage(e))),
      );
    }
  }

  Future<void> _confirmRemove(BuildContext context, SharedMember m) async {
    final name = m.nickname?.isNotEmpty == true ? m.nickname! : '该成员';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分享权限'),
        content: Text('确认移除 $name 对该宠物档案的访问权限？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorColor),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await ref
          .read(sharedMembersProvider(widget.petId).notifier)
          .remove(m.userId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已移除 $name 的分享权限')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(shareErrorToMessage(e))),
      );
    }
  }
}
