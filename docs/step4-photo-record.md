# Step 4: 照片记录

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL + MinIO 技术栈。本步骤实现宠物照片的上传、管理与记录页面闭环。

**前置依赖**:
- Step 3 已完成，宠物档案管理与档案选择器可用
- 用户登录、鉴权、`pet_members` 权限链路已可用
- MinIO 基础连接与统一入口 `/media/...` 已具备

---

## 本步骤目标

1. 后端实现照片上传 API，支持批量上传，每次最多 5 张，单张 <= 15MB
2. 后端实现宠物图片校验，调用阿里云场景识别 API 拦截明确的非宠物图片
3. 后端实现缩略图生成、原图访问签名 URL、按宠物分页查询、删除照片
4. Flutter 实现「记录」页面，支持选档案、选照片、日期选择、上传结果反馈
5. Flutter 实现 EXIF 日期提取，并处理手动修改后的日期覆盖规则
6. 明确 Step 4 与 Step 6 的边界: Step 4 负责按宠物的照片管理，Step 6 再做跨宠物时间轴

---

## 0. 本步骤关键约定

这些约定已经在 Step 4 细化中确认，后续实现默认按此执行:

- 共享档案中，`owner` 和 `member` 都可以上传照片
- 删除照片时，只要当前用户可以访问该宠物档案，就可以删除该档案下任意照片
- 批量上传采用**部分成功**策略，不做整批回滚
- 上传接口统一返回 `200`，用 `successes` / `failures` 表达结果
- 服务端处理文件时要**继续处理完整批次**，不能遇到第一张失败就中断
- 阿里云识别服务异常、超时、未配置时，**放行上传**，优先保证主流程可用
- 一次上传请求只提交一个 `taken_at`，本次成功上传的所有照片共享该日期
- 上传响应中保留 `storage_key`、`thumbnail_key`

---

## 1. 照片存储架构

```text
MinIO Buckets:
├── pet-photos/          # 原图，建议私有，仅通过预签名 URL 访问
│   ├── {pet_id}/{uuid}.jpg
│   ├── {pet_id}/{uuid}.png
│   └── {pet_id}/{uuid}.webp
└── pet-thumbnails/      # 缩略图，公开读，经 /media/... 访问
    └── {pet_id}/{uuid}_thumb.jpg
```

约定说明:
- 原图保持上传后的实际格式，支持 `jpg` / `png` / `webp`
- 如果用户原始选择的是 `HEIC/HEIF`，Flutter 端必须先转成 `JPEG` 再上传
- 缩略图由后端生成，统一为 `JPEG`
- 文件名使用 UUID，按 `pet_id` 分目录，方便删除宠物时按前缀清理
- `storage_key` 与 `thumbnail_key` 仅保存对象 key，不重复包含 bucket 名
- `thumbnail_url` 由后端拼接为:
  - `{PUBLIC_BASE_URL}/media/{MINIO_BUCKET_THUMBNAILS}/{thumbnail_key}`
- 原图不直接暴露固定公开 URL，查看原图时走签名 URL 接口

---

## 2. 后端 API 规格

### 2.1 上传照片

```http
POST /api/v1/pets/{pet_id}/photos
Content-Type: multipart/form-data
Authorization: Bearer {access_token}
```

表单字段:
- `files`: 图片文件列表，最少 1 张，最多 5 张，每张 <= 15MB
- `taken_at`: 拍摄日期，格式 `YYYY-MM-DD`

支持的图片格式:
- JPEG
- PNG
- WEBP

补充说明:
- 如果用户选择 `HEIC/HEIF`，Flutter 端先转换为 `JPEG`
- 上传接口只负责写入照片记录，不负责时间轴聚合
- `owner` 与 `member` 只要能访问该宠物档案，都可以上传

#### 2.1.1 返回语义

上传接口统一返回 `200 OK`，响应体描述本批次结果:

```json
{
  "successes": [
    {
      "index": 0,
      "filename": "cat-1.jpg",
      "photo": {
        "id": 1,
        "pet_id": 1,
        "user_id": 12,
        "storage_key": "1/a1b2c3d4.jpg",
        "thumbnail_key": "1/a1b2c3d4_thumb.jpg",
        "thumbnail_url": "http://YOUR_SERVER_IP/media/pet-thumbnails/1/a1b2c3d4_thumb.jpg",
        "taken_at": "2024-01-15",
        "created_at": "2024-01-20T10:30:00Z"
      }
    }
  ],
  "failures": [
    {
      "index": 1,
      "filename": "landscape.png",
      "code": "PET_NOT_DETECTED",
      "message": "未识别到宠物，请换一张图片试试吧！",
      "details": {
        "detected_labels": [
          "outdoor(0.82)",
          "grass(0.77)"
        ]
      }
    }
  ],
  "success_count": 1,
  "failure_count": 1,
  "total_count": 2
}
```

