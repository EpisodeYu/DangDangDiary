import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../models/health.dart';
import '../../models/pet.dart';
import '../../providers/health_provider.dart';

class VaccinationTab extends ConsumerWidget {
  final Pet pet;

  const VaccinationTab({super.key, required this.pet});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(vaccinationListProvider(pet.id));

    return asyncList.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => _buildError(context, ref, err),
      data: (data) => _buildContent(context, ref, data),
    );
  }

  Widget _buildError(BuildContext context, WidgetRef ref, Object err) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('加载失败：${_friendlyError(err)}',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => ref.invalidate(vaccinationListProvider(pet.id)),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref, VaccinationListResult data) {
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(vaccinationListProvider(pet.id));
        await ref.read(vaccinationListProvider(pet.id).future);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          const Row(
            children: [
              Icon(Icons.access_time, size: 16, color: AppTheme.textSecondary),
              SizedBox(width: 6),
              Text('疫苗记录',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          const SizedBox(height: 12),
          if (data.vaccinations.isEmpty)
            _buildEmpty()
          else
            ...data.vaccinations.map((v) => _buildItem(context, ref, v)),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.vaccines_outlined, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 8),
          const Text('还没有疫苗记录',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          const SizedBox(height: 4),
          const Text('点击右下角加号添加第一条记录',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, WidgetRef ref, VaccinationRecord v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Slidable(
        key: ValueKey('vaccination-${v.id}'),
        endActionPane: ActionPane(
          motion: const BehindMotion(),
          children: [
            SlidableAction(
              onPressed: (_) => _edit(context, ref, v),
              backgroundColor: Colors.blue.shade400,
              foregroundColor: Colors.white,
              icon: Icons.edit,
              label: '编辑',
              borderRadius: BorderRadius.circular(12),
            ),
            SlidableAction(
              onPressed: (_) => _confirmDelete(context, ref, v),
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
              Text(v.vaccinatedAt,
                  style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  v.vaccineType,
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

  void _edit(BuildContext context, WidgetRef ref, VaccinationRecord v) {
    final encoded = Uri.encodeQueryComponent(v.vaccineType);
    context.push('/health/vaccination/edit?petId=${pet.id}&vaccinationId=${v.id}'
        '&type=$encoded&date=${v.vaccinatedAt}');
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    VaccinationRecord v,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除疫苗记录'),
        content: Text('确认删除 ${v.vaccinatedAt} 的${v.vaccineType}记录？'),
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
      await ref.read(healthServiceProvider).deleteVaccination(v.id);
      ref.invalidate(vaccinationListProvider(pet.id));
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
