import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../models/health.dart';
import '../../models/pet.dart';
import '../../providers/health_provider.dart';
import '../../widgets/skeleton.dart';

class WeightTab extends ConsumerWidget {
  final Pet pet;

  const WeightTab({super.key, required this.pet});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(weightListProvider(pet.id));

    return asyncList.when(
      loading: () => const SkeletonHealthList(),
      error: (err, _) => _buildError(context, ref, err),
      data: (data) => _buildContent(context, ref, data),
    );
  }

  Widget _buildError(BuildContext context, WidgetRef ref, Object err) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('加载失败：${_friendlyError(err)}',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => ref.invalidate(weightListProvider(pet.id)),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref, WeightListResult data) {
    final latest = data.weights.isEmpty ? null : data.weights.first;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(weightListProvider(pet.id));
        await ref.read(weightListProvider(pet.id).future);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          _buildLatestCard(latest),
          const SizedBox(height: 20),
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              const Text('体重记录',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          const SizedBox(height: 12),
          if (data.weights.isEmpty)
            _buildEmpty()
          else
            ...data.weights.map((w) => _buildItem(context, ref, w)),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.monitor_weight_rounded,
              size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 8),
          const Text('还没有体重记录',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          const SizedBox(height: 4),
          const Text('点击右下角加号添加第一条记录',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildLatestCard(WeightRecord? latest) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.primaryColor, AppTheme.secondaryColor],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('最新体重',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 6),
          Text(
            latest == null ? '-- kg' : '${latest.weightKg.toStringAsFixed(2)} kg',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            latest == null ? '暂无记录' : '记录日期：${latest.recordedAt}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, WidgetRef ref, WeightRecord w) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Slidable(
        key: ValueKey('weight-${w.id}'),
        endActionPane: ActionPane(
          motion: const BehindMotion(),
          children: [
            SlidableAction(
              onPressed: (_) => _edit(context, ref, w),
              backgroundColor: Colors.blue.shade400,
              foregroundColor: Colors.white,
              icon: Icons.edit_rounded,
              label: '编辑',
              borderRadius: BorderRadius.circular(12),
            ),
            SlidableAction(
              onPressed: (_) => _confirmDelete(context, ref, w),
              backgroundColor: AppTheme.errorColor,
              foregroundColor: Colors.white,
              icon: Icons.delete_rounded,
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
              Icon(Icons.calendar_today_rounded, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Text(w.recordedAt,
                  style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
              const Spacer(),
              Text(
                '${w.weightKg.toStringAsFixed(2)} kg',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primaryColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _edit(BuildContext context, WidgetRef ref, WeightRecord w) {
    context.push('/health/weight/edit?petId=${pet.id}&weightId=${w.id}'
        '&weight=${w.weightKg}&date=${w.recordedAt}');
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, WeightRecord w) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除体重记录'),
        content: Text('确认删除 ${w.recordedAt} 的体重记录？'),
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
      await ref.read(healthServiceProvider).deleteWeight(w.id);
      ref.invalidate(weightListProvider(pet.id));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除'), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：${_friendlyError(e)}'), behavior: SnackBarBehavior.floating),
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