字段说明:
- `index`: 对应前端上传数组中的 0-based 序号
- `filename`: 客户端上传时的文件名，方便前端定位失败项
- `photo`: 成功项的完整照片对象
- `failures[*]`: 只描述该文件失败原因，不影响同批次其它文件继续处理

#### 2.1.2 请求级错误与文件级失败的区分

以下情况属于**请求级错误**，直接返回错误响应，不进入批量处理结果:
- `400 EMPTY_UPLOAD`: 没有上传任何文件
- `400 TOO_MANY_FILES`: 一次上传超过 5 张
- `400 INVALID_TAKEN_AT`: `taken_at` 缺失或格式非法
- `403 PET_FORBIDDEN`: 当前用户无权访问该宠物档案
- `404 PET_NOT_FOUND`: 宠物档案不存在

以下情况属于**文件级失败**，写入 `failures`，请求本身仍返回 `200`:
- `UNSUPPORTED_IMAGE_TYPE`
- `FILE_TOO_LARGE`
- `PET_NOT_DETECTED`
- `THUMBNAIL_GENERATION_FAILED`
- `PHOTO_UPLOAD_FAILED`

如果一批次中所有文件都失败，但请求本身合法，也仍然返回 `200`，此时:
- `success_count = 0`
- `failure_count = total_count`

#### 2.1.3 处理流程

1. 校验当前用户是否可以访问 `pet_id`
2. 校验请求级条件:
   - `files` 非空
   - 文件总数不超过 5
   - `taken_at` 格式合法
3. 按顺序遍历每个文件，**继续处理完整批次**
4. 单文件处理流程:
   - 校验类型是否为 `image/jpeg`、`image/png`、`image/webp`
   - 校验文件大小是否 <= 15MB
   - 调用阿里云 `RecognizeScene` 判断是否包含猫或狗
   - 如果明确识别为非宠物，则写入 `failures`
   - 如果识别服务异常、超时或未配置，则记录日志并继续上传
   - 生成 UUID 文件名
   - 上传原图到 `pet-photos`
   - 生成缩略图并上传到 `pet-thumbnails`
   - 创建 `photos` 表记录
   - 把成功结果写入 `successes`
5. 汇总返回 `successes`、`failures`、`success_count`、`failure_count`、`total_count`

#### 2.1.4 宠物图片校验策略

使用阿里云视觉智能开放平台的**场景识别 (`RecognizeScene`)** API。

关键约定:
- AccessKey 与短信服务共用
- 识别输入使用二进制流，不要求先传 OSS
- 识别结果命中宠物关键词且置信度 > `0.3`，判定为通过
- 识别结果明确不含宠物时，返回文件级失败 `PET_NOT_DETECTED`
- 第三方服务异常时**放行上传**

这里的“放行”是**产品决策**，表示“第三方识别不可用时不阻塞主流程”，并不等于识别成功。

阿里云文档参考:
- `docs/API_docs/本文档为您介绍场景识别常用语言和常见情况的示例代码.md`

#### 2.1.5 推荐响应模型

```python
class PhotoResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    storage_key: str
    thumbnail_key: str
    thumbnail_url: str
    taken_at: date
    created_at: datetime

class PhotoUploadSuccess(BaseModel):
    index: int
    filename: str
    photo: PhotoResponse

class PhotoUploadFailure(BaseModel):
    index: int
    filename: str
    code: str
    message: str
    details: dict | None = None

class PhotoUploadResponse(BaseModel):
    successes: list[PhotoUploadSuccess]
    failures: list[PhotoUploadFailure]
    success_count: int
    failure_count: int
    total_count: int
```

### 2.2 获取宠物照片列表

```http
GET /api/v1/pets/{pet_id}/photos?page=1&page_size=20
Authorization: Bearer {access_token}
```

查询参数:
- `page`: 页码，默认 `1`
- `page_size`: 每页数量，默认 `20`，最大 `50`

权限:
- `owner` 与 `member` 只要可以访问该宠物档案，都可以查看列表

