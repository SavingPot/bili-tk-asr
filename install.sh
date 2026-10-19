#!/usr/bin/env bash
# =============================================================
#  bili-tk-asr 一键安装脚本（release 版）
#  用法: 解压 release 包后，在解压目录内运行：
#    ./install.sh                  # 安装到当前目录
#    ./install.sh -s               # 跳过模型下载
#    ./install.sh -m               # 强制使用 hf-mirror 镜像
#    ./install.sh -n               # 强制直连 huggingface
#    ./install.sh -y               # 全程不暂停 / 自动同意
# =============================================================
set -euo pipefail

PYTHON_VER="3.12"
HF_MIRROR="${HF_MIRROR:-https://hf-mirror.com}"

# 项目根目录 = 本脚本所在目录（release 解压后的目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"

USE_MIRROR="auto"      # auto | always | never
SKIP_MODEL=0
FORCE=0
ASSUME_YES=0

# ---------- 颜色 ----------
if [[ -t 1 ]]; then
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[36m'; DIM=$'\e[2m'; NC=$'\e[0m'
else
  RED=; GRN=; YEL=; BLU=; DIM=; NC=
fi
info(){ echo "${BLU}[INFO]${NC} $*"; }
ok  (){ echo "${GRN}[ OK ]${NC} $*"; }
warn(){ echo "${YEL}[WARN]${NC} $*"; }
die (){ echo "${RED}[FAIL]${NC} $*" >&2; exit 1; }

usage(){ sed -n '3,10p' "$0" | sed 's/^#  \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mirror)     USE_MIRROR="always"; shift ;;
    -n|--no-mirror)  USE_MIRROR="never";  shift ;;
    -s|--skip-model) SKIP_MODEL=1; shift ;;
    -f|--force)      FORCE=1; shift ;;
    -y|--yes|--no-pause) ASSUME_YES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "未知参数: $1（-h 查看帮助）" ;;
  esac
done

# ---------- 暂停（供用户开关 VPN） ----------
pause(){
  local msg="$1"
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  echo >&2
  echo "${YEL}⏸  暂停：${NC}${msg}" >&2
  echo "${DIM}   按 Enter 继续，Ctrl-C 取消...${NC}" >&2
  if [[ -t 0 ]]; then
    read -r _ || true
  elif [[ -r /dev/tty ]]; then
    read -r _ < /dev/tty || true
  else
    warn "无可用终端，跳过暂停（可用 -y 显式关闭此提示）"
  fi
}

# ---------- 询问 yes/no ----------
confirm(){
  local msg="$1"
  local default="${2:-y}"
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  local prompt
  if [[ "$default" == "y" ]]; then
    prompt="$msg [Y/n] "
  else
    prompt="$msg [y/N] "
  fi
  local reply=""
  if [[ -t 0 ]]; then
    read -r -p "$prompt" reply || reply=""
  elif [[ -r /dev/tty ]]; then
    read -r -p "$prompt" reply < /dev/tty || reply=""
  else
    warn "无可用终端，按默认 ($default) 处理"
    reply="$default"
  fi
  reply="${reply:-$default}"
  case "$reply" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    [Nn]|[Nn][Oo])     return 1 ;;
    *) if [[ "$default" == "y" ]]; then return 0; else return 1; fi ;;
  esac
}

# ---------- 依赖检查 ----------
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令 '$1'，请先安装"; }

if ! command -v uv >/dev/null 2>&1; then
  die "缺少 uv。请先执行:  curl -LsSf https://astral.sh/uv/install.sh | sh   然后重开终端"
fi
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  die "需要 wget 或 curl 之一用于下载模型"
fi

# 校验 release 是否完整解压
for f in launch_asr.sh server.py; do
  [[ -f "$INSTALL_DIR/$f" ]] || die "缺少 $f，请确认 release 包已完整解压到 $INSTALL_DIR"
done

cd "$INSTALL_DIR"

# ---------- 下载工具 ----------
fetch(){
  local url="$1" out="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress --tries=3 --timeout=30 --retry-connrefused -O "$out.part" "$url"
  else
    curl -fL --retry 3 --connect-timeout 30 --progress-bar -o "$out.part" "$url"
  fi && mv -f "$out.part" "$out"
}

