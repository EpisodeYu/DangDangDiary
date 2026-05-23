# Optimizations · Batch 1

本文件夹收录 Phase 1 收尾 / Phase 2 当前进度下的一批小型优化任务规划。每个 step 文档对应一个独立的优化点，agent 可以按顺序逐个实施，也可以并行（除非文档明确标注依赖）。

文档命名沿用 `stepN-xxx.md` 风格，但不与 `docs/step1~step8` 或 `docs/phase2-stepN-xxx.md` 共享编号，仅在本目录内有效。

## Step 列表

| 文档 | 主题 | 改动规模 | 是否破坏性 | 状态 |
|------|------|----------|------------|------|
| [`step1-disable-pet-recognition.md`](./step1-disable-pet-recognition.md) | 关闭上传时的猫狗内容识别（前端 TFLite + 后端 RecognizeScene），保留代码以备未来恢复 | 极小（仅切换开关 + 修文案） | 否，仅放宽放行规则 | ✅ 已落地 |
| [`step2-timeline-group-by-day.md`](./step2-timeline-group-by-day.md) | 时间轴内容按「日」分组（无照片的日子不显示），右侧月级 scrollbar 保留 | 中等（后端 service + 前后端 schema 注释 + 前端 provider/widget 调整） | **是**，`groups[].date` 字段语义从 `"YYYY-MM"` 变为 `"YYYY-MM-DD"`，前后端原子升级 | ✅ 已落地（pytest 189/189，实机滚动需人测） |
| [`step3-share-qr-code.md`](./step3-share-qr-code.md) | 档案分享码生成 QR、保存图片到相册；新增宠物档案页支持扫码/相册图片识别加入档案 | 较大（新依赖 + 新 UI + 自定义合成图） | 否，新增功能 | ✅ 已落地（实机权限弹窗需人测） |
| [`step4-pet-role-silent-sync.md`](./step4-pet-role-silent-sync.md) | 修复「拥有者赋权后被分享用户感知不到」的 bug：silent refresh + diff 后再替换 state，零页面闪动 | 中等（pet_provider 重写 + 多入口触发 + 403 兜底） | 否，纯客户端 | ✅ 已落地（health 模块 403 文案统一推迟） |
| [`step5-save-photo-to-gallery.md`](./step5-save-photo-to-gallery.md) | 时间轴 / 大图查看器长按 sheet 新增「保存原图到相册」（与删除按钮平级） | 小（新依赖 + 两处 sheet 接入 + 权限文案） | 否，新增功能 | ✅ 已落地 |
| [`step6-ui-polish.md`](./step6-ui-polish.md) | 前端质感提升（无美工方案）：圆润图标、双层柔阴影、列表入场动画、骨架屏、底栏自绘 + haptic、时间轴胶带日期标签 | 较大（30+ 文件 + 4 个新 widget + 2 个新依赖） | 否，纯客户端视觉层 | 🟡 第一轮已落地，§5 放大方案待取用 |

## 推荐实施顺序

1. **Step 1**（5 分钟）：开关切换，立刻可验证
2. **Step 5**（半天）：纯加按钮 + 调系统相册 API，最快出结果，跟现有删除按钮平级，前端体验立刻好
3. **Step 4**（半天 ~ 一天）：silent refresh 是 Step 3 / 后续多人协作场景的基础，先做完体验直线上升
4. **Step 3**（一天 ~ 两天）：依赖新依赖与多种系统权限，单独迭代
5. **Step 2**（一天）：涉及前后端原子升级 + 时间轴重建 + scrollbar 逻辑梳理，单独打 PR

> 注：Step 2 与 Step 3 没有严格依赖关系，但都属于较大改动，建议拆开 PR 评审。Step 4 在 Step 3 完成后会被高频触发（owner 改完权限后立刻分享 QR 给对方），先做 Step 4 体验更连贯。

## 全局对齐

所有 step 都遵循 `docs/00-global-rules.md` 与 `docs/CLAUDE.md` 的约束，重点提醒：

- 前端只通过 Nginx 入口访问后端（不要直连 FastAPI / MinIO 内部地址）
- 后端响应字段保持 `snake_case`，时间戳 UTC，日期字段用 `date`
- 错误结构 `{ "code", "message", "details" }`，权限不足统一 `PET_OWNER_REQUIRED` / `PET_EDITOR_REQUIRED`
- 新增依赖在文档内列出原因 + 版本范围
- 新增数据库迁移必须配套 `alembic revision`

## 关键产品决策（已与产品负责人对齐）

每个 step 文档开头都会重复列出决策点 + 选定方案 + 理由，方便单独阅读。这里给出全局摘要：

- Step 1 取舍：**保留代码、仅关闭开关**（不删除 `pet_classifier.dart`、`image_recognition.py`、TFLite 资源、依赖），便于未来若需要重新启用直接翻 flag。
- Step 2 取舍：右侧 scrollbar **仍按月**跳转，正文按日分组——长时间轴下日级 scrollbar 过密、按月跳更符合 iOS Photos / 微信收藏的成熟交互。
- Step 3 取舍：QR 协议采用 **HTTPS URL** (`https://dangdangdiary.app/s/<code>`)，便于未来加 Web 落地页同时兼容只装了 App 的用户；保存的 QR 图卡片包含 Logo + DangDangDiary 字样 + 宠物名 + 过期时间 + 一句邀请文案。
- Step 4 取舍：**Silent refresh + 差异比对**——`silentRefresh()` 后台 fetch，比对 (id, role, share_code_active, name, breed, birthday, avatar_url, owner_id) 后只在变化时 `state = AsyncData(new)`；触发点 = 进入编辑页 + App 回到前台 + 写操作收到 403。**绝不**触发 `AsyncLoading`。
- Step 5 取舍：仅支持**单张保存**（时间轴长按 sheet 与大图查看器长按 sheet 都加），与「删除」按钮平级；不在多选模式扩展批量保存（避免操作面板过载）。
- Step 6 取舍：放弃了 `phosphor_flutter`（在 Flutter 3.44 下 `extends IconData` 编译失败、无维护中 fork），回退到 Material `*_rounded` 变体；放弃中文字体 / AI 生图 / 文案温度化（不在"无美工"严格约束内，单独走新 step doc）。第一轮自评见 §2.1 ——"60% 的代码量贡献了 <10% 的感官变化"，二轮放大方案（§5）单独评审实施。

## 完成报告

落地后请阅读 [`COMPLETION_REPORT.md`](./COMPLETION_REPORT.md)，包含：
- 变更文件清单（新建 13 / 修改 17）
- 9 项风险（含「占位域名」「前端 flutter analyze 未跑」「mobile_scanner 7.x API 版本敏感」等）
- 必须人测清单（P0 二维码全链路 + 双账号权限感知 / P1 单账号回归 / P2 平台兼容）
- 部署建议与待办

## 不在本批次范围内的内容

- 真正的实时推送（WebSocket / FCM / MiPush）——`docs/future-async-task-queue.md` 已记录，本批次不引入。
- 时间轴的二级 chip（月内按日折叠展开）——交互复杂，等 Phase 2 收尾再讨论。
- QR 码扫码后的 Web 落地页（无 App 时引导下载）——需要先有官网域名 + 备案，本批次不做，但协议格式已为未来兼容预留。
- 批量保存原图、保存到自定义相册等高级图库功能——本批次不做。
