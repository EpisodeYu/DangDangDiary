# 部署与运维（Deploy / Ops）

> 本机线上部署的日常运维手册。记录「怎么起、怎么重启、怎么迁移、踩过哪些坑」。
> 与 `docs/step1-environment-setup.md`（首次搭环境）互补：那篇讲从零搭，这篇讲长期运维。

## 拓扑现状（2026-05-26 起）

```
手机 → ingress-nginx (:80/:443, ~/infra/ingress, 终止 TLS, 按 Host 分流)
          └─ dangdang-nginx:80   （本项目入口，仅 compose 网络内可达）
               ├── /api/...      → fastapi:8000   （compose 服务名直连）
               ├── /docs /openapi.json → fastapi:8000
               └── /media/...    → minio:9000
```

整个后端栈都在 `docker-compose.yml` 里，**全部容器化**，包括 FastAPI 本身：

| 容器 | 服务名 | 说明 |
|------|--------|------|
| `dangdang-fastapi` | `fastapi` | 业务后端。`build: ./backend`，绑定挂载源码 + `--reload`，`restart: unless-stopped`，crash / 重启会自动拉起 |
| `dangdang-nginx` | `nginx` | 本项目入口，`expose: 80`（不再发布到宿主机，80 由 ingress 接管） |
| `dangdang-postgres` | `postgres` | PostgreSQL 16 + pgvector |
| `dangdang-redis` | `redis` | Redis 7（AOF） |
| `dangdang-minio` | `minio` | S3 兼容对象存储 |

> 历史：2026-05-26 前 FastAPI 是宿主机裸进程（`nohup uvicorn ... :8000`），nginx 经
> `host.docker.internal:8000` 回连宿主机。已收进 compose，**不要再手动起宿主机 uvicorn**，
> 否则会和容器抢 8000 端口。

## 日常运维

```bash
# 起 / 停整栈
docker compose up -d
docker compose down                 # 不带 -v，数据卷保留

# 只重启后端（改了 .env / 需要重读配置时）
docker compose restart fastapi

# 看日志
docker compose logs -f fastapi
docker compose ps                   # 各容器状态

# 改了 requirements.txt 才需要重建镜像
docker compose build fastapi && docker compose up -d fastapi
```

- **改业务代码**：`./backend` 绑定挂载 + `uvicorn --reload`，**自动热重载，无需任何操作**。
- **改 `.env`**：不会热加载，`docker compose restart fastapi`。
- **改 `requirements.txt`**：要 `build` 重新装依赖。

### 数据库迁移

`.env` 里的地址是 compose **服务名**（`postgres` / `redis` / `minio`），宿主机直接跑
`alembic` 解析不了这些主机名。迁移要在容器里跑：

```bash
docker compose exec fastapi alembic upgrade head
docker compose exec fastapi alembic revision --autogenerate -m "xxx"
```

## 配置约定（容易踩的坑）

### 1. `.env` 用服务名，不是 `127.0.0.1`

FastAPI 在容器里，`127.0.0.1` 指向容器自己。所有内部地址必须用 compose 服务名：

```ini
DATABASE_URL=postgresql+asyncpg://dangdang:***@postgres:5432/dangdang
REDIS_URL=redis://redis:6379/0
MINIO_ENDPOINT=minio:9000
```

### 2. `PUBLIC_BASE_URL` = 对外域名

后端返回给前端的所有媒体 URL（缩略图、原图预签名、**头像**）都是
`f"{PUBLIC_BASE_URL}/media/..."` 拼出来的，**响应时即时拼接**：DB 里只存
bucket 相对 object key，绝对 URL 在序列化时由 `storage.build_thumbnail_url` /
`get_photo_presigned_url` / `build_avatar_url` 组装。**换域名 / 切 HTTPS 无需迁移数据。**

```ini
PUBLIC_BASE_URL=https://dangdangdiary.org
```

> 换域名只需改这一行 + `docker compose restart fastapi`。前端的 `BASE_URL` 是编译期
> `--dart-define` 注入的，见 README §6.4 / `frontend/lib/config/constants.dart`。
>
> ⚠️ **历史坑（2026-05-26 已修）**：头像曾经把**绝对 URL** 整条存进
> `users.avatar_url` / `pets.avatar_url`，换域名后旧头像全变死链（缩略图/原图因为存 key
> 反而自愈了，对比之下更隐蔽）。已重构为存 key + `build_avatar_url` 响应时拼接，并由迁移
> `c9d0e1f2a3b4` 把存量绝对 URL 改写成 key。**以后任何新的"媒体 URL"字段都不要存绝对 URL。**

### 3. ⚠️ `MINIO_ENDPOINT` 必须与 nginx `/media/` 的 `Host` 头一致

原图和语音用的是 **host-signed 预签名 URL**：MinIO SigV4 签名把 host 算进签名里。
- 后端用 `MINIO_ENDPOINT`（=`minio:9000`）签名；
- nginx 反代 `/media/` 时用 `proxy_set_header Host ...` 决定给 MinIO 的 Host。

两者必须**完全相等**，否则 MinIO 返回 `SignatureDoesNotMatch`（403），表现为
**缩略图能显示（公共 bucket 不验签）、但原图打不开**。

```nginx
location /media/ {
  proxy_pass http://minio:9000/;
  proxy_set_header Host minio:9000;   # 必须 == 后端 MINIO_ENDPOINT
}
```

> 语音转写给 DashScope 拉取的 URL 是另一条路（`_get_voice_public_client` 直连
> `<PUBLIC_BASE_URL host>:9000`，不走 nginx），由 `MINIO_PUBLIC_ENDPOINT` 控制，留空时
> 从 `PUBLIC_BASE_URL` 推导。改 `MINIO_ENDPOINT` 不影响这条路。

## 切换后的冒烟验证

```bash
# 1) 域名 → nginx → fastapi（无 token 预期 401）
curl -s -o /dev/null -w "%{http_code}\n" "https://dangdangdiary.org/api/v1/pets?page=1&page_size=1"

# 2) 容器能连到 PG / Redis / MinIO
docker compose exec fastapi python -c "import socket;[print(h,(lambda s:(s.settimeout(3),s.connect((h,p)),'OK')[-1])(socket.socket())) for h,p in [('postgres',5432),('redis',6379),('minio',9000)]]"

# 3) 媒体两条路都要过：缩略图（公共，200）+ 原图预签名（验签，200）
#    用 docker compose exec fastapi python 调 storage.build_thumbnail_url /
#    storage.get_photo_presigned_url 取一个真实 key，再 curl 经域名拉，确认都是 200 image/jpeg。
```