download_hf(){
  local rel="$1" out="$2"
  local -a urls=()
  case "$USE_MIRROR" in
    always) urls=("$HF_MIRROR/$rel") ;;
    never)  urls=("https://huggingface.co/$rel") ;;
    auto)   urls=("https://huggingface.co/$rel" "$HF_MIRROR/$rel") ;;
  esac
  local u
  for u in "${urls[@]}"; do
    info "下载 $out ...  ${DIM}<- $u${NC}"
    if fetch "$u" "$out"; then ok "$out 完成"; return 0; fi
    warn "下载失败，尝试下一个源"
    rm -f "$out.part"
  done
  return 1
}

# ---------- 注册 bili-asr:// URL 协议 ----------
register_protocol(){
  local launch_script="$INSTALL_DIR/launch_asr.sh"
  local desktop_file="$HOME/.local/share/applications/bili-asr-handler.desktop"
  local desktop_name="bili-asr-handler.desktop"

  if [[ ! -f "$launch_script" ]]; then
    warn "未找到 $launch_script，跳过协议注册"
    return 0
  fi
  if [[ "$(uname -s)" != "Linux" ]]; then
    warn "当前系统非 Linux，跳过 bili-asr:// 协议注册"
    return 0
  fi
  if ! command -v xdg-mime >/dev/null 2>&1; then
    warn "未找到 xdg-mime，跳过协议注册（可安装 xdg-utils 后手动运行）"
    return 0
  fi

  chmod +x "$launch_script" || { warn "无法设置 $launch_script 执行权限，跳过协议注册"; return 0; }

  local desired
  desired="$(cat <<EOF
[Desktop Entry]
Name=BiliTK ASR Launcher
Comment=Launch BiliTK Local ASR Service
Exec=$launch_script %u
Type=Application
Terminal=false
MimeType=x-scheme-handler/bili-asr;
EOF
)"

  mkdir -p "$HOME/.local/share/applications"

  local need_write=0
  if [[ -f "$desktop_file" ]]; then
    local current
    current="$(cat "$desktop_file" 2>/dev/null || true)"
    if [[ "$current" == "$desired" ]]; then
      ok "桌面文件已存在且内容一致，跳过写入: $desktop_file"
    else
      info "检测到已存在的桌面文件（内容不同，可能目录变更），需要更新: $desktop_file"
      need_write=1
    fi
  else
    info "未发现桌面文件，需要创建: $desktop_file"
    need_write=1
  fi

  if [[ "$need_write" == "1" ]]; then
    echo
    echo "${YEL}⚠  强烈建议添加 .desktop 文件${NC}"
    echo "    用途：注册 bili-asr:// URL 协议，让 ${GRN}油猴（Tampermonkey）脚本${NC}"
    echo "    能从网页一键唤起本地 ASR 服务。"
    echo "    不添加的话，网页端将无法自动拉起本地服务（只能手动运行 launch_asr.sh）。"
    echo
    if ! confirm "是否创建 / 更新 .desktop 文件并注册 bili-asr:// 协议？" y; then
      warn "已跳过 .desktop 文件写入和协议注册"
      info "之后如需手动添加，可重新运行:  ./install.sh -y"
      return 0
    fi
    printf '%s\n' "$desired" > "$desktop_file"
    ok "已写入: $desktop_file"
  fi

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null || true
  fi

  local current_handler
  current_handler="$(xdg-mime query default x-scheme-handler/bili-asr 2>/dev/null || true)"
  if [[ "$current_handler" == "$desktop_name" ]]; then
    ok "bili-asr:// 协议已指向 $desktop_name，跳过注册"
  else
    if xdg-mime default "$desktop_name" x-scheme-handler/bili-asr 2>/dev/null; then
      ok "bili-asr:// 协议已注册: $desktop_file"
      info "现在可以在网页上一键唤起本地服务了"
    else
      warn "xdg-mime 注册失败，可稍后手动运行:"
      warn "  xdg-mime default $desktop_name x-scheme-handler/bili-asr"
    fi
  fi
}

