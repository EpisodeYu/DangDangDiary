# Step 6: 照片时间轴

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL + MinIO 技术栈。本步骤实现照片时间轴功能，用户可以按时间顺序浏览所有宠物照片。

**前置依赖**: Step 4 已完成 (照片记录功能)，照片已存储在 MinIO 中。

---

## 本步骤目标

1. 后端实现时间轴照片查询 API (支持多档案筛选、分页)
2. Flutter 实现时间轴页面 (网格布局 + 时间分组 + 滚动定位)
3. Flutter 实现照片查看大图功能
4. Flutter 实现长条时间轴滚动条定位

---

## 1. 后端 API 规格

### 1.1 获取时间轴照片

```
GET /api/v1/photos/timeline?pet_ids=1,2&page=1&page_size=40&year=2024&month=1
Authorization: Bearer {access_token}
```

查询参数:
- `pet_ids`: 宠物 ID 列表 (逗号分隔)，为空表示查询所有绑定的宠物
- `page`: 页码，默认 1
- `page_size`: 每页数量，默认 40，最大 100
- `year`: 按年份筛选 (可选)
- `month`: 按月份筛选 (可选，需配合 year 使用)

成功响应 (200):
```json
{
  "groups": [
    {
      "date": "2024-01",
      "label": "2024年1月",
      "photos": [
        {
          "id": 1,
          "pet_id": 1,
          "pet_name": "橘子",
          "pet_type": "cat",
          "thumbnail_url": "http://...",
          "taken_at": "2024-01-15",
          "created_at": "2024-01-20T10:30:00"
        },
        ...
      ]
    },
    {
      "date": "2023-12",
      "label": "2023年12月",
      "photos": [...]
    }
  ],
  "total_photos": 150,
  "page": 1,
  "page_size": 40,
  "has_more": true,
  "date_range": {
    "earliest": "2023-01-15",
    "latest": "2024-01-20"
  }
}
```

业务逻辑:
- 查询用户通过 pet_members 关联的宠物照片
- 按 taken_at 降序排列
- 返回按月分组的照片列表
- `date_range` 返回最早和最新照片日期，供前端时间轴滚动条使用
- 缩略图使用 MinIO 预签名 URL (1小时过期)

### 1.2 获取照片原图

```
GET /api/v1/photos/{photo_id}/url
Authorization: Bearer {access_token}
```

成功响应 (200):
```json
{
  "url": "http://minio:9000/pet-photos/1/xxx.jpg?X-Amz-...",
  "expires_in": 3600
}
```

已在 Step 4 中定义，供点击缩略图查看大图时使用。

### 1.3 获取时间轴日期分布

```
GET /api/v1/photos/timeline/dates?pet_ids=1,2
Authorization: Bearer {access_token}
```

成功响应 (200):
```json
{
  "months": [
    {"date": "2024-01", "count": 15},
    {"date": "2023-12", "count": 8},
    {"date": "2023-11", "count": 23},
    ...
  ]
}
```

用途: 供前端长条时间轴滚动条显示有照片的月份和密度。

---

## 2. Flutter 页面设计

### 2.1 时间轴页面整体布局

```
┌─────────────────────────────────┐
│  全部宠物 ▼  (多选宠物筛选器)     │
├─────────────────────────────────┤
│                                 │
│  ── 2024年1月 ──               │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ │ ┐
│  │ 📷 │ │ 📷 │ │ 📷 │ │ 📷 │ │ │
│  └────┘ └────┘ └────┘ └────┘ │ │
│  ┌────┐ ┌────┐ ┌────┐       │ │
│  │ 📷 │ │ 📷 │ │ 📷 │       │ │ 网格照片区
│  └────┘ └────┘ └────┘       │ │
│                               │ │
│  ── 2023年12月 ──             │ │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ │ │
│  │ 📷 │ │ 📷 │ │ 📷 │ │ 📷 │ │ │
│  └────┘ └────┘ └────┘ └────┘ │ ┘
│                               │
│  (继续向下滚动加载更多...)       │
│                               │
├─ ┌──┐ ──────────────────────── ┤
│  │  │  1月                     │ ← 长条时间轴滚动条(竖向)
│  │  │  2月                     │   在屏幕右侧
│  │  │  ...                     │
│  │  │  12月                    │
│  └──┘                          │
├─────────────────────────────────┤
│  记录  │  健康  │ 时间轴 │  AI  │ 我的 │
└─────────────────────────────────┘
```

### 2.2 核心交互

1. **宠物筛选器** (顶部)
   - 多选模式的宠物选择器
   - 默认选中全部宠物
   - 可以取消选择某些宠物，实时筛选
   - 选择变化时重新加载时间轴数据

2. **照片网格**
   - 按月分组，每月一个标题 (如 "2024年1月")
   - 每行 4 张缩略图，正方形裁切显示
   - 多档案照片混合展示时，缩略图左下角显示宠物名字小标签
   - 使用 `cached_network_image` 缓存缩略图
   - 滚动到底部自动加载下一页 (无限滚动)

3. **点击查看大图**
   - 点击缩略图进入全屏查看模式
   - 使用 `photo_view` 包支持双指缩放和左右滑动
   - 底部显示: 宠物名字、拍摄日期
   - 支持左右滑动浏览同一组的其他照片
   - 右上角可以分享/保存到本地

4. **长条时间轴滚动条** (右侧)
   - 竖向长条，显示在屏幕右侧边缘
   - 标注有照片的月份
   - 拖动滚动条可以快速定位到对应月份的照片
   - 拖动时显示年月气泡提示 (如 "2024年1月")
   - 月份标记的密度/大小可以反映该月照片数量

### 2.3 空状态

