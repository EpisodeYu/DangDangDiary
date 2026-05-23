# Optimization Step 2 · 时间轴按「日」分组（月级 scrollbar 保留）

> 状态：✅ 已落地（2026-05-23）。
> 后端：
> - `app/services/timeline.py` 新增 `_day_key` / `_day_label` / `_group_by_day`；`get_timeline_window` 内 `_group_by_month(items)` 已替换为 `_group_by_day(items)`；`_month_key` / `_month_label` / `_group_by_month` 保留（`_resolve_anchor_cursor` 仍消费 `_month_key`，scrollbar 走的 `/photos/timeline/dates` 仍按月）。
> - `app/schemas/photo.py` 中 `TimelineGroup.date` 注释更新为 `"YYYY-MM-DD"`。
> - 新增单元测试 `tests/unit/test_timeline_group_by_day.py`（5 个用例：同日合并 / 不同日拆分 / 空日不出现 / 10 位日期格式 / 空输入）。
> - **测试结果：`pytest tests` 189 passed / 0 failed**（baseline 184 + 新增 5；含原已稳定通过的 184 个测试集，全部不受 month→day 切换影响）。
>
> 前端：
> - `lib/models/timeline.dart` `TimelineGroup.date` 注释更新；新增 `TimelinePhoto.dayKey` getter。
> - `lib/providers/timeline_provider.dart`：新增 `dayKey` / `dayLabel`、`regroupByDay`；`rebuildMonthIndex` 含义升级为「day-key groups → month-key → 首张索引」，用 `g.date.substring(0, 7)` 取月前缀，保持给 `jumpToMonth` 的契约不变。`mergeWindow` / `removePhotos` 调用切到 `regroupByDay`。原 `monthKey` / `monthLabel` 保留供未来或月级展示复用。
> - `lib/screens/timeline/timeline_screen.dart`：`_monthKeys` 改名为 `_dayKeys`；`_updateActiveMonth` 把 day-key 前 7 位映射为 month；`_scrollToMonth` 按 `startsWith('$month-')` 找该月首个 day group；group header 上下 padding 从 `(20,8)` 收紧到 `(16,6)`（日级 group 更密，体验微调）。
> - **未跑 `flutter analyze`/`flutter test`**（无 SDK 环境）。lint 静态检查无 issue。**实机验证一日多照 / 跨月跳转 / scrollbar 高亮需要人测**。
>
> 破坏性变更：`groups[].date` 字段语义由 `"YYYY-MM"` → `"YYYY-MM-DD"`，**前后端必须同发**。旧客户端 + 新后端会渲染出 365 个独立 month header（实际是日 key 当 month key 用），UI 怪但不崩；新客户端 + 旧后端的 month key 走 `substring(0,7)` 也仍取得到正确月前缀，相当于退化回"按月分组"，不崩。

## 1. 背景

当前 `GET /api/v1/photos/timeline` 与前端 `TimelineScreen` / `TimelineNotifier` 都把照片按「月」分组：

- 后端 `app/services/timeline.py:_group_by_month` 把 `taken_at` 折叠到 `"YYYY-MM"` 桶。
- `TimelineGroup.date` 字段语义是 `"YYYY-MM"`（见 `backend/app/schemas/photo.py:75`），`label` 是 `"2026年1月"`。
- 前端 `TimelineMerge.regroupByMonth` 与 `_buildGroupSlivers` 把每个月渲染成一个 sliver header + 一个 4 列网格。
- 右侧 `TimelineScrollbar` 也按月，每月一条 tick，drag 后调 `jumpToMonth(monthKey)` 让后端用 `anchor_month` 加载窗口。

产品诉求：

- 改成「按日」分组，**没有照片的日子不显示**（即天然 group-by 的副产物）。
- 例：1 月 1 日下三张照片渲染为一个 group，1 月 2 日没有照片直接跳过，1 月 3 日的照片渲染为下一个 group。
- 右侧 scrollbar **仍然按月**——长时间轴下一年 365 个 tick 太密集，按月跳更符合 iOS Photos / Google Photos / 微信收藏的成熟交互。

## 2. 目标

