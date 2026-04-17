import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/theme.dart';
import '../../models/timeline.dart';
import '../../providers/pet_provider.dart';
import '../../providers/timeline_provider.dart';
import '../../widgets/pet_selector.dart';
import '../../widgets/photo_grid_tile.dart';
import '../../widgets/timeline_scrollbar.dart';
import 'photo_viewer_screen.dart';

class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key});

  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends ConsumerState<TimelineScreen> {
  final ScrollController _scrollController = ScrollController();

  // Keyed per month so we can scroll-to on jumpToMonth.
  final Map<String, GlobalKey> _monthKeys = {};
  String? _activeMonth;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels > pos.maxScrollExtent - 600) {
      ref.read(timelineProvider.notifier).loadOlder();
    }
    _updateActiveMonth();
  }

  void _updateActiveMonth() {
    // Find the top-most month header currently visible.
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
    // Let the list rebuild before scrolling.
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

  @override
  Widget build(BuildContext context) {
    final petListAsync = ref.watch(petListProvider);
    final selectedPetIds = ref.watch(selectedTimelinePetIdsProvider);
    final pets = petListAsync.valueOrNull?.pets ?? const [];
    final state = ref.watch(timelineProvider);

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
        title: PetSelector(
          multiSelect: true,
          pets: pets,
          selectedPetIds: selectedPetIds,
          onMultiChanged: (ids) {
            ref.read(selectedTimelinePetIdsProvider.notifier).state = ids;
          },
        ),
      ),
      body: _buildBody(state, filterMulti),
    );
  }

  Widget _buildBody(TimelineState state, bool filterMulti) {
    if (state.isInitialLoading && state.orderedPhotoIds.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.isEmpty) {
      return _EmptyView(onRefresh: () => ref.read(timelineProvider.notifier).refresh());
    }

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => ref.read(timelineProvider.notifier).refresh(),
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              for (final group in state.groups) ..._buildGroupSlivers(group, filterMulti),
              if (state.isLoadingOlder)
                const SliverToBoxAdapter(
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
                )
              else if (!state.hasMoreOlder && state.orderedPhotoIds.isNotEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        '— 没有更多照片了 —',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                )
              else
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
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
              );
            },
            childCount: group.photos.length,
          ),
        ),
      ),
    ];
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