# ---------- 1. 虚拟环境 ----------
echo
info "== 步骤 1/4: 创建 Python $PYTHON_VER 虚拟环境 =="
if [[ ! -x ".venv/bin/python" || "$FORCE" == "1" ]]; then
  rm -rf .venv
  uv venv --python "$PYTHON_VER"
fi
VENV_PY="$INSTALL_DIR/.venv/bin/python"
"$VENV_PY" -V
ok "虚拟环境: $INSTALL_DIR/.venv"

# ---------- 2. 安装依赖 ----------
echo
pause "接下来安装 Python 依赖（走 PyPI 或你本地的 pip 镜像）。
       国内一般直连即可；如果你平时需要关 VPN 才能用镜像源，现在去关。"

info "== 步骤 2/4: 安装 Python 依赖 =="
uv pip install --python "$VENV_PY" \
  fastapi uvicorn python-multipart funasr_onnx modelscope

if ! "$VENV_PY" -c "import funasr_onnx" >/dev/null 2>&1; then
  warn "funasr_onnx 导入失败，安装修复版（--force-reinstall --no-deps）"
  uv pip install --python "$VENV_PY" --force-reinstall --no-deps \
    "git+https://github.com/modelscope/FunASR.git#subdirectory=runtime/python/onnxruntime"
  "$VENV_PY" -c "import funasr_onnx" >/dev/null 2>&1 \
    || warn "修复版仍然导入失败，请检查 Python 版本 / 平台兼容性"
fi
ok "依赖安装完成"

# ---------- 3. 下载模型 ----------
echo
if [[ "$SKIP_MODEL" == "1" ]]; then
  warn "== 步骤 3/4: 跳过模型下载（--skip-model）=="
else
  pause "接下来下载模型（默认先连 huggingface.co 官方，失败才回退 hf-mirror）。
       国内通常需要开 VPN。不想开 VPN 的话：Ctrl-C 取消，改用  ./install.sh -m  走镜像。"

  info "== 步骤 3/4: 下载 SenseVoiceSmall ONNX 模型 =="
  MODEL_DIR="$INSTALL_DIR/SenseVoiceSmall-onnx"
  mkdir -p "$MODEL_DIR"
  pushd "$MODEL_DIR" >/dev/null

  declare -a FILES=(
    "DennisHuang648/SenseVoiceSmall-onnx/resolve/main/model_quant.onnx|model_quant.onnx"
    "FunAudioLLM/SenseVoiceSmall/resolve/main/chn_jpn_yue_eng_ko_spectok.bpe.model|chn_jpn_yue_eng_ko_spectok.bpe.model"
    "DennisHuang648/SenseVoiceSmall-onnx/resolve/main/config.yaml|config.yaml"
    "DennisHuang648/SenseVoiceSmall-onnx/resolve/main/tokens.json|tokens.json"
    "FunAudioLLM/SenseVoiceSmall/resolve/main/am.mvn|am.mvn"
  )

  for item in "${FILES[@]}"; do
    rel="${item%%|*}"; out="${item##*|}"
    if [[ -s "$out" && "$FORCE" != "1" ]]; then
      ok "$out 已存在，跳过"
      continue
    fi
    download_hf "$rel" "$out" || die "模型文件 $out 下载失败（可尝试 -m 走镜像，或 -s 跳过稍后手动下载）"
  done

  if [[ -f model_quant.onnx && ! -f model.onnx ]]; then
    mv -f model_quant.onnx model.onnx
    ok "model_quant.onnx -> model.onnx"
  fi

  popd >/dev/null
  ok "模型目录: $MODEL_DIR"
fi

# ---------- 4. 注册 bili-asr:// 协议 ----------
echo
info "== 步骤 4/4: 注册 bili-asr:// URL 协议并添加 .desktop 文件 =="
register_protocol

# ---------- 完成 ----------
echo
ok "安装完成 🎉"
cat <<EOF

  安装目录 : $INSTALL_DIR
  虚拟环境 : $INSTALL_DIR/.venv
  模型目录 : $INSTALL_DIR/SenseVoiceSmall-onnx

EOF