- `groups[].date` 改为 `"YYYY-MM-DD"`，`label` 改为 `"2026年1月3日"`（或语义等价的本地化字符串）。
- 后端排序、cursor 语义完全不变（仍是 `(taken_at DESC, created_at DESC, id DESC)`）。
- 后端 `anchor_month` 入参保留，含义不变（前端右侧 scrollbar 跳转触发）。`resolved_anchor_month` 仍按月返回。
- `GET /api/v1/photos/timeline/dates` 仍返回月级别分布（`months[]`），驱动 scrollbar。
- 前端：
  - calendar 视图按日分组渲染，每个日 group 顶部 header 显示「2026年1月3日 (n)」。
  - 右侧月级 scrollbar 与 jumpToMonth 完全保留；jump 到月之后落地到该月「最新一天」的 day group。
  - immersive 视图不受影响（它不显示 group header）。
- 前后端原子升级，**不做向后兼容**：旧客户端读不到新 `groups[].date` 时会回退到「按 takenAt 自行重排」的客户端排序，但失去 group header（影响小）。新客户端配合新后端发布。

## 3. 已决策

| 决策点 | 选定方案 | 理由 |
|--------|----------|------|
| 右侧 scrollbar 颗粒度 | 仍按月 | 按日 tick 过密；与 iOS Photos 一致 |
| `groups[].date` 字段语义 | `"YYYY-MM-DD"`（破坏性变更） | 简单直接，不引入并行字段；前后端原子升级 |
| `groups[].label` 文案 | `"2026年1月3日"`（与现有 "2026年1月" 同语种风格） | 中文风格保留 |
| 是否需要新增日级 distribution 接口 | 否 | scrollbar 不需要，每个 day group 已带 `photos.length` |
| anchor 是否新增 `anchor_date` | 否 | 当前需求只通过月级 scrollbar 跳转，不需要按日 anchor |
| jumpToMonth 后落地的目标 day group | 该月内**最新一天**（即第一个出现的 day group） | 与右侧 scrollbar 对齐：用户拖到「2026 年 1 月」期望看到「1 月里的最新照片」 |
| 单月内没有照片时 jumpToMonth 行为 | 沿用 `_resolve_anchor_cursor` 现有 fallback（先 older 后 newer），用户感知不到改动 | 已有行为 |

## 4. 修改清单

### 4.1 后端

| 文件 | 改动 |
|------|------|
| `backend/app/services/timeline.py` | 新增 `_day_key(d)` / `_day_label(key)`；`_group_by_month` → `_group_by_day`；`get_timeline_window` 内调用点改为 `_group_by_day` |
| `backend/app/schemas/photo.py` | `TimelineGroup.date` 注释由 `"YYYY-MM"` 改为 `"YYYY-MM-DD"`；`label` 注释举例从 `"2024年1月"` → `"2024年1月3日"` |
| `backend/tests/test_timeline_service.py`（如存在；不存在则新增） | 加 group-by-day 用例 + 验证 `groups[].date` 是 10 位日期 + 同一天的照片聚成一个 group + 跨天分到不同 group + 没有照片的日子不出现在 groups |
| `docs/step6-timeline.md` | 更新 group 说明段落（标注 "Optimization Step 2 起：groups[].date = YYYY-MM-DD"） |

### 4.2 前端

| 文件 | 改动 |
|------|------|
| `frontend/lib/providers/timeline_provider.dart` | `TimelineMerge.monthKey/monthLabel` 改名为 `dayKey/dayLabel`；新增 `monthKey(DateTime)` 辅助（保留按月计算 scrollbar active month）；`regroupByMonth` → `regroupByDay`；`rebuildMonthIndex` 改为 `rebuildDayIndex`，但新增 `rebuildMonthIndex` 仍计算月 → 第一张照片的 ordered index（驱动 scrollbar 跳转） |
| `frontend/lib/models/timeline.dart` | `TimelineGroup.date` 注释更新；新增 `TimelinePhoto.dayKey` getter（返回 `"YYYY-MM-DD"`） |
| `frontend/lib/screens/timeline/timeline_screen.dart` | `_monthKeys` 改名为 `_dayKeys`（实际持有 day group 的 GlobalKey）；`_updateActiveMonth` 内仍计算当前可见 day group 的「月」并作为 scrollbar `_activeMonth`；`_scrollToMonth` 改为 `_scrollToDay`，但被 `_onJumpToMonth` 调用时按月解析到该月的第一个 day group key |
| `frontend/lib/widgets/timeline_scrollbar.dart` | **保持不动**，它消费的仍是 `monthDistribution`（来自 `GET /photos/timeline/dates`，依然按月） |
| `frontend/lib/services/photo_service.dart` | **不动**，`getTimeline` / `getTimelineDates` 协议没变 |

