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

## 当前实现基线与提交对照

当前 Step 4 的代码基线不是单一提交，而是以下几次提交叠加后的结果；后续 agent 应以**当前代码实现**为准，而不是只看最早设计稿:

- `14adfff Step4 code commit`
  - 后端落地照片上传、列表、删除、原图 URL 四个接口
  - 新增 `image_recognition.py` 与 `storage.py` 的照片上传/缩略图/签名 URL 能力
  - 前端新增 `Photo` 模型、`PhotoService`、`RecordScreen`、`ExifHelper`
  - Nginx 补齐 `/media/` 代理，使缩略图与签名 URL 能通过统一入口访问
- `eb33b23 Change UI of recoding and fix upload bug`
  - 上传协议从“整批共用一个 `taken_at`”调整为“每张照片各自提交一个 `taken_at`”
  - 记录页 UI 改成纵向照片卡片，每张照片独立显示和修改日期
  - FastAPI 校验错误序列化做了兼容处理，避免错误详情里出现不可 JSON 化对象
  - 前后端/Nginx 增加上传超时配置，减少大图上传时的超时报错
- `bc5f59f Fix multi upload bug`
  - 后端把图片识别和 MinIO 上传包进 `asyncio.to_thread(...)`，避免阻塞事件循环
  - 前端与 Nginx 接收超时继续放宽到 `300s`，提升多图上传成功率
  - 记录页保留“失败项继续重试”的逻辑，同时修正多图场景下的交互细节
- `34b1372 Fix image recognotion too slow`
  - 阿里云识别前先把图片压缩到较小 JPEG，再发识别请求
  - 识别客户端改成单例缓存，避免每张图重复初始化 SDK Client
  - 为识别请求加 `connect_timeout=5s`、`read_timeout=15s`，慢请求异常时继续按“放行上传”策略处理

与 Step 4 无直接关系的后续提交（例如 Android SDK 配置）不在本文档范围内。

---

## 0. 本步骤关键约定

这些约定已经在 Step 4 细化中确认，后续实现默认按此执行:

- 共享档案中，`owner` 和 `member` 都可以上传照片
- 删除照片时，只要当前用户可以访问该宠物档案，就可以删除该档案下任意照片
- 批量上传采用**部分成功**策略，不做整批回滚
- 上传接口统一返回 `200`，用 `successes` / `failures` 表达结果
- 服务端处理文件时要**继续处理完整批次**，不能遇到第一张失败就中断
- 阿里云识别服务异常、超时、未配置时，**放行上传**，优先保证主流程可用
- 当前实现中，`taken_at` 是**与文件一一对应的数组字段**，每张照片有自己的拍摄日期
- 上传响应中保留 `storage_key`、`thumbnail_key`
- 当前实现已把图片识别和存储上传放到工作线程中执行，避免阻塞 FastAPI 异步请求
- 当前上传链路的超时基线是: 前端 `sendTimeout=120s`、`receiveTimeout=300s`，Nginx `proxy_read_timeout=300s`

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
- `taken_at`: 拍摄日期字段，格式 `YYYY-MM-DD`，**需要重复提交多次**，数量必须和 `files` 一致

支持的图片格式:
- JPEG
- PNG
- WEBP

补充说明:
- 如果用户选择 `HEIC/HEIF`，Flutter 端先转换为 `JPEG`
- 上传接口只负责写入照片记录，不负责时间轴聚合
- `owner` 与 `member` 只要能访问该宠物档案，都可以上传
- 当前实现按表单顺序把 `taken_at[i]` 对应到 `files[i]`

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
- `400 VALIDATION_ERROR`: `multipart/form-data` 缺少必填字段，或 FastAPI 基础校验失败
- `400 EMPTY_UPLOAD`: 没有上传任何文件
- `400 TOO_MANY_FILES`: 一次上传超过 5 张
- `400 TAKEN_AT_MISMATCH`: `taken_at` 数量与 `files` 数量不一致
- `400 INVALID_TAKEN_AT`: 某个 `taken_at` 不是合法 `YYYY-MM-DD`
- `403 PET_FORBIDDEN`: 当前用户无权访问该宠物档案
- `404 PET_NOT_FOUND`: 宠物档案不存在

