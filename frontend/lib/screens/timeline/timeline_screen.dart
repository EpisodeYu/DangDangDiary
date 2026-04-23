import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/theme.dart';
import '../../models/pet.dart';
import '../../models/timeline.dart';
import '../../providers/pet_provider.dart';
import '../../providers/timeline_provider.dart';
import '../../services/original_photo_cache.dart';
import '../../services/photo_service.dart';
import '../../widgets/immersive_photo_tile.dart';
import '../../widgets/pet_selector.dart';
import '../../widgets/photo_grid_tile.dart';
import '../../widgets/photo_info_dialog.dart';
import '../../widgets/timeline_scrollbar.dart';
import 'photo_viewer_screen.dart';

final _photoServiceProvider = Provider<PhotoService>((ref) => PhotoService());

const int _maxBatchSelection = 9;

/// How many upcoming items to prefetch (originals) as the user scrolls
/// through the immersive timeline. The current-item original is always
/// fetched by [OriginalPhotoImage] itself.
const int _immersivePrefetchAhead = 2;
const int _immersivePrefetchBehind = 1;

/// How many photos ahead of the currently visible band of the calendar
/// grid we proactively warm in the image cache. The grid renders ~4 photos
/// per row and each row is the same height, so prefetching 24 photos ≈ 6
/// rows ≈ 1.5 viewports of headroom — enough that a quick swipe lands on
/// already-decoded tiles, but not so aggressive that we waste bytes on
/// content the user will never see.
const int _calendarPrefetchAhead = 24;

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

  bool _selectionMode = false;
  final Set<int> _selectedIds = <int>{};

  /// Photo ids whose calendar-grid thumbnail we have already asked
  /// `precacheImage` to warm. The flutter image cache deduplicates by
  /// provider key on its own, but doing the dedup here too lets us skip
  /// rebuilding the `CachedNetworkImageProvider` and short-circuit on
  /// every scroll tick once a tile is known to be warm.
  final Set<int> _prefetchedThumbIds = <int>{};

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

  /// Warm the image cache for [_calendarPrefetchAhead] tiles starting at
  /// [startIndex] in [photos]. Safe to call repeatedly; per-id dedup makes
  /// repeated invocations from the grid builder essentially free.
  void _prefetchCalendarThumbsFrom(
    BuildContext context,
    List<TimelinePhoto> photos,
    int startIndex,
  ) {
    if (photos.isEmpty) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cachePx = (110 * dpr).round().clamp(180, 420);
    final end =
        (startIndex + _calendarPrefetchAhead).clamp(0, photos.length);
    for (var i = startIndex; i < end; i++) {
      final photo = photos[i];
      if (!_prefetchedThumbIds.add(photo.id)) continue;
      final url = photo.gridThumbnailUrl;
      if (url.isEmpty) continue;
      // IMPORTANT: build the *same* provider chain `CachedNetworkImage`
      // uses inside `PhotoGridTile`. The widget constructs a bare
      // `CachedNetworkImageProvider` (no maxWidth/maxHeight on disk
      // cache) and then wraps it in `ResizeImage(width: memCacheWidth)`.
      // Matching that exactly is what makes the warmed entry's cache key
      // collide with the one the tile resolves at paint time — otherwise
      // the prefetch downloads a duplicate the tile never reads.
      //
      // We also pass ONLY `width:` (not `height:`) so `ResizeImage` keeps
      // the source aspect ratio. Setting both would force
      // `ResizeImagePolicy.exact` and visibly stretch non-square photos.
      final provider = ResizeImage(
        CachedNetworkImageProvider(url),
        width: cachePx,
      );
      // precacheImage drives the provider to `resolve()` and pins the
      // decoded bitmap into `imageCache` until eviction. We swallow
      // failures to keep a single dead URL from polluting the logs as
      // the grid grows.
      // ignore: discarded_futures
      precacheImage(provider, context, onError: (_, stack) {});
    }
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

  void _enterSelection(int firstId) {
    setState(() {
      _selectionMode = true;
      _selectedIds
        ..clear()
        ..add(firstId);
    });
  }

  void _exitSelection() {
    if (!_selectionMode && _selectedIds.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(int id) {
    if (_selectedIds.contains(id)) {
      setState(() {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectionMode = false;
      });
      return;
    }
    if (_selectedIds.length >= _maxBatchSelection) {
      _showSnack('一次最多选择 $_maxBatchSelection 张照片');
      return;
    }
    setState(() => _selectedIds.add(id));
  }

  Future<void> _onTapPhoto(TimelinePhoto photo) async {
    if (_selectionMode) {
      _toggleSelection(photo.id);
      return;
    }
    _openViewer(photo.id);
  }

  Future<void> _onLongPressCalendar(TimelinePhoto photo) async {
    if (_selectionMode) return;
    final action = await _showPhotoActionSheet(allowMultiSelect: true);
    if (!mounted) return;
    await _handlePhotoSheetAction(photo, action);
  }

  Future<void> _onLongPressImmersive(TimelinePhoto photo) async {
    final action = await _showPhotoActionSheet(allowMultiSelect: false);
    if (!mounted) return;
    await _handlePhotoSheetAction(photo, action);
  }

  Future<String?> _showPhotoActionSheet({required bool allowMultiSelect}) {
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('详细信息'),
              onTap: () => Navigator.pop(ctx, 'info'),
            ),
            if (allowMultiSelect)
              ListTile(
                leading: const Icon(Icons.check_box_outlined),
                title: const Text('多选'),
                onTap: () => Navigator.pop(ctx, 'multi'),
              ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: AppTheme.errorColor),
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
  }

  Future<void> _handlePhotoSheetAction(
    TimelinePhoto photo,
    String? action,
  ) async {
    switch (action) {
      case 'info':
        await showPhotoInfoDialog(context, photo);
        break;
      case 'multi':
        _enterSelection(photo.id);
        break;
      case 'delete':
        final confirmed = await _confirmDelete(1);
        if (!mounted || confirmed != true) return;
        await _deleteSinglePhoto(photo.id);
        break;
    }
  }

  Future<bool?> _confirmDelete(int count) {
    final title = count > 1 ? '确定删除这 $count 张照片吗？' : '确定删除这张照片吗？';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
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
  }

  Future<void> _deleteSinglePhoto(int photoId) async {
    final service = ref.read(_photoServiceProvider);
    try {
      await service.deletePhoto(photoId);
      if (!mounted) return;
      ref.read(timelineProvider.notifier).removePhotos([photoId]);
      _showSnack('已删除');
    } on DioException catch (e) {
      if (!mounted) return;
      _showSnack(_deleteErrorMessage(e));
    } catch (_) {
      if (!mounted) return;
      _showSnack('删除失败，请稍后重试');
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final ids = _selectedIds.toList(growable: false);
    final confirmed = await _confirmDelete(ids.length);
    if (!mounted || confirmed != true) return;

    final service = ref.read(_photoServiceProvider);
    final deleted = <int>[];
    final failed = <int>[];
    bool anyPermissionFailure = false;
    for (final id in ids) {
      try {
        await service.deletePhoto(id);
        deleted.add(id);
      } on DioException catch (e) {
        failed.add(id);
        if (_isPermissionError(e)) anyPermissionFailure = true;
      } catch (_) {
        failed.add(id);
      }
    }
    if (!mounted) return;
    if (deleted.isNotEmpty) {
      ref.read(timelineProvider.notifier).removePhotos(deleted);
    }
    _exitSelection();
    if (failed.isEmpty) {
      _showSnack('已删除 ${deleted.length} 张');
    } else if (deleted.isEmpty) {
      _showSnack(anyPermissionFailure ? '无删除权限' : '删除失败，请稍后重试');
    } else {
      final suffix = anyPermissionFailure ? '${failed.length} 张无删除权限' : '${failed.length} 张失败';
      _showSnack('已删除 ${deleted.length} 张，$suffix');
    }
  }

  bool _isPermissionError(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['code'] == 'PET_EDITOR_REQUIRED') return true;
    return e.response?.statusCode == 403;
  }

  String _deleteErrorMessage(DioException e) {
    if (_isPermissionError(e)) return '无删除权限';
    final data = e.response?.data;
    if (data is Map<String, dynamic>) {
      return (data['message'] as String?) ?? '删除失败，请稍后重试';
    }
    return '删除失败，请稍后重试';
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

    // Selection only applies to calendar mode — leaving the mode drops it.
    if (_selectionMode && viewMode != TimelineViewMode.calendar) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _exitSelection();
      });
    }

    // Drop stale selected IDs (e.g., if photos were removed from state).
    if (_selectionMode) {
      final stale = _selectedIds
          .where((id) => !state.photoMap.containsKey(id))
          .toList(growable: false);
      if (stale.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _selectedIds.removeAll(stale);
            if (_selectedIds.isEmpty) _selectionMode = false;
          });
        });
      }
    }

    for (final g in state.groups) {
      _monthKeys.putIfAbsent(g.date, () => GlobalKey());
    }

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Scaffold(
        appBar: _selectionMode
            ? _buildSelectionAppBar()
            : _buildDefaultAppBar(pets, selectedPetIds, viewMode),
        body: _buildBody(state, viewMode),
        bottomNavigationBar: _selectionMode ? _buildSelectionBar() : null,
      ),
    );
  }

  PreferredSizeWidget _buildDefaultAppBar(
    List<Pet> pets,
    List<int> selectedPetIds,
    TimelineViewMode viewMode,
  ) {
    return AppBar(
      titleSpacing: 16,
      centerTitle: false,
      automaticallyImplyLeading: false,
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
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: '取消',
        onPressed: _exitSelection,
      ),
      title: Text('已选 ${_selectedIds.length}/$_maxBatchSelection'),
    );
  }

  Widget _buildSelectionBar() {
    final count = _selectedIds.length;
    final enabled = count > 0;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          border: Border(
            top: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              onPressed: enabled ? _deleteSelected : null,
              icon: const Icon(Icons.delete_outline),
              label: Text(enabled ? '删除 ($count)' : '删除'),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.errorColor,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    TimelineState state,
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

    // Keep both views mounted so switching modes does not dispose tiles and
    // force thumbnails / originals to reload from disk on every toggle.
    return IndexedStack(
      sizing: StackFit.expand,
      index: viewMode == TimelineViewMode.calendar ? 0 : 1,
      children: [
        TickerMode(
          enabled: viewMode == TimelineViewMode.calendar,
          child: _buildCalendar(state),
        ),
        TickerMode(
          enabled: viewMode == TimelineViewMode.immersive,
          child: _buildImmersive(
            state,
            active: viewMode == TimelineViewMode.immersive,
          ),
        ),
      ],
    );
  }

  Widget _buildCalendar(TimelineState state) {
    // Flatten once per build so `_buildGroupSlivers` can hand each tile
    // its global index. Cheap (O(n)) and shared across all groups in this
    // build.
    final flatPhotos = state.orderedPhotoIds
        .map((id) => state.photoMap[id])
        .whereType<TimelinePhoto>()
        .toList(growable: false);
    final flatIndex = <int, int>{
      for (var i = 0; i < flatPhotos.length; i++) flatPhotos[i].id: i,
    };
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            _exitSelection();
            // Drop the prefetch dedup so a manual refresh re-warms the
            // first viewport's worth of (possibly new) tiles.
            _prefetchedThumbIds.clear();
            await ref.read(timelineProvider.notifier).refresh();
          },
          child: CustomScrollView(
            controller: _calendarScrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              for (final group in state.groups)
                ..._buildGroupSlivers(group, flatPhotos, flatIndex),
              _buildTailSliver(state),
            ],
          ),
        ),
        if (!_selectionMode)
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

  Widget _buildImmersive(TimelineState state, {required bool active}) {
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
            // Rebuild the tail whenever the original cache state changes so
            // we can flip "正在加载" → "没有更多" the moment the last
            // pending download lands, without waiting for the user to
            // scroll or for an unrelated state change.
            return ValueListenableBuilder<int>(
              valueListenable: OriginalPhotoCache.instance.revision,
              builder: (context, _, child) => _buildImmersiveTail(state),
            );
          }
          final photo = photos[index];
          // Only prefetch originals when immersive is the active view. When
          // it's offstage inside IndexedStack the ListView still builds its
          // viewport items, and we don't want background downloads of full
          // originals while the user is browsing calendar thumbnails.
          if (active) {
            _prefetchAround(photos, index);
          }
          return ImmersivePhotoTile(
            photo: photo,
            showPetLabel: false,
            onTap: () => _openViewer(photo.id),
            onLongPress: () => _onLongPressImmersive(photo),
          );
        },
      ),
    );
  }

  /// Ask the cache to download originals for a small window around [index].
  /// The cache deduplicates concurrent requests, so calling this repeatedly
  /// as tiles enter the viewport is safe.
  void _prefetchAround(List<TimelinePhoto> photos, int index) {
    final start =
        (index - _immersivePrefetchBehind).clamp(0, photos.length - 1);
    final end =
        (index + _immersivePrefetchAhead).clamp(0, photos.length - 1);
    for (var i = start; i <= end; i++) {
      OriginalPhotoCache.instance.prefetch(photos[i].id);
    }
  }

  Widget _buildImmersiveTail(TimelineState state) {
    // Show the spinner whenever:
    //   * the server still has older pages we haven't fetched,
    //   * a fetch is in flight, OR
    //   * every metadata page is loaded but originals are still being
    //     downloaded into the on-disk cache for already-known photos.
    //
    // The third case is what made "没有更多照片了" appear too early: the
    // user could scroll to the bottom of the immersive list while plenty
    // of tiles further up were still downloading their originals, and the
    // "end" marker felt jarring next to half-loaded tiles.
    final allOriginalsReady = state.orderedPhotoIds
        .every(OriginalPhotoCache.instance.isCachedSync);
    final stillLoadingOriginals =
        !allOriginalsReady && state.orderedPhotoIds.isNotEmpty;

    if (state.hasMoreOlder ||
        state.isLoadingOlder ||
        stillLoadingOriginals) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text(
                '— 正在加载 —',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    if (state.orderedPhotoIds.isNotEmpty) {
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

  List<Widget> _buildGroupSlivers(
    TimelineGroup group,
    List<TimelinePhoto> flatPhotos,
    Map<int, int> flatIndex,
  ) {
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
              // Treat each laid-out tile as a "user is currently looking
              // around here" hint and warm the next slab of upcoming
              // tiles. Doing it from the builder keeps prefetch tied to
              // actual scroll position without any extra listeners or
              // viewport math.
              final globalIdx = flatIndex[photo.id];
              if (globalIdx != null) {
                _prefetchCalendarThumbsFrom(
                  context, flatPhotos, globalIdx + 1,
                );
              }
              return PhotoGridTile(
                photo: photo,
                showPetLabel: false,
                selectionMode: _selectionMode,
                selected: _selectedIds.contains(photo.id),
                onTap: () => _onTapPhoto(photo),
                onLongPress: () => _onLongPressCalendar(photo),
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