```
┌─────────────────────────────────┐
│                                 │
│                                 │
│         📷                      │
│     还没有照片哦                  │
│   去「记录」页面上传第一张吧       │
│                                 │
│                                 │
└─────────────────────────────────┘
```

---

## 3. Flutter 实现要点

### 3.1 时间轴数据模型

```dart
class TimelineGroup {
  final String date;       // "2024-01"
  final String label;      // "2024年1月"
  final List<TimelinePhoto> photos;
}

class TimelinePhoto {
  final int id;
  final int petId;
  final String petName;
  final String petType;
  final String thumbnailUrl;
  final DateTime takenAt;
}

class DateDistribution {
  final String date;       // "2024-01"
  final int count;
}
```

### 3.2 分页加载策略

```dart
class TimelineProvider extends StateNotifier<TimelineState> {
  int _currentPage = 1;
  bool _hasMore = true;
  bool _isLoading = false;

  Future<void> loadMore() async {
    if (_isLoading || !_hasMore) return;
    _isLoading = true;

    final response = await _photoService.getTimeline(
      petIds: state.selectedPetIds,
      page: _currentPage,
      pageSize: 40,
    );

    state = state.copyWith(
      groups: _mergeGroups(state.groups, response.groups),
      hasMore: response.hasMore,
    );

    _currentPage++;
    _isLoading = false;
  }

  List<TimelineGroup> _mergeGroups(
    List<TimelineGroup> existing,
    List<TimelineGroup> newGroups,
  ) {
    // 合并相同月份的分组
    // ...
  }
}
```

### 3.3 照片网格组件

```dart
// 使用 SliverList + SliverGrid 实现分组网格
CustomScrollView(
  controller: _scrollController,
  slivers: [
    for (final group in state.groups) ...[
      // 月份标题
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(group.label, style: ...),
        ),
      ),
      // 照片网格
      SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildPhotoTile(group.photos[index]),
          childCount: group.photos.length,
        ),
      ),
    ],
  ],
)
```

### 3.4 右侧时间轴滚动条

实现思路:
- 使用 `Stack` 在照片网格上层叠加一个右侧的时间轴滚动条
- 滚动条高度与页面滚动范围对应
- 监听 `ScrollController` 的滚动位置，同步更新滚动条位置
- 拖动滚动条时，使用 `_scrollController.jumpTo()` 跳转到对应位置
- 需要预先知道每个月份分组在列表中的像素偏移量

```dart
class TimelineScrollbar extends StatelessWidget {
  final ScrollController scrollController;
  final List<DateDistribution> dateDistribution;
  final double maxScrollExtent;

  // 拖动时显示的年月气泡
  Widget _buildBubble(String label) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.primaryColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: TextStyle(color: Colors.white, fontSize: 14)),
    );
  }
}
```

### 3.5 照片查看器

```dart
// 点击缩略图打开全屏查看
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => PhotoViewerScreen(
      photos: currentGroup.photos,
      initialIndex: tappedIndex,
    ),
  ),
);

// PhotoViewerScreen 使用 PageView + PhotoView
PageView.builder(
  controller: PageController(initialPage: initialIndex),
  itemCount: photos.length,
  itemBuilder: (context, index) {
    return PhotoView(
      imageProvider: NetworkImage(photos[index].fullUrl),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 2,
    );
  },
)
```

---

## 4. 性能优化要点

1. **缩略图缓存**: 使用 `cached_network_image`，设置合理的缓存大小
2. **分页加载**: 每次加载 40 张，滚动到底部自动加载
3. **图片占位**: 加载中显示灰色占位方块，避免布局跳动
4. **预签名 URL 缓存**: 缩略图 URL 在前端缓存，避免频繁请求签名
5. **懒加载原图**: 只在用户点击查看大图时才请求原图 URL
6. **列表回收**: 使用 Sliver 系列组件，确保离屏图片被回收

---

## 5. 需要创建/修改的文件清单

### 后端
- `backend/app/api/v1/photos.py` - 添加时间轴查询接口 (修改)
- `backend/app/schemas/photo.py` - 添加时间轴响应模型 (修改)

### 前端
- `frontend/lib/models/timeline.dart` - 时间轴数据模型 (新建)
- `frontend/lib/services/photo_service.dart` - 添加时间轴 API (修改)
- `frontend/lib/providers/timeline_provider.dart` - 时间轴状态管理 (新建)
- `frontend/lib/screens/timeline/timeline_screen.dart` - 时间轴主页面 (实现)
- `frontend/lib/screens/timeline/photo_viewer_screen.dart` - 照片查看器 (新建)
- `frontend/lib/widgets/timeline_scrollbar.dart` - 时间轴滚动条 (新建)
- `frontend/lib/widgets/photo_grid_tile.dart` - 照片网格单元 (新建)

---

## 6. 验收标准

- [ ] 后端时间轴 API 正确返回按月分组的照片数据
- [ ] 后端支持多 pet_id 筛选
- [ ] 后端分页正常工作
- [ ] Flutter 时间轴页面展示照片网格 (每行4张)
- [ ] Flutter 照片按月分组，显示月份标题
- [ ] Flutter 多宠物照片混合展示时有宠物名标签
- [ ] Flutter 滚动到底部自动加载更多
- [ ] Flutter 多选宠物筛选器正常工作
- [ ] Flutter 点击照片可查看大图
- [ ] Flutter 大图支持双指缩放
- [ ] Flutter 大图支持左右滑动切换
- [ ] Flutter 右侧时间轴滚动条可拖动定位
- [ ] Flutter 拖动时显示年月气泡提示
- [ ] Flutter 无照片时显示空状态提示
- [ ] 缩略图加载性能流畅 (不卡顿)
