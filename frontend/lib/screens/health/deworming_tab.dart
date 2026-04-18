import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../models/health.dart';
import '../../models/pet.dart';
import '../../providers/health_provider.dart';
import '../../providers/notification_provider.dart';
import '../../providers/pet_provider.dart';

class DewormingTab extends ConsumerWidget {
  final Pet pet;

  const DewormingTab({super.key, required this.pet});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncStatus = ref.watch(dewormingStatusProvider(pet.id));
    final asyncList = ref.watch(dewormingListProvider(pet.id));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(dewormingStatusProvider(pet.id));
        ref.invalidate(dewormingListProvider(pet.id));
        await Future.wait([
          ref.read(dewormingStatusProvider(pet.id).future),
          ref.read(dewormingListProvider(pet.id).future),
        ]);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          asyncStatus.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (err, _) => _buildError(context, ref, err),
            data: (status) => _buildStatusCard(context, ref, status),
          ),
          const SizedBox(height: 20),
          const Row(
            children: [
              Icon(Icons.access_time, size: 16, color: AppTheme.textSecondary),
              SizedBox(width: 6),
              Text('驱虫记录',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          const SizedBox(height: 12),
          asyncList.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (err, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text('加载失败：${_friendlyError(err)}',
                  style: const TextStyle(color: AppTheme.textSecondary)),
            ),
            data: (data) => data.dewormings.isEmpty
                ? _buildEmpty()
                : Column(
                    children: data.dewormings
                        .map((d) => _buildItem(context, ref, d))
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, WidgetRef ref, Object err) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text('状态加载失败：${_friendlyError(err)}',
            style: const TextStyle(color: AppTheme.textSecondary)),
      ),
    );
  }

  Widget _buildStatusCard(BuildContext context, WidgetRef ref, DewormingStatus status) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusRow(context, ref, DewormingTypeE.internal, status.internal,
              pet.internalReminderEnabled),
          const Divider(height: 20),
          _buildStatusRow(context, ref, DewormingTypeE.external, status.external,
              pet.externalReminderEnabled),
          const Divider(height: 20),
          _buildStatusRow(context, ref, DewormingTypeE.combined, status.combined,
              pet.combinedReminderEnabled),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => context.push('/health/deworming/cycle?petId=${pet.id}'),
              icon: const Icon(Icons.settings, size: 16),
              label: const Text('设置周期'),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.primaryColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusRow(
    BuildContext context,
    WidgetRef ref,
    DewormingTypeE type,
    DewormingStatusItem item,
    bool reminderEnabled,
  ) {
    final subtitle = _buildSubtitle(type, item);
    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Checkbox(
            value: reminderEnabled,
            onChanged: (v) => _toggleReminder(context, ref, type, v ?? false),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 72,
          child: Text(type.label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              )),
        ),
        Expanded(child: subtitle),
      ],
    );
  }

  Widget _buildSubtitle(DewormingTypeE type, DewormingStatusItem item) {
    if (!item.reminderEnabled) {
      return const Text('已关闭提醒',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary));
    }
    if (item.lastDewormedAt == null) {
      return const Text('请先记录驱虫日期',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary));
    }
    if (item.cycleDays == null) {
      return const Text('请先设置驱虫周期',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary));
    }
    final days = item.daysRemaining ?? 0;
    if (item.isOverdue == true) {
      return Text('距离${type.label}提醒日期已过 ${days.abs()} 天',
          style: const TextStyle(
            fontSize: 13,
            color: AppTheme.errorColor,
            fontWeight: FontWeight.w600,
          ));
    }
    return Text('距离下次${type.label} $days 天',
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary));
  }

  Future<void> _toggleReminder(
    BuildContext context,
    WidgetRef ref,
    DewormingTypeE type,
    bool enabled,
  ) async {
    final service = ref.read(healthServiceProvider);
    try {
      await service.updateDewormingCycle(
        pet.id,
        internalReminderEnabled: type == DewormingTypeE.internal ? enabled : null,
        externalReminderEnabled: type == DewormingTypeE.external ? enabled : null,
        combinedReminderEnabled: type == DewormingTypeE.combined ? enabled : null,
      );
      ref.invalidate(dewormingStatusProvider(pet.id));
      await ref.read(petListProvider.notifier).refresh();
      unawaited(ref.read(healthReminderSchedulerProvider).refresh());
    } on DioException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(e)), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.vaccines_outlined, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 8),
          const Text('还没有驱虫记录',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          const SizedBox(height: 4),
          const Text('点击右下角加号添加第一条记录',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, WidgetRef ref, DewormingRecord d) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Slidable(
        key: ValueKey('deworming-${d.id}'),
        endActionPane: ActionPane(
          motion: const BehindMotion(),
          children: [
            SlidableAction(
              onPressed: (_) => _edit(context, ref, d),
              backgroundColor: Colors.blue.shade400,
              foregroundColor: Colors.white,
              icon: Icons.edit,
              label: '编辑',
              borderRadius: BorderRadius.circular(12),
            ),
            SlidableAction(
              onPressed: (_) => _confirmDelete(context, ref, d),
              backgroundColor: AppTheme.errorColor,
              foregroundColor: Colors.white,
              icon: Icons.delete,
              label: '删除',
              borderRadius: BorderRadius.circular(12),
            ),
          ],
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(Icons.calendar_today, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Text(d.dewormedAt,
                  style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  d.dewormingType.label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.primaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _edit(BuildContext context, WidgetRef ref, DewormingRecord d) {
    context.push('/health/deworming/edit?petId=${pet.id}&dewormingId=${d.id}'
        '&type=${d.dewormingType.apiValue}&date=${d.dewormedAt}');
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    DewormingRecord d,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除驱虫记录'),
        content: Text('确认删除 ${d.dewormedAt} 的${d.dewormingType.label}记录？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(healthServiceProvider).deleteDeworming(d.id);
      ref.invalidate(dewormingListProvider(pet.id));
      ref.invalidate(dewormingStatusProvider(pet.id));
      unawaited(ref.read(healthReminderSchedulerProvider).refresh());
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除'), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('删除失败：${_friendlyError(e)}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  String _friendlyError(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['message'] is String) {
        return data['message'] as String;
      }
    }
    return '请稍后重试';
  }
}