成功响应:

```json
{
  "photos": [
    {
      "id": 1,
      "pet_id": 1,
      "user_id": 12,
      "storage_key": "1/a1b2c3d4.jpg",
      "thumbnail_key": "1/a1b2c3d4_thumb.jpg",
      "thumbnail_url": "http://YOUR_SERVER_IP/media/pet-thumbnails/1/a1b2c3d4_thumb.jpg",
      "taken_at": "2024-01-15",
      "created_at": "2024-01-20T10:30:00Z"
    }
  ],
  "total": 150,
  "page": 1,
  "page_size": 20,
  "total_pages": 8
}
```

排序:
- 先按 `taken_at` 降序
- 再按 `created_at` 降序
- 如仍相同，可按 `id` 降序稳定排序

### 2.3 删除照片

```http
DELETE /api/v1/photos/{photo_id}
Authorization: Bearer {access_token}
```

成功响应:
- `204 No Content`

权限:
- 只要当前用户可以访问该照片所属宠物档案，就可以删除该照片
- 不区分该照片是否由当前用户上传

业务逻辑:
1. 查询 `photo_id`
2. 校验当前用户是否可以访问该照片所属宠物档案
3. 删除 MinIO 原图与缩略图
4. 删除数据库记录

推荐错误码:
- `404 PHOTO_NOT_FOUND`
- `403 PHOTO_FORBIDDEN`

### 2.4 获取照片原图 URL

```http
GET /api/v1/photos/{photo_id}/url
Authorization: Bearer {access_token}
```

成功响应:

```json
{
  "url": "http://YOUR_SERVER_IP/media/pet-photos/1/a1b2c3d4.jpg?X-Amz-...",
  "expires_in": 3600
}
```

说明:
- 该接口用于查看原图
- 原图通过 MinIO 预签名 URL 暴露，默认有效期 1 小时
- 返回给客户端的签名 URL 必须使用外部统一入口域名，不能泄露 MinIO 内部地址
- 缩略图则继续使用固定 `/media/...` 路径
- `owner` 与 `member` 只要可以访问该宠物档案，都可以获取原图 URL

---

## 3. 后端实现要点

### 3.1 路由职责划分

建议保留 `photos` 模块，但按职责拆分清楚:

- Step 4:
  - `POST /api/v1/pets/{pet_id}/photos`
  - `GET /api/v1/pets/{pet_id}/photos`
  - `DELETE /api/v1/photos/{photo_id}`
  - `GET /api/v1/photos/{photo_id}/url`
- Step 6:
  - `GET /api/v1/photos/timeline`

也就是说，Step 4 先完成“按宠物的照片管理”，Step 6 再完成“跨宠物聚合浏览”。

### 3.2 存储服务要求 (`app/services/storage.py`)

建议在现有 MinIO 封装上补齐以下能力:

- `upload_photo(...)`:
  - 上传原图到 `MINIO_BUCKET_PHOTOS`
  - 生成缩略图并上传到 `MINIO_BUCKET_THUMBNAILS`
  - 返回 `storage_key`、`thumbnail_key`
- `build_thumbnail_url(thumbnail_key)`:
  - 拼出缩略图公开 URL
- `get_photo_presigned_url(storage_key, expires_seconds=3600)`:
  - 生成原图签名 URL
- `delete_photo_objects(storage_key, thumbnail_key)`:
  - 删除原图和缩略图

实现要求:
- `pet-thumbnails` 允许公开读
- `pet-photos` 不依赖公开读，优先通过签名 URL 访问
- 缩略图统一转成 JPEG，尺寸上限 `400x400`，质量 `80`

### 3.3 图片识别服务 (`app/services/image_recognition.py`)

建议封装为独立服务，避免把第三方 SDK 逻辑直接塞进路由。

输出建议:

```python
class ImageRecognitionResult(TypedDict):
    is_pet: bool
    labels: list[str]
    skipped: bool
```

语义:
- `is_pet=True, skipped=False`: 明确识别为宠物图片
- `is_pet=False, skipped=False`: 明确识别为非宠物图片
- `is_pet=True, skipped=True`: 因服务异常或未配置而放行

### 3.4 错误处理风格

整个 Step 4 继续沿用项目统一错误结构:

```json
{
  "code": "SOME_ERROR",
  "message": "用户可读提示",
  "details": {}
}
```

