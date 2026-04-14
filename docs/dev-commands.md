# 开发常用命令手册

## 一、服务启停

### Docker 容器（PostgreSQL、Redis、MinIO、Nginx）

```bash
# 启动所有容器
cd ~/DangDangDiary && docker compose up -d

# 查看容器状态
docker compose ps

# 停止所有容器
docker compose down

# 查看某个容器日志（如 nginx）
docker logs dangdang-nginx

# 重启某个容器
docker compose restart nginx
```

### FastAPI 后端

```bash
# 启动（开发模式，代码修改自动重载）
cd ~/DangDangDiary/backend && source .venv/bin/activate && uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

# 后台端口被占用时，先查找并杀掉旧进程
lsof -i :8000
kill <PID>
```

### 完整启动流程（建议在 tmux 中执行）

```bash
# 1. 启动 Docker 容器
cd ~/DangDangDiary && docker compose up -d

# 2. 启动后端
cd ~/DangDangDiary/backend && source .venv/bin/activate && uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

---

## 二、tmux 会话管理

```bash
# 创建会话
tmux new -s services     # 跑 Docker + 后端
tmux new -s claude        # 跑 Claude CLI

# 脱离当前会话（不停止程序）
Ctrl+B，松手，按 D

# 查看所有会话
tmux ls

# 重新进入会话
tmux a -t services
tmux a -t claude

# 翻看会话内的历史输出
Ctrl+B，松手，按 [，用方向键/PgUp 翻页，按 Q 退出

# 关闭会话（会停掉里面的程序）
tmux kill-session -t 会话名
```

---

## 三、Flutter / APK 编译

### 编译 debug APK

```bash
cd ~/DangDangDiary/frontend

# 使用默认 baseUrl（10.0.2.2，模拟器用）
flutter build apk --debug

# 指定服务器 IP（真机测试用，替换为你的实际 IP）
flutter build apk --debug --dart-define=BASE_URL=http://你的服务器IP
```

编译产物路径：`frontend/build/app/outputs/flutter-apk/app-debug.apk`

### 编译 release APK

```bash
flutter build apk --release --dart-define=BASE_URL=http://你的服务器IP
```

### 代码检查（不编译，速度快）

```bash
cd ~/DangDangDiary/frontend && flutter analyze
```

### 安装依赖

```bash
cd ~/DangDangDiary/frontend && flutter pub get
```

### 编译后清理 Gradle 残留（释放内存）

```bash
# 查看是否有 Java 进程残留
ps aux | grep java | grep -v grep

# 杀掉所有 Gradle daemon
pkill -f gradle
```

---

## 四、数据库操作

### Alembic 迁移

```bash
cd ~/DangDangDiary/backend && source .venv/bin/activate

# 修改模型后生成迁移文件
alembic revision --autogenerate -m "描述修改内容"

# 执行迁移（升级到最新）
alembic upgrade head

# 回退一个版本
alembic downgrade -1

# 查看当前版本
alembic current

# 查看迁移历史
alembic history
```

### 直接操作 PostgreSQL

```bash
# 进入 psql 命令行
docker exec -it dangdang-postgres psql -U dangdang -d dangdang

# 常用 SQL（在 psql 内）
\dt              -- 列出所有表
\d users         -- 查看 users 表结构
SELECT * FROM users;
\q               -- 退出
```

### 直接操作 Redis

```bash
# 进入 redis-cli
docker exec -it dangdang-redis redis-cli

# 常用命令（在 redis-cli 内）
KEYS *           -- 查看所有 key
GET key名        -- 获取值
FLUSHALL         -- 清空所有数据（慎用）
quit             -- 退出
```

---

## 五、MinIO 操作

```bash
# 查看所有 bucket
~/mc ls dangdang

# 查看某个 bucket 内容
~/mc ls dangdang/pet-photos

# 上传文件
~/mc cp 本地文件 dangdang/pet-photos/

# 删除文件
~/mc rm dangdang/pet-photos/文件名
```

MinIO Web 控制台：浏览器访问 `http://服务器IP:9001`，账号 `minioadmin`，密码 `minioadmin123`

---

## 六、后端依赖管理

```bash
cd ~/DangDangDiary/backend && source .venv/bin/activate

# 安装所有依赖
pip install -r requirements.txt

# 新增依赖后更新 requirements.txt
pip install 包名
pip freeze > requirements.txt
```

---

## 七、APK 传到手机安装

### 方案 A：Windows 用 scp 下载后 adb 安装

```cmd
# Windows 命令行
scp 用户名@服务器IP:~/DangDangDiary/frontend/build/app/outputs/flutter-apk/app-debug.apk C:\Users\你的用户名\Downloads\
adb install C:\Users\你的用户名\Downloads\app-debug.apk
```

### 方案 B：adb 连接手机后从服务器直接安装

```bash
# 在服务器上（需要先通过 adb connect 连接手机）
adb install ~/DangDangDiary/frontend/build/app/outputs/flutter-apk/app-debug.apk
```

### 方案 C：手动传到手机

用 WinSCP / FileZilla 从服务器下载 APK，通过微信/网盘/USB 传到手机安装。

---

## 八、验证服务是否正常

```bash
# 后端健康检查
curl http://localhost:8000/health
# 期望：{"status":"ok"}

# 通过 Nginx 代理访问
curl http://localhost/api/v1/pets
# 期望：{"pets":[]}

# Swagger 文档
# 浏览器访问 http://服务器IP/docs

# PostgreSQL
docker exec dangdang-postgres pg_isready -U dangdang

# Redis
docker exec dangdang-redis redis-cli ping
# 期望：PONG

# 内存使用情况
free -m
```

---

## 九、Git 操作

```bash
cd ~/DangDangDiary

# 查看状态
git status

# 添加并提交
git add -A
git commit -m "提交说明"

# 查看日志
git log --oneline -10
```

---

## 十、系统排障

```bash
# 查看内存使用
free -m

# 查看占内存最多的进程
ps aux --sort=-%mem | head -10

# 查看磁盘空间
df -h

# 查看 Docker 占用空间
docker system df

# 清理 Docker 无用镜像/缓存（释放磁盘）
docker system prune -a
```