### 4.3 文档

| 文件 | 改动 |
|------|------|
| `docs/step6-timeline.md` | §「响应结构」节 + 示例 JSON 更新，加 "Optimization Step 2" 标注 |
| `docs/optimizations/README.md` | 标 step2 完成度 / commit hash 由 agent 实施时填回 |

## 5. 详细步骤

### 5.1 后端 `app/services/timeline.py`

新增 helpers（与现有 month helpers 平级）：

```python
def _day_label(key: str) -> str:
    # "2026-01-03" -> "2026年1月3日"
    year, month, day = key.split("-")
    return f"{int(year)}年{int(month)}月{int(day)}日"


def _day_key(d: date) -> str:
    return f"{d.year:04d}-{d.month:02d}-{d.day:02d}"
```

新增 `_group_by_day`，把当前的 `_group_by_month` 留作 dead code（前端不再消费，但月级 scrollbar 仍可能间接复用 `_month_key`）。**保留 `_month_key` / `_month_label`**——它们仍被 `_resolve_anchor_cursor` 用来计算 `resolved_anchor_month`。

```python
def _group_by_day(photos: list[TimelinePhotoItem]) -> list[TimelineGroup]:
    bucket: "OrderedDict[str, list[TimelinePhotoItem]]" = OrderedDict()
    for p in photos:
        key = _day_key(p.taken_at)
        bucket.setdefault(key, []).append(p)
    return [
        TimelineGroup(date=key, label=_day_label(key), photos=items)
        for key, items in bucket.items()
    ]
```

`get_timeline_window` 内：

```python
# ...
items = [
    _photo_to_item(...) for photo in photos
]
groups = _group_by_day(items)   # ← 改这一行
```

`_resolve_anchor_cursor` 中 `resolved_anchor_month` 已经返回 month key，无需改。

> 注意：`_group_by_month` 可以**删除**（仅 `get_timeline_window` 用过一次），但为了让回滚成本低、且不引入大段 dead code，建议**保留**并打 `# OPT-STEP2 obsoleted` 注释。

### 5.2 后端 `app/schemas/photo.py`

```python
class TimelineGroup(BaseModel):
    date: str   # "YYYY-MM-DD" since Optimization Step 2; was "YYYY-MM" prior.
    label: str  # e.g. "2026年1月3日"
    photos: list[TimelinePhotoItem]
```

### 5.3 后端测试

`backend/tests/test_timeline_service.py` 新增（或追加到已有 group 相关测试）：

```python
async def test_timeline_groups_by_day_not_month(...):
    # 准备 3 张同一天的照片 + 1 张次日 + 1 张同月其他日 + 1 张上月
    # 调 get_timeline_window
    # 断言：
    #   - 同一天的 3 张落到同一个 group
    #   - 不同天落到不同 group
    #   - groups[].date 是 10 位 "YYYY-MM-DD"
    #   - groups[].label 形如 "2026年1月3日"
    #   - 没有任何 "空日子" 的 group
    ...

async def test_anchor_month_still_works(...):
    # anchor_month="2026-01" 仍然返回 resolved_anchor_month="2026-01"
    # 第一组 group 仍然落在 2026 年 1 月内某一天
    ...
```

如果项目下 `tests/` 还没建立完整的 timeline 测试夹具，可以最低限度补一个 `test_group_by_day_split` 单元测试 + 一个 e2e（用 in-memory SQLite）。

### 5.4 前端 `lib/models/timeline.dart`

`TimelineGroup.date` 注释 → `"YYYY-MM-DD"`；保留 `TimelinePhoto.monthKey` getter，**新增** `TimelinePhoto.dayKey`：

```dart
String get monthKey { ... }   // 保留：scrollbar active month 仍用

String get dayKey {
  final y = takenAt.year.toString().padLeft(4, '0');
  final m = takenAt.month.toString().padLeft(2, '0');
  final d = takenAt.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
```

### 5.5 前端 `lib/providers/timeline_provider.dart`

新增 `dayKey` / `dayLabel`：

