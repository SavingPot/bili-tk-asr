#!/bin/bash
# 自动获取当前脚本所在的绝对目录
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR" || exit 1

# 检查服务是否已经在运行 (端口 8001)
if curl -s http://127.0.0.1:8001/docs > /dev/null; then
    exit 0
fi

# 启动服务（优先使用虚拟环境，否则使用 uv）
if [ -f "$PROJECT_DIR/.venv/bin/python" ]; then
    nohup "$PROJECT_DIR/.venv/bin/python" server.py > asr.log 2>&1 &
elif command -v uv > /dev/null 2>&1; then
    nohup uv run server.py > asr.log 2>&1 &
else
    echo "Error: 找不到 python 或 uv，请先安装运行环境。" > asr.log
    exit 1
fi
