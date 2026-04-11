# Step 0: 开发环境手动搭建指南

本文档指导你在 Ubuntu 服务器上搭建「当当日记」的完整开发环境。
预计耗时 30-60 分钟（取决于网络速度）。

---

## 一、系统基础工具

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl wget unzip xz-utils zip \
  build-essential libssl-dev zlib1g-dev \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev
```

### 验收
```bash
git --version    # 应输出 git version 2.x+
curl --version   # 应输出 curl 7.x+ 或 8.x+
```

---

## 二、Docker + Docker Compose

```bash
# 卸载旧版本（如有）
sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null

# 安装 Docker 官方版
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# 将当前用户加入 docker 组（免 sudo 运行 docker）
sudo usermod -aG docker $USER

# 【重要】退出并重新登录 SSH，使组权限生效
exit
# 重新 SSH 登录后继续
```

### 验收
```bash
docker --version          # 应输出 Docker version 24.x+ 或 27.x+
docker compose version    # 应输出 Docker Compose version v2.x+
docker run hello-world    # 应成功拉取并运行，无需 sudo
```

如果 `docker run hello-world` 提示权限错误，确认你已重新登录。

---

## 三、Python 3.11+

```bash
# 检查系统自带版本
python3 --version

# 如果版本 >= 3.11，跳过安装
# 如果版本 < 3.11，使用 deadsnakes PPA 安装:
sudo apt install -y software-properties-common
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt update
sudo apt install -y python3.11 python3.11-venv python3.11-dev

# 设置 python3.11 为默认 python3（可选，按需）
sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1

# 安装 pip
curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11
```

### 验收
```bash
python3.11 --version     # 应输出 Python 3.11.x
python3.11 -m pip --version  # 应输出 pip 2x.x
```

---

## 四、Java JDK 17（Android 编译需要）

```bash
sudo apt install -y openjdk-17-jdk
```

### 验收
```bash
java -version    # 应输出 openjdk version "17.x.x"
```

---

## 五、Android SDK（命令行工具，不装 Android Studio）

由于你在服务器上开发（无桌面环境），只需安装命令行工具。

```bash
# 创建 Android SDK 目录
mkdir -p ~/Android/Sdk/cmdline-tools

# 下载最新的 commandlinetools（检查官网获取最新链接）
cd /tmp
wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
unzip commandlinetools-linux-11076708_latest.zip
mv cmdline-tools ~/Android/Sdk/cmdline-tools/latest

# 配置环境变量
cat >> ~/.bashrc << 'EOF'

# Android SDK
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SDK_ROOT=$HOME/Android/Sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
export PATH=$PATH:$ANDROID_HOME/platform-tools
EOF

source ~/.bashrc

# 安装必要的 SDK 组件（需要同意许可协议，输入 y）
sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0"

# 同意所有许可协议
yes | sdkmanager --licenses
```

### 验收
```bash
sdkmanager --version          # 应输出版本号
adb --version                 # 应输出 Android Debug Bridge version
sdkmanager --list_installed   # 应显示已安装的 platform-tools, platforms;android-34, build-tools
```

---

## 六、Flutter SDK

```bash
# 下载 Flutter SDK（使用 stable channel）
cd ~
git clone https://github.com/flutter/flutter.git -b stable --depth 1

# 配置环境变量
cat >> ~/.bashrc << 'EOF'

# Flutter SDK
export PATH=$PATH:$HOME/flutter/bin
export PATH=$PATH:$HOME/flutter/bin/cache/dart-sdk/bin
export PATH=$PATH:$HOME/.pub-cache/bin
EOF

source ~/.bashrc

# 关闭分析报告
flutter config --no-analytics
dart --disable-analytics

# 运行 doctor 检查环境
flutter doctor
```

### 验收
```bash
flutter --version    # 应输出 Flutter 3.x.x
dart --version       # 应输出 Dart SDK version 3.x.x
flutter doctor       # 检查输出
```

`flutter doctor` 预期输出：
- `[✓] Flutter` — 正常
- `[✓] Android toolchain` — 正常（需要 Java + Android SDK）
- `[✗] Chrome` — 不需要，忽略（我们不做 Web）
- `[✗] Linux toolchain` — 不需要，忽略（我们不做 Linux 桌面应用）
- `[!] Android Studio` — 显示未安装，正常（我们用命令行工具）
- `[✗] Connected device` — 暂时没连设备，正常

**关键：确保 `Android toolchain` 是绿色 ✓。** 如果显示问题，按提示修复。

如果提示 `Android toolchain - develop for Android devices — cmdline-tools component is missing`：
```bash
sdkmanager "cmdline-tools;latest"
```

---

## 七、启动基础服务 (Docker Compose)

```bash
cd ~/dangdang-diary

