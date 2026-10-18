# 宠物档案数据导出

在已有宠物档案的编辑/查看页，`下载此档案全部数据` 位于删除档案或退出共享按钮上方。主人、编辑成员、查看成员均可使用。

弹窗默认勾选「照片」「记录」，可单选或多选；全部取消时禁用「下载」。点击「取消」关闭弹窗。开始导出后显示准备原图数量、打包和保存状态，禁止重复提交，并允许在系统保存窗口打开前取消。系统保存窗口中由系统提供取消操作。

## 文件内容

2026-10 自定义日常扩展：`records.routine_items` 同时保存预置、自定义及已删除事项的名称、周期、提醒开关和删除时间；日常历史增加 `routine_name`、`routine_deleted`，详见 [自定义日常事项](custom-daily-routines.md)。

所有组合均输出 `档案名.zip`，由用户通过系统文件选择器选择保存位置。文件名保留中文；路径分隔符、控制字符、Windows 非法字符和保留名称会被安全替换。

- 照片：`photos/照片ID.原扩展名`，包含该档案下所有成员上传的照片。保留服务器存储文件的字节和格式，不重新编码或缩小照片。当前上传流程本身会压缩照片，因此导出的「原图」指服务器保存的完整文件。
- 记录：ZIP 根目录下的 `档案名.json`，UTF-8 编码，包含 `schema_version`、`exported_at`、`timestamp_timezone`、`pet`、`records`。`pet` 包含基本资料、头像 URL、全部护理/驱虫周期及提醒开关；`records` 按 `weights`、`dewormings`、`vaccinations`、`routines` 保存完整历史。日期保持 `YYYY-MM-DD`，时间戳使用 UTC，体重保留 API 的精确十进制字符串。
- 同时导出时，JSON 额外提供 `photos` 清单，含照片 ID、档案 ID、创建人 ID、拍摄日期、创建时间及 ZIP 内的 `file` 路径。
- 只选记录时 ZIP 只有 JSON；只选照片时没有 JSON。无照片时生成空 `photos/` 目录；无健康记录时对应数组为空。
- 导出不包含登录凭据、邀请码、分享码或短期签名 URL。头像 URL 是基本资料字段，头像文件不作为相册照片额外打包。

## 实现

`GET /api/v1/pets/{pet_id}/export?photos=true&records=true` 返回版本化的数据清单；至少选择一项，否则返回 `400 EXPORT_EMPTY_SELECTION`。复用现有档案成员权限校验，非成员返回 403。服务端只读取数据，不生成 ZIP、不下载照片。

清单包含全部数据，不受页面分页限制。PostgreSQL 使用只读 REPEATABLE READ 事务，让档案资料和各类记录来自同一快照。原图仍通过既有 `/photos/{photo_id}/url` 获取临时地址。

App 优先使用 `OriginalPhotoCache` 的原图。缓存缺失时下载并缓存；复制到导出临时目录期间保护该文件不被 LRU 淘汰。之后在后台 isolate 中按文件流生成 ZIP，系统文件保存器按文件路径复制，避免把整个压缩包载入内存。导出临时目录会在成功、失败或取消后清理。取消导出不打断查看器正在共用的原图下载。

任何必需原图或数据获取失败都会终止导出，不会打开保存窗口或输出缺少数据的 ZIP；弹窗提示重试。重试可复用已下载原图。

## 验证

后端运行 `python -m pytest -q`；前端运行 `flutter test --no-pub` 和 `flutter analyze --no-pub`。后端测试环境使用 Python 3.11、requirements.txt，并安装 `dashscope==1.23.9`（新版 SDK 的导入弃用警告会触发现有全局 warnings-as-errors 规则）。

新增 API 测试覆盖三种成员角色、非成员/未登录/不存在档案、勾选组合、105 条/类数据完整性、排序、跨档案隔离及健康设置。客户端测试解码真实 ZIP 并比较照片字节、JSON 内容，覆盖单选/全选/空数据、121 张照片、失败重试、取消、保存失败、文件名安全、缓存命中、下载复用以及超缓存配额的原图保护。

原生 Android 保存流程使用合成数据和 App 内 loopback HTTP 服务，不连接生产服务。在已启动的专用测试模拟器上运行：

```powershell
cd frontend
python scripts/run_export_integration.py emulator-5554
```

若本机 ADB 的自动模拟器连接不稳定，可先执行 `adb connect 127.0.0.1:5555`，再将上面脚本的设备参数改为 `127.0.0.1:5555`。脚本使用 `flutter drive` 与独立驱动运行测试。

脚本操作系统文件保存窗口，验证取消以及主人/编辑/查看成员的导出，拉回实际保存的 ZIP，使用 Python zipfile 校验 CRC、原图字节、健康记录及配置。日志、窗口截图及压缩包存放于忽略提交的 `frontend/build/export-integration/`。

Android 构建兼容配置同时修正了 TFLite 0.11 在 Flutter 3.44 / JDK 21 下的 Java/Kotlin 字节码目标不一致问题，保留 Java 8 目标。回归测试中也修正了旧时间轴测试仍按月份断言、缓存测试使用 Unix 路径分隔符、档案 CRUD 测试未隔离 MinIO 的问题。

此功能无需数据库迁移；发布 App 前需要更新后端以提供新的 export 接口。当前本机为 Windows，原生验证覆盖 Android 模拟器；iOS 的原生保存窗口仍需在 macOS/iOS 环境验证。

2026-10-18 本机验证结果：后端 194 项、Flutter 单元/组件 65 项测试通过，静态分析无问题，正式 App 入口的 Android debug APK 构建成功；Android 15 模拟器完成系统取消、三种角色保存、原图缓存请求次数检查，以及三份实际 ZIP 的独立 CRC/文件字节/JSON 校验。
