#!/bin/bash
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_SCRIPT="$PROJECT_DIR/launch_asr.sh"
DESKTOP_FILE="$HOME/.local/share/applications/bili-asr-handler.desktop"

# 确保启动脚本有执行权限
chmod +x "$LAUNCH_SCRIPT"

# 动态生成 .desktop 文件
mkdir -p "$HOME/.local/share/applications"
cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=BiliTK ASR Launcher
Comment=Launch BiliTK Local ASR Service
Exec=$LAUNCH_SCRIPT %u
Type=Application
Terminal=false
MimeType=x-scheme-handler/bili-asr;
EOF

# 刷新并注册协议
update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null
xdg-mime default bili-asr-handler.desktop x-scheme-handler/bili-asr

echo "✅ BiliTK ASR 协议注册成功！"
echo "现在你可以直接在网页上一键唤起本地服务了。"