以下情况属于**文件级失败**，写入 `failures`，请求本身仍返回 `200`:
- `UNSUPPORTED_IMAGE_TYPE`
- `FILE_TOO_LARGE`
- `PET_NOT_DETECTED`
- `PHOTO_UPLOAD_FAILED`

说明:
- 当前实现没有把“缩略图生成失败”单独区分成独立错误码，统一折叠到 `PHOTO_UPLOAD_FAILED`

如果一批次中所有文件都失败，但请求本身合法，也仍然返回 `200`，此时:
- `success_count = 0`
- `failure_count = total_count`

#### 2.1.3 处理流程

1. 校验当前用户是否可以访问 `pet_id`
2. 校验请求级条件:
   - `files` 非空
   - 文件总数不超过 5
   - `taken_at` 数量与文件数一致
   - 每个 `taken_at` 都能解析为合法日期
3. 按顺序遍历每个文件，**继续处理完整批次**
4. 单文件处理流程:
   - 校验类型是否为 `image/jpeg`、`image/png`、`image/webp`
   - 校验文件大小是否 <= 15MB
   - 在工作线程中调用阿里云 `RecognizeScene` 判断是否包含猫或狗
   - 如果明确识别为非宠物，则写入 `failures`
   - 如果识别服务异常、超时或未配置，则记录日志并继续上传
   - 生成 UUID 文件名
   - 在工作线程中上传原图到 `pet-photos`
   - 生成缩略图并上传到 `pet-thumbnails`
   - 创建 `photos` 表记录
   - 该条记录的 `taken_at` 使用当前文件对应的 `parsed_dates[idx]`
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
- 当前实现会先把图片压缩到约 `800x800` 的 JPEG（质量 `70`）再调用识别接口
- 当前实现会复用单例 Aliyun Client，并为识别请求设置连接/读取超时

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
- FastAPI `RequestValidationError` 也会被统一转成 `400` + 结构化错误体；当前实现会把 `loc` / `msg` / `type` 都转换成可 JSON 序列化的字符串结构
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
│  [初始态]                         │
│  点击添加照片                     │
│  支持从相册选择或拍照，最多 5 张     │
│                                 │
│  [选择后]                         │
│  ┌─────────────────────────┐    │
│  │        照片预览          │    │
│  │                  ×       │    │
│  ├─────────────────────────┤    │
│  │  📅 2024-01-15      >    │    │
│  └─────────────────────────┘    │
│  (每张照片单独一张卡片)            │
│                                 │
│  [继续添加照片]                   │
│                                 │
│  [底部固定按钮: 记录完成]          │
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
   - 当前实现为纵向卡片列表，每张卡片右上角有删除按钮
3. HEIC/HEIF 处理:
   - 选图后先检查格式
   - 如果是 `HEIC/HEIF`，客户端先转为 `JPEG`
   - 转换后的临时文件继续参与 EXIF 处理与上传
4. 日期处理:
   - 当前实现是**每张照片单独维护一个日期**
   - 从相册选择时，会逐张调用 `ExifHelper.extractDate(file)` 提取 EXIF 日期
   - 单张提取失败时，该照片日期回退为 `DateTime.now()`
   - 当前拍照分支直接以 `DateTime.now()` 作为默认日期，没有再读相机返回文件的 EXIF
   - 每张卡片底部都有自己的日期行，点击后可单独修改该照片日期
   - 添加或删除其它照片时，不会覆盖已存在照片的日期；删除照片时同步移除其日期
5. 点击“记录完成”:
   - 必须满足“已选宠物 + 至少 1 张照片”
   - 提交期间禁用按钮和删除操作
   - 显示上传进度对话框
6. 处理上传结果:
   - 全部成功: 弹出 `SnackBar`，页面重置
   - 部分成功: 弹出结果摘要，移除成功项，保留失败项及其日期，方便用户重试
   - 全部失败: 保留全部已选图片，并把失败原因显示在对应照片卡片的底部遮罩上

### 4.3 EXIF 日期提取 (`frontend/lib/utils/exif_helper.dart`)

