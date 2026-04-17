import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/theme.dart';
import '../../models/timeline.dart';
import '../../providers/pet_provider.dart';
import '../../providers/timeline_provider.dart';
import '../../services/photo_service.dart';
import '../../widgets/immersive_photo_tile.dart';
import '../../widgets/pet_selector.dart';
import '../../widgets/photo_grid_tile.dart';
import '../../widgets/timeline_scrollbar.dart';
import 'photo_viewer_screen.dart';

final _photoServiceProvider = Provider<PhotoService>((ref) => PhotoService());

class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key});

  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends ConsumerState<TimelineScreen> {
  final ScrollController _calendarScrollController = ScrollController();
  final ScrollController _immersiveScrollController = ScrollController();

  // Keyed per month so we can scroll-to on jumpToMonth (calendar mode only).
  final Map<String, GlobalKey> _monthKeys = {};
  String? _activeMonth;

  @override
  void initState() {
    super.initState();
    _calendarScrollController.addListener(_onCalendarScroll);
    _immersiveScrollController.addListener(_onImmersiveScroll);
  }

  @override
  void dispose() {
    _calendarScrollController.removeListener(_onCalendarScroll);
    _calendarScrollController.dispose();
    _immersiveScrollController.removeListener(_onImmersiveScroll);
    _immersiveScrollController.dispose();
    super.dispose();
  }

  void _onCalendarScroll() {
    if (!_calendarScrollController.hasClients) return;
    final pos = _calendarScrollController.position;
    if (pos.pixels > pos.maxScrollExtent - 600) {
      ref.read(timelineProvider.notifier).loadOlder();
    }
    _updateActiveMonth();
  }

  void _onImmersiveScroll() {
    if (!_immersiveScrollController.hasClients) return;
    final pos = _immersiveScrollController.position;
    if (pos.pixels > pos.maxScrollExtent - 800) {
      ref.read(timelineProvider.notifier).loadOlder();
    }
  }

  void _updateActiveMonth() {
    String? candidate;
    for (final entry in _monthKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox) continue;
      final pos = box.localToGlobal(Offset.zero).dy;
      if (pos <= 180) {
        candidate = entry.key;
      } else {
        break;
      }
    }
    if (candidate != null && candidate != _activeMonth) {
      setState(() => _activeMonth = candidate);
    }
  }

  Future<void> _scrollToMonth(String month) async {
    final key = _monthKeys[month];
    final ctx = key?.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 240),
        alignment: 0.0,
      );
      return;
    }
  }

  Future<void> _onJumpToMonth(String month) async {
    final resolved =
        await ref.read(timelineProvider.notifier).jumpToMonth(month);
    if (resolved == null || !mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _scrollToMonth(resolved);
  }

  void _openViewer(int photoId) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => PhotoViewerScreen(initialPhotoId: photoId),
      ),
    );
  }

  Future<void> _onLongPressPhoto(TimelinePhoto photo) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppTheme.errorColor),
              title: const Text(
                '删除',
                style: TextStyle(color: AppTheme.errorColor),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action != 'delete') return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确定删除这张照片吗？'),
        content: const Text('删除后不可恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorColor),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    await _deletePhoto(photo.id);
  }

  Future<void> _deletePhoto(int photoId) async {
    final service = ref.read(_photoServiceProvider);
    try {
      await service.deletePhoto(photoId);
      if (!mounted) return;
      _showSnack('已删除');
      await ref.read(timelineProvider.notifier).refresh();
    } on DioException catch (e) {
      if (!mounted) return;
      final data = e.response?.data;
      String message = '删除失败，请稍后重试';
      if (data is Map<String, dynamic>) {
        message = (data['message'] as String?) ?? message;
      }
      _showSnack(message);
    } catch (_) {
      if (!mounted) return;
      _showSnack('删除失败，请稍后重试');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    final petListAsync = ref.watch(petListProvider);
    final selectedPetIds = ref.watch(selectedTimelinePetIdsProvider);
    final pets = petListAsync.valueOrNull?.pets ?? const [];
    final state = ref.watch(timelineProvider);
    final viewMode = ref.watch(timelineViewModeProvider);

    // Decide whether to show the pet-name overlay label on each tile.
    final filterMulti = selectedPetIds.isEmpty
        ? pets.length > 1
        : selectedPetIds.length > 1;

    // Ensure keys for every group present in state.
    for (final g in state.groups) {
      _monthKeys.putIfAbsent(g.date, () => GlobalKey());
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        centerTitle: false,
        title: Row(
          children: [
            PetSelector(
              multiSelect: true,
              pets: pets,
              selectedPetIds: selectedPetIds,
              onMultiChanged: (ids) {
                ref.read(selectedTimelinePetIdsProvider.notifier).state = ids;
              },
            ),
            const Spacer(),
            _ViewModeSwitcher(
              current: viewMode,
              onChanged: (mode) {
                ref.read(timelineViewModeProvider.notifier).state = mode;
              },
            ),
          ],
        ),
      ),
      body: _buildBody(state, filterMulti, viewMode),
    );
  }

  Widget _buildBody(
    TimelineState state,
    bool filterMulti,
    TimelineViewMode viewMode,
  ) {
    if (state.isInitialLoading && state.orderedPhotoIds.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.isEmpty) {
      return _EmptyView(
        onRefresh: () => ref.read(timelineProvider.notifier).refresh(),
      );
    }

    if (viewMode == TimelineViewMode.immersive) {
      return _buildImmersive(state, filterMulti);
    }
    return _buildCalendar(state, filterMulti);
  }

  Widget _buildCalendar(TimelineState state, bool filterMulti) {
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => ref.read(timelineProvider.notifier).refresh(),
          child: CustomScrollView(
            controller: _calendarScrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              for (final group in state.groups)
                ..._buildGroupSlivers(group, filterMulti),
              _buildTailSliver(state),
            ],
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          bottom: 0,
          child: TimelineScrollbar(
            months: state.monthDistribution,
            activeMonth: _activeMonth,
            onJump: _onJumpToMonth,
          ),
        ),
      ],
    );
  }

  Widget _buildImmersive(TimelineState state, bool filterMulti) {
    final photos = state.orderedPhotoIds
        .map((id) => state.photoMap[id])
        .whereType<TimelinePhoto>()
        .toList(growable: false);

    return RefreshIndicator(
      onRefresh: () => ref.read(timelineProvider.notifier).refresh(),
      child: ListView.builder(
        controller: _immersiveScrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
        itemCount: photos.length + 1,
        itemBuilder: (context, index) {
          if (index == photos.length) {
            return _buildImmersiveTail(state);
          }
          final photo = photos[index];
          return ImmersivePhotoTile(
            photo: photo,
            showPetLabel: filterMulti,
            onTap: () => _openViewer(photo.id),
            onLongPress: () => _onLongPressPhoto(photo),
          );
        },
      ),
    );
  }

  Widget _buildImmersiveTail(TimelineState state) {
    if (state.isLoadingOlder) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (!state.hasMoreOlder && state.orderedPhotoIds.isNotEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            '— 没有更多照片了 —',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ),
      );
    }
    return const SizedBox(height: 40);
  }

  Widget _buildTailSliver(TimelineState state) {
    if (state.isLoadingOlder) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    if (!state.hasMoreOlder && state.orderedPhotoIds.isNotEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              '— 没有更多照片了 —',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
        ),
      );
    }
    return const SliverToBoxAdapter(child: SizedBox(height: 40));
  }

  List<Widget> _buildGroupSlivers(TimelineGroup group, bool filterMulti) {
    return [
      SliverToBoxAdapter(
        key: _monthKeys[group.date],
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                group.label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '(${group.photos.length})',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
            childAspectRatio: 1,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final photo = group.photos[i];
              return PhotoGridTile(
                photo: photo,
                showPetLabel: filterMulti,
                onTap: () => _openViewer(photo.id),
                onLongPress: () => _onLongPressPhoto(photo),
              );
            },
            childCount: group.photos.length,
          ),
        ),
      ),
    ];
  }
}

class _ViewModeSwitcher extends StatelessWidget {
  final TimelineViewMode current;
  final ValueChanged<TimelineViewMode> onChanged;

  const _ViewModeSwitcher({
    required this.current,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ModeIconButton(
          icon: Icons.grid_view_rounded,
          selected: current == TimelineViewMode.calendar,
          tooltip: '日历模式',
          onTap: () => onChanged(TimelineViewMode.calendar),
        ),
        const SizedBox(width: 4),
        _ModeIconButton(
          icon: Icons.view_agenda_outlined,
          selected: current == TimelineViewMode.immersive,
          tooltip: '沉浸模式',
          onTap: () => onChanged(TimelineViewMode.immersive),
        ),
      ],
    );
  }
}

class _ModeIconButton extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  const _ModeIconButton({
    required this.icon,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primaryColor.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 20,
            color: selected ? AppTheme.primaryColor : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  final VoidCallback onRefresh;
  const _EmptyView({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          const Icon(
            Icons.photo_library_outlined,
            size: 64,
            color: AppTheme.textSecondary,
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              '还没有照片哦',
              style: TextStyle(
                fontSize: 16,
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text(
              '去「记录」页面上传第一张吧',
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