```dart
class TimelineMerge {
  static String monthKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    return '$y-$m';
  }

  static String dayKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static String monthLabel(String key) {
    final parts = key.split('-');
    return '${int.parse(parts[0])}年${int.parse(parts[1])}月';
  }

  static String dayLabel(String key) {
    final parts = key.split('-');
    return '${int.parse(parts[0])}年${int.parse(parts[1])}月${int.parse(parts[2])}日';
  }
```

`regroupByMonth` → 改名为 `regroupByDay`（替换实现，桶 key 用 `dayKey`，label 用 `dayLabel`）：

```dart
static List<TimelineGroup> regroupByDay(
  List<int> orderedIds,
  Map<int, TimelinePhoto> photoMap,
) {
  final groups = <String, List<TimelinePhoto>>{};
  final order = <String>[];
  for (final id in orderedIds) {
    final p = photoMap[id];
    if (p == null) continue;
    final key = dayKey(p.takenAt);
    final bucket = groups.putIfAbsent(key, () {
      order.add(key);
      return <TimelinePhoto>[];
    });
    bucket.add(p);
  }
  return order
      .map((k) => TimelineGroup(date: k, label: dayLabel(k), photos: groups[k]!))
      .toList(growable: false);
}
```

`rebuildMonthIndex` 仍然存在，**含义变成「day-key group 列表 → 月 key 第一个出现位置的 photo flat index」**，给 jumpToMonth 用：

```dart
/// month key -> index of the first photo (in flat order) that belongs
/// to that month. Used by `jumpToMonth` so scrolling to a month lands
/// on the newest day group inside that month.
static Map<String, int> rebuildMonthIndex(List<TimelineGroup> groups) {
  final map = <String, int>{};
  var idx = 0;
  for (final g in groups) {
    // g.date is now "YYYY-MM-DD" — derive the month prefix.
    final monthPrefix = g.date.substring(0, 7);
    map.putIfAbsent(monthPrefix, () => idx);
    idx += g.photos.length;
  }
  return map;
}
```

`mergeWindow` 内调用：

```dart
final groups = regroupByDay(ids, photoMap);          // ← 改
final monthIndex = rebuildMonthIndex(groups);        // 不变
```

`removePhotos` 内的 `regroupByMonth` 调用同步改成 `regroupByDay`，`removedPerMonth` 的桶 key 改为按月仍然合适（因为 monthDistribution 是月级），逻辑无需改：

```dart
final removedPerMonth = <String, int>{};
for (final id in removing) {
  final p = state.photoMap[id];
  if (p == null) continue;
  final key = TimelineMerge.monthKey(p.takenAt);   // 仍按月
  removedPerMonth[key] = (removedPerMonth[key] ?? 0) + 1;
}
// ...
final groups = TimelineMerge.regroupByDay(orderedIds, photoMap);
final monthIndex = TimelineMerge.rebuildMonthIndex(groups);
```

### 5.6 前端 `lib/screens/timeline/timeline_screen.dart`

`_monthKeys` 改名为 `_dayKeys`（语义更准确），其余跟随调整：

```dart
final Map<String, GlobalKey> _dayKeys = {};
String? _activeMonth;     // ← 保留：scrollbar 高亮仍按月
```

`_updateActiveMonth`：仍然要把当前可见的「day group key」映射回它的「月 key」给 scrollbar 高亮：

```dart
void _updateActiveMonth() {
  String? candidate;
  for (final entry in _dayKeys.entries) {
    final ctx = entry.value.currentContext;
    if (ctx == null) continue;
    final box = ctx.findRenderObject();
    if (box is! RenderBox) continue;
    final pos = box.localToGlobal(Offset.zero).dy;
    if (pos <= 180) {
      candidate = entry.key.substring(0, 7); // YYYY-MM 前缀
    } else {
      break;
    }
  }
  if (candidate != null && candidate != _activeMonth) {
    setState(() => _activeMonth = candidate);
  }
}
```

`_scrollToMonth(String month)`：找该月**第一个** day group key 然后 ensureVisible：