当前实现提供的能力:
- `extractDate(File imageFile)`: 提取单张日期
- `extractFirstValidDate(List<File> files)`: 按顺序取第一张有效日期

优先字段:
1. `EXIF DateTimeOriginal`
2. `EXIF DateTimeDigitized`
3. `Image DateTime`

异常处理:
- 读取失败时返回 `null`
- 不要因为某一张 EXIF 解析失败影响整批选图

当前页面实际用法:
- `record_screen.dart` 当前使用的是 `extractDate(...)`，按照片逐张初始化默认日期
- `extractFirstValidDate(...)` 仍保留在工具类中，但当前记录页未使用这条逻辑

### 4.4 照片选择与预览组件

当前实现说明:
- 当前记录页的照片卡片列表直接写在 `record_screen.dart` 中
- `photo_picker_grid.dart` 虽然在主提交中创建过，但当前页面并**未直接引用**这个组件，后续 agent 不要误以为它是现行主路径 UI

功能要求:
- 展示本地预览图
- 支持删除单张
- 当已选张数 < 5 时显示“继续添加照片”入口
- 当已选张数 = 5 时隐藏继续添加入口
- 失败项在图片底部显示错误文案遮罩

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
- 当前实现使用 `ValueNotifier<double>` 驱动进度弹窗刷新
- UI 展示百分比和已选总张数
- 请求完成后关闭进度框，再处理成功/失败摘要

### 4.6 上传结果反馈

前端需要区分三种情况:

### 全部成功
- 当前提示: `上传成功，请在时间轴内查看吧！`
- 页面行为:
  - 清空已选图片
  - 清空每张照片的日期状态
  - 清空失败消息

### 部分成功
- 提示: `已成功上传 2 张，失败 1 张`
- 页面行为:
  - 从已选列表中移除成功项
  - 保留失败项，便于用户删除或重新提交
  - 失败项对应日期一并保留
- 结果展示:
  - 当前实现会把失败原因映射到保留后的卡片索引，并显示在卡片底部

### 全部失败
- 提示: `本次未成功上传，请检查失败原因后重试`
- 页面行为:
  - 保留全部已选图片
  - 保留全部已选日期
  - 按原索引展示失败原因

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
- `taken_at` 按 `YYYY-MM-DD` 重复追加到 `formData.fields`
- `taken_at` 数量必须与 `files` 一致
- 使用 `onSendProgress` 更新上传进度
- 当前实现超时配置为 `sendTimeout=120s`、`receiveTimeout=300s`

---

## 5. 需要创建或修改的文件清单

### 后端
- `backend/app/services/image_recognition.py` - 宠物图片校验服务
- `backend/app/services/storage.py` - 补充照片上传、缩略图、签名 URL、删除能力
- `backend/app/schemas/photo.py` - 补充照片响应模型与上传结果模型
- `backend/app/api/v1/photos.py` - 实现 Step 4 照片相关接口
- `backend/app/api/v1/router.py` - 确认 photos 路由注册
- `backend/app/main.py` - 补充 Step 4 上传场景依赖的请求校验错误序列化兼容

### 前端
- `frontend/lib/models/photo.dart` - 照片数据模型
- `frontend/lib/services/photo_service.dart` - 照片 API 服务
- `frontend/lib/screens/record/record_screen.dart` - 记录页面
- `frontend/lib/utils/exif_helper.dart` - EXIF 日期提取
- `frontend/lib/widgets/photo_picker_grid.dart` - 早期创建的照片选择组件，当前记录页未直接使用

### 网关
- `nginx/nginx.conf` - 统一入口 `/media/` 代理与上传超时配置

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
- [ ] Flutter 从相册选择时，会为每张照片单独尝试提取 EXIF 日期
- [ ] 单张照片 EXIF 缺失或解析失败时，会回退到当前时间
- [ ] Flutter 支持逐张修改照片日期，且不会因继续加图或删图覆盖其它照片日期
- [ ] Flutter 上传时显示总进度百分比
- [ ] 全部成功后页面重置
- [ ] 部分成功时保留失败项及其日期，便于重试
- [ ] Flutter 能正确展示非宠物图片等失败原因