# docker-compose.yml 已由后续步骤生成
# 此处仅验证 Docker 能正常拉取和运行容器

# 快速测试 PostgreSQL
docker run --rm -e POSTGRES_PASSWORD=test postgres:16-alpine pg_isready
# 应输出相关信息后容器退出

# 快速测试 Redis
docker run --rm redis:7-alpine redis-cli --version
# 应输出 redis-cli 版本

# 快速测试 MinIO
docker run --rm minio/minio:latest --version
# 应输出 minio 版本
```

注意: 完整的 `docker-compose.yml` 将在 Step 1 由 AI agent 创建。这里只确认镜像能拉取。

如果服务器位于国内且 Docker Hub 访问慢，配置镜像加速：
```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.mirrors.ustc.edu.cn"
  ]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

---

## 八、配置 Git

```bash
git config --global user.name "你的名字"
git config --global user.email "你的邮箱"
git config --global init.defaultBranch main
```

---

## 九、创建项目并初始化 Git

```bash
cd ~/dangdang-diary
git init
```

创建 `.gitignore`:
```bash
cat > .gitignore << 'EOF'
# Python
__pycache__/
*.py[cod]
*.egg-info/
.venv/
venv/

# Flutter
frontend/.dart_tool/
frontend/.packages
frontend/build/
frontend/.flutter-plugins
frontend/.flutter-plugins-dependencies

# IDE
.idea/
.vscode/
*.swp
*.swo

# Environment
.env
*.env.local

# OS
.DS_Store
Thumbs.db

# Docker volumes (local)
postgres_data/
redis_data/
minio_data/
EOF

git add .
git commit -m "初始化项目结构"
```

---

## 十、Android 真机调试准备（可选，后续需要时再配置）

如果你要用真机（通过 USB 连接到服务器或通过 adb 网络连接）测试 APP：

### 方案 A: USB 连接（服务器有物理 USB 接口时）
```bash
# 确认设备已连接
adb devices
# 应显示你的设备 ID
```

### 方案 B: 网络 ADB（推荐，服务器远程开发时）
在手机上：
1. 开启「开发者模式」和「USB 调试」
2. 连接到与服务器同一局域网的 WiFi
3. 进入开发者选项 → 无线调试 → 开启
4. 记下手机的 IP 和端口

在服务器上：
```bash
adb pair <手机IP>:<配对端口>    # 输入配对码
adb connect <手机IP>:<连接端口>
adb devices                    # 应显示已连接的设备
```

### 方案 C: 编译 APK 后传到手机安装
```bash
# 在 Flutter 项目中
cd ~/dangdang-diary/frontend
flutter build apk --debug
# APK 路径: build/app/outputs/flutter-apk/app-debug.apk
# 通过 scp 或其他方式传到手机安装
```

---

## 最终环境验收清单

逐项执行以下命令，全部通过即环境准备完毕：

| # | 检查项 | 命令 | 预期结果 |
|---|--------|------|----------|
| 1 | Git | `git --version` | 2.x+ |
| 2 | Docker | `docker --version` | 24.x+ |
| 3 | Docker Compose | `docker compose version` | v2.x+ |
| 4 | Docker 免 sudo | `docker run hello-world` | 成功运行 |
| 5 | Python | `python3.11 --version` | 3.11.x |
| 6 | pip | `python3.11 -m pip --version` | 2x.x |
| 7 | Java | `java -version` | 17.x |
| 8 | Android SDK | `sdkmanager --version` | 有输出 |
| 9 | adb | `adb --version` | 有输出 |
| 10 | Flutter | `flutter --version` | 3.x.x |
| 11 | Dart | `dart --version` | 3.x.x |
| 12 | Flutter Doctor | `flutter doctor` | Android toolchain ✓ |

**全部通过后，环境准备完毕，可以开始 Step 1 的项目骨架搭建。**

---

## 常见问题

### Q: Flutter 下载很慢怎么办？
使用 Flutter 中国镜像：
```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
# 添加到 ~/.bashrc
```

### Q: 服务器磁盘空间不够怎么办？
检查空间占用：
```bash
df -h           # 查看磁盘空间
du -sh ~/Android/Sdk    # Android SDK 约 2GB
du -sh ~/flutter         # Flutter SDK 约 1.5GB
docker system df         # Docker 占用
```
如果 50GB 不够，可以清理不需要的 Docker 镜像：`docker system prune -a`

### Q: 没有桌面环境能开发 Flutter 吗？
可以。你在服务器上编写代码和编译，通过以下方式测试：
1. 编译 APK → 传到手机安装
2. 使用 adb 网络连接 → `flutter run` 直接部署到手机
3. 使用 Cursor 远程开发，在本地预览
