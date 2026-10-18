import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../widgets/app_page_intro.dart';
import '../../widgets/app_empty_state.dart';
import '../../models/health.dart';
import '../../models/pet.dart';
import '../../providers/health_provider.dart';
import '../../widgets/skeleton.dart';

class VaccinationTab extends ConsumerWidget {
  final Pet pet;

  const VaccinationTab({super.key, required this.pet});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(vaccinationListProvider(pet.id));

    return asyncList.when(
      loading: () => const SkeletonGenericList(rows: 5),
      error: (err, _) => _buildError(context, ref, err),
      data: (data) => _buildContent(context, ref, data),
    );
  }

  Widget _buildError(BuildContext context, WidgetRef ref, Object err) {
    return Center(
      child: AppEmptyState(
        icon: Icons.cloud_off_rounded,
        title: '暂时没能加载记录',
        message: '加载失败：${_friendlyError(err)}',
        action: TextButton(
          onPressed: () => ref.invalidate(vaccinationListProvider(pet.id)),
          child: const Text('重试'),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    VaccinationListResult data,
  ) {
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(vaccinationListProvider(pet.id));
        await ref.read(vaccinationListProvider(pet.id).future);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          const AppSectionTitle('疫苗记录'),
          const SizedBox(height: 12),
          if (data.vaccinations.isEmpty)
            _buildEmpty()
          else
            ...data.vaccinations.map((v) => _buildItem(context, ref, v)),
        ],
      ),
    );
  }

  Widget _buildEmpty() => const AppEmptyState(
    icon: Icons.vaccines_rounded,
    title: '还没有疫苗记录',
    message: '点击右下角加号添加第一条记录',
  );

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
              backgroundColor: AppTheme.blueColor,
              foregroundColor: Colors.white,
              icon: Icons.edit_rounded,
              label: '编辑',
              borderRadius: BorderRadius.circular(16),
            ),
            SlidableAction(
              onPressed: (_) => _confirmDelete(context, ref, v),
              backgroundColor: AppTheme.errorColor,
              foregroundColor: Colors.white,
              icon: Icons.delete_rounded,
              label: '删除',
              borderRadius: BorderRadius.circular(16),
            ),
          ],
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: AppTheme.borderColor),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Icon(
                Icons.calendar_today_rounded,
                size: 16,
                color: AppTheme.textSecondary,
              ),
              Text(
                v.vaccinatedAt,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textPrimary,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  v.vaccineType,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.accentColor,
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
    context.push(
      '/health/vaccination/edit?petId=${pet.id}&vaccinationId=${v.id}'
      '&type=$encoded&date=${v.vaccinatedAt}',
    );
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
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
          const SnackBar(
            content: Text('已删除'),
            behavior: SnackBarBehavior.floating,
          ),
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