注意:
- 请求级错误使用 `AppException`
- 文件级失败不抛整批异常，而是进入 `failures`
- 不再使用“整批抛 400 + `failed_index`”的旧设计

### 3.5 事务与一致性建议

因为本步骤采用“部分成功”策略，所以不做整批数据库回滚。

建议实现原则:
- 每个文件独立处理
- 单文件内部尽量保持“存储成功后再写库”
- 如果原图已上传但缩略图或写库失败，要尽量做该文件级补偿删除
- 失败文件不能影响同批次后续文件

---

## 4. Flutter「记录」页面

### 4.1 页面布局

```text
┌─────────────────────────────────┐
│  橘子 ▼    (宠物选择器)           │
├─────────────────────────────────┤
│                                 │
│  ┌─────┐ ┌─────┐ ┌─────┐      │
│  │     │ │     │ │  ＋  │      │
│  │ 📷  │ │ 📷  │ │ 添加 │      │
│  │     │ │     │ │     │      │
│  └──×──┘ └──×──┘ └─────┘      │
│  (已选照片预览，最多 5 张)         │
│                                 │
│  拍摄日期                        │
│  ┌─────────────────────────┐    │
│  │  2024-01-15    📅        │    │
│  └─────────────────────────┘    │
│  (默认取 EXIF，可手动修改)         │
│                                 │
│  ┌─────────────────────────┐    │
│  │       记录完成            │    │
│  └─────────────────────────┘    │
│                                 │
└─────────────────────────────────┘
```

### 4.2 交互流程

1. 页面初始状态:
   - 显示宠物选择器
   - 如果没有宠物档案，显示“请先创建宠物档案”的空状态与跳转入口
   - 照片区域默认显示一个「+」添加按钮
2. 选择照片:
   - 点击「+」弹出操作菜单: `从相册选择` / `拍照`
   - 相册支持多选，相机一次新增 1 张
   - 总数最多 5 张，超过上限时禁止继续添加
   - 每张缩略图右上角有删除按钮
3. HEIC/HEIF 处理:
   - 选图后先检查格式
   - 如果是 `HEIC/HEIF`，客户端先转为 `JPEG`
   - 转换后的临时文件继续参与 EXIF 处理与上传
4. 日期处理:
   - 初次选图后，自动从当前已选图片中提取**第一个有效 EXIF 日期**
   - 如果所有图片都没有 EXIF，默认当天
   - 日期框可手动修改，修改后将 `isDateManuallyEdited = true`
   - 当用户手动改过日期后，再继续加图或删图时，不再自动覆盖该日期
   - 只有在“清空全部已选图片”或“本次上传全部成功并重置页面”后，才把手动修改标记重置
5. 点击“记录完成”:
   - 必须满足“已选宠物 + 至少 1 张照片”
   - 提交期间禁用按钮和删除操作
   - 显示上传进度对话框
6. 处理上传结果:
   - 全部成功: 弹出 `SnackBar`，页面重置
   - 部分成功: 弹出结果摘要，移除成功项，保留失败项，方便用户重试
   - 全部失败: 保留全部已选图片，展示失败原因列表

### 4.3 EXIF 日期提取 (`frontend/lib/utils/exif_helper.dart`)

建议职责:
- `extractDate(File imageFile)`: 提取单张日期
- `extractFirstValidDate(List<File> files)`: 按顺序取第一张有效日期

优先字段:
1. `EXIF DateTimeOriginal`
2. `EXIF DateTimeDigitized`
3. `Image DateTime`

异常处理:
- 读取失败时返回 `null`
- 不要因为某一张 EXIF 解析失败影响整批选图

### 4.4 照片选择与预览组件

组件建议:
- `photo_picker_grid.dart`

功能要求:
- 展示本地缩略图
- 支持删除单张
- 当已选张数 < 5 时显示添加卡片
- 当已选张数 = 5 时隐藏添加卡片
- 支持为失败项显示错误角标或错误文案

### 4.5 上传进度展示

由于上传采用单次 `multipart/form-data` 请求，进度展示以**总字节百分比**为准，不以“第几张 / 第几张”作为唯一进度来源。

推荐展示:

```text
┌─────────────────────┐
│   正在上传照片...     │
│   ██████░░░░ 46%    │
│   共 5 张，请勿关闭页面 │
└─────────────────────┘
```

实现建议:
- 使用 Dio 的 `onSendProgress(sent, total)`
- UI 展示百分比和已选总张数
- 请求完成后关闭进度框，再处理成功/失败摘要

