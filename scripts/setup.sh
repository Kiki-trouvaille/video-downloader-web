#!/bin/bash
# 安装本 skill 的依赖：yt-dlp（解析/下载）与 ffmpeg（封装/转封装）
# 用法: bash setup.sh [安装目录]
# 默认目录: 有 D 盘则用 D:/VideoDownloads/_tools，否则 ~/.workbuddy/tools/video-downloader
set -u

if [ -n "${1:-}" ]; then
  VDL_HOME="$1"
elif [ -d /d ]; then
  VDL_HOME="D:/VideoDownloads/_tools"
else
  VDL_HOME="$HOME/.workbuddy/tools/video-downloader"
fi
mkdir -p "$VDL_HOME"

echo "== 安装目录: $VDL_HOME"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) _PS=';' ;;
  *) _PS=':' ;;
esac
export PYTHONPATH="$VDL_HOME/pylibs${PYTHONPATH:+${_PS}${PYTHONPATH}}"
python -m pip install -q --upgrade --target "$VDL_HOME/pylibs" yt-dlp imageio-ffmpeg 2>&1 | grep -v notice | head -3

echo "== 校验"
PYTHONPATH="$VDL_HOME/pylibs" python -c "import yt_dlp; print('yt-dlp', yt_dlp.version.__version__)"
FF=$(ls "$VDL_HOME"/ffbin/imageio_ffmpeg/binaries/ffmpeg* 2>/dev/null | head -1)
if [ -z "$FF" ]; then
  PYTHONPATH="$VDL_HOME/pylibs" python -m pip install -q --target "$VDL_HOME/ffbin" imageio-ffmpeg 2>&1 | grep -v notice | head -3
  FF=$(ls "$VDL_HOME"/ffbin/imageio_ffmpeg/binaries/ffmpeg* 2>/dev/null | head -1)
fi
[ -n "$FF" ] && "$FF" -version 2>/dev/null | head -1

cat > "$VDL_HOME/env.sh" <<EOF
# 由 video-downloader skill 的 setup.sh 生成
export VDL_HOME="$VDL_HOME"
export PYTHONPATH="$VDL_HOME/pylibs\${PYTHONPATH:+:\$PYTHONPATH}"
export VDL_FFMPEG="$FF"
EOF
echo "== 已写入 $VDL_HOME/env.sh"
echo "完成。下载时如提示缺少依赖，先 source $VDL_HOME/env.sh 或重跑本脚本。"