```dart
Future<void> _scrollToMonth(String month) async {
  // _dayKeys 已经是按时间倒序 putIfAbsent 的，所以遍历到的第一个
  // 满足前缀的 key 就是该月最新的一天 group。
  String? targetKey;
  for (final k in _dayKeys.keys) {
    if (k.startsWith('$month-')) {
      targetKey = k;
      break;
    }
  }
  final ctx = targetKey == null ? null : _dayKeys[targetKey]?.currentContext;
  if (ctx != null) {
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 240),
      alignment: 0.0,
    );
  }
}
```

`_buildGroupSlivers` 中 `_monthKeys[group.date]` 改成 `_dayKeys[group.date]`；group header 标题从月转日：

```dart
SliverToBoxAdapter(
  key: _dayKeys[group.date],
  child: Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Row(
      children: [
        // 紫色侧条不动
        // group.label 现在是 "2026年1月3日"
        Text(group.label, ...),
        const SizedBox(width: 6),
        Text('(${group.photos.length})', ...),
      ],
    ),
  ),
),
```

`putIfAbsent` 循环：

```dart
for (final g in state.groups) {
  _dayKeys.putIfAbsent(g.date, () => GlobalKey());
}
```

### 5.7 视觉调整建议（可选）

- 当一个 day group 只有 1 ~ 2 张时，sliver header 与下方网格之间的视觉密度比月级时密集很多。视情况把 group header 上下 padding 从 `(20, 8)` 改为 `(16, 6)`，让连续多天的列表更紧凑。**这是 UX 调优，非必须**。
- `(${group.photos.length})` 在按月时很有用（直观感受月产量），按日时往往是 1~3，没必要时可以隐藏。**建议保留**，与现有视觉一致；若 product 觉得太杂可单独迭代。

## 6. 数据 & API 兼容性

- **破坏性变更**：`TimelineGroup.date` 由 `"YYYY-MM"` 变为 `"YYYY-MM-DD"`，前后端原子发布。
- `TimelineWindowResponse.requested_anchor_month` / `resolved_anchor_month` 字段语义不变。
- `TimelineDatesResponse.months[].date` 仍是 `"YYYY-MM"`，不变。
- 无数据库迁移。

## 7. 验证清单

后端：

1. 单元测试 `pytest backend/tests/test_timeline_service.py -k group_by_day` 全过。
2. 手动 `curl /api/v1/photos/timeline?limit=40` ：`groups[0].date` 长度 = 10，`groups[].photos[].taken_at` 均落在 `groups[].date` 这一天内。
3. `anchor_month=2026-01` 仍可用，`resolved_anchor_month` 仍是 `"2026-01"`。

前端：

1. 进入时间轴，calendar 视图：连续 3 张同一天的照片显示在同一个 `"2026年1月3日 (3)"` 组下；中间空着的 1 月 2 日**不显示**。
2. 切换到 immersive 视图，照片继续按既有顺序流式展示，不显示 group header（不受影响）。
3. 右侧 scrollbar：拖到某一个月，正文滚动到该月最新一天的 day group 顶部。
4. 删除一张照片：所在 day group 数量 -1；若该 group 仅剩 1 张被删，删除后该 day group 整组消失。
5. 上下滚动：右上 scrollbar 高亮的月 tick 与可见 day group 所属的月一致。
6. 跨月翻页（loadOlder）：新加载的 day group 正确追加到列表末尾，不会出现"月已经存在还重复 group"的渲染异常。

## 8. 风险与回退

- **风险 1**：用户照片量大时 day group 数量可能远超月 group。CustomScrollView 的 sliver 数量翻倍，需关注内存。
  - 现状：grid 部分仍是 `SliverGrid` lazy build；header 是 `SliverToBoxAdapter`，每 group 一个固定的 ~36 px 高度的 Widget。100 个 day group × 36 px ≈ 3600 px header 总高度，对滚动性能无明显影响。
- **风险 2**：`_dayKeys` 哈希表条目数可能 ~ 数百，scrollbar `_updateActiveMonth` 每帧遍历对性能有一定开销。
  - 建议：`_updateActiveMonth` 已有 early-break，只要 day key 按时间倒序遍历，定位到首个可见 group 立即 break，无性能问题。
- **回退**：把后端 `_group_by_day` 改回 `_group_by_month`，schema 注释回滚，前端 `regroupByDay` 改回 `regroupByMonth` + group label 回月。打两个独立 commit，分别可 revert。

## 9. 估时

人 / agent ≈ 0.5 天（前后端协同）。