### 4.6 上传结果反馈

前端需要区分三种情况:

### 全部成功
- 提示: `记录完成，已上传 3 张照片`
- 页面行为:
  - 清空已选图片
  - 日期恢复为当天
  - `isDateManuallyEdited = false`

### 部分成功
- 提示: `已成功上传 2 张，失败 1 张`
- 页面行为:
  - 从已选列表中移除成功项
  - 保留失败项，便于用户删除或重新提交
  - 日期保持当前值，不自动重置
- 结果展示:
  - 至少展示失败文件名和失败原因

### 全部失败
- 提示: `本次未成功上传，请检查失败原因后重试`
- 页面行为:
  - 保留全部已选图片
  - 日期保持当前值

### 4.7 API 调用 (`frontend/lib/services/photo_service.dart`)

建议模型:

```dart
class PhotoUploadSuccess {
  final int index;
  final String filename;
  final Photo photo;
}

class PhotoUploadFailure {
  final int index;
  final String filename;
  final String code;
  final String message;
  final Map<String, dynamic>? details;
}

class PhotoUploadResponse {
  final List<PhotoUploadSuccess> successes;
  final List<PhotoUploadFailure> failures;
  final int successCount;
  final int failureCount;
  final int totalCount;
}
```

调用要求:
- 使用 `FormData`
- 所有文件字段都使用 `files`
- `taken_at` 按 `YYYY-MM-DD` 提交
- 使用 `onSendProgress` 更新上传进度

---

## 5. 需要创建或修改的文件清单

### 后端
- `backend/app/services/image_recognition.py` - 宠物图片校验服务
- `backend/app/services/storage.py` - 补充照片上传、缩略图、签名 URL、删除能力
- `backend/app/schemas/photo.py` - 补充照片响应模型与上传结果模型
- `backend/app/api/v1/photos.py` - 实现 Step 4 照片相关接口
- `backend/app/api/v1/router.py` - 确认 photos 路由注册

### 前端
- `frontend/lib/models/photo.dart` - 照片数据模型
- `frontend/lib/services/photo_service.dart` - 照片 API 服务
- `frontend/lib/screens/record/record_screen.dart` - 记录页面
- `frontend/lib/utils/exif_helper.dart` - EXIF 日期提取
- `frontend/lib/widgets/photo_picker_grid.dart` - 照片选择预览组件

---

## 6. 验收标准

- [ ] 后端 `POST /api/v1/pets/{id}/photos` 支持上传 1-5 张照片
- [ ] 上传接口采用 `200` + `successes` / `failures` 聚合返回
- [ ] 服务端会继续处理整批文件，不会因单张失败而提前中断
- [ ] 文件级失败会返回 `index`、`filename`、`code`、`message`、`details`
- [ ] 请求级错误与文件级失败语义清晰分离
- [ ] 后端正确验证文件类型 (`JPEG/PNG/WEBP`) 和大小 (`<= 15MB`)
- [ ] Flutter 在选择 `HEIC/HEIF` 时先转换为 `JPEG`
- [ ] 后端调用阿里云场景识别 API 校验图片是否包含宠物
- [ ] 识别明确不是宠物时，单文件进入 `failures`
- [ ] 识别服务异常时放行上传，不阻塞正常流程
- [ ] 后端自动生成缩略图并存储到 MinIO
- [ ] 后端 `GET /api/v1/pets/{id}/photos` 分页返回照片列表
- [ ] 后端 `DELETE /api/v1/photos/{id}` 删除照片及 MinIO 文件
- [ ] 后端 `GET /api/v1/photos/{id}/url` 返回原图签名 URL
- [ ] `owner` 与 `member` 都可以上传照片
- [ ] 只要能访问档案，`member` 也可以删除该档案下任意照片
- [ ] Flutter 记录页面展示宠物选择器和无档案空状态
- [ ] Flutter 可以从相册多选照片，并支持拍照追加
- [ ] Flutter 照片预览正确显示，可以删除单张
- [ ] Flutter 自动从 EXIF 提取日期并填入日期输入框
- [ ] Flutter 多张照片时使用第一个有效 EXIF 日期
- [ ] Flutter 手动修改日期后，不会因继续加图或删图而被自动覆盖
- [ ] Flutter 上传时显示总进度百分比
- [ ] 全部成功后页面重置
- [ ] 部分成功时保留失败项，便于重试
- [ ] Flutter 能正确展示非宠物图片等失败原因
