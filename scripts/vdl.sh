#!/bin/bash
# 通用视频下载器主入口
#   vdl.sh <url|links.txt> [选项]
# 选项:
#   -o DIR    输出目录（默认 D:/VideoDownloads）
#   -n NAME   输出文件名（不含扩展名；默认用站点标题）
#   -p PROXY  强制走该代理；不传则先试直连，不通再自动回落系统代理
#   -q Q      画质上限: max | 1080 | 720 | 480 | audio（默认 max）
#   -N N      并发分片数（默认 4）
#   --dry     只解析不下载
#   --list    打印可用格式列表后退出
#
# 设计：默认交给 yt-dlp（覆盖绝大多数站点，含 HLS/DASH/直链，自动无损 remux 为 mp4）；
#       命中 USP/HLS 阶梯型 m3u8 时走专用分片管线（可突破 yt-dlp 的清晰度上限）。
set -u

SKILL_DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
VDL_HOME="${VDL_HOME:-D:/VideoDownloads/_tools}"
# Windows 下 PYTHONPATH 的分隔符是 ';'，用 ':' 会把已有路径拼成一条无效路径
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) _PS=';' ;;
  *) _PS=':' ;;
esac
export PYTHONPATH="$VDL_HOME/pylibs${PYTHONPATH:+${_PS}${PYTHONPATH}}"

OUT_DIR="D:/VideoDownloads"
NAME=""
PROXY_ARG=""
QUALITY="max"
CONC=4
DRY=0
LIST=0
INPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT_DIR="${2:-}"; shift 2;;
    -n) NAME="${2:-}"; shift 2;;
    -p) PROXY_ARG="${2:-}"; shift 2;;
    -q) QUALITY="${2:-max}"; shift 2;;
    -N) CONC="${2:-4}"; shift 2;;
    --dry) DRY=1; shift;;
    --list) LIST=1; shift;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    -*) echo "未知选项: $1" >&2; exit 2;;
    *) INPUT="$1"; shift;;
  esac
done

[ -z "$INPUT" ] && { echo "用法: vdl.sh <url|links.txt> [-o 目录] [-n 名称] [-q max|1080|720|audio]" >&2; exit 2; }
mkdir -p "$OUT_DIR"

# ---------- 依赖定位 ----------
find_ff() {
  local f
  [ -n "${VDL_FFMPEG:-}" ] && [ -x "${VDL_FFMPEG}" ] && { echo "$VDL_FFMPEG"; return; }
  f=$(ls "$VDL_HOME"/ffbin/imageio_ffmpeg/binaries/ffmpeg* 2>/dev/null | head -1)
  [ -n "$f" ] && { echo "$f"; return; }
  f=$(command -v ffmpeg 2>/dev/null)
  [ -n "$f" ] && { echo "$f"; return; }
  echo ""
}
FF=$(find_ff)

# yt-dlp 只认名为 ffmpeg/ffmpeg.exe 的可执行文件。imageio-ffmpeg 的二进制叫
# ffmpeg-win-x86_64-vX.Y.Z.exe，直接传目录会找不到 → 建一个标准名硬链接入口，
# 否则音视频轨不会被合并，留下两个分离文件且无任何报错。
FF_DIR=""
ensure_ff_dir() {
  [ -n "$FF_DIR" ] && { echo "$FF_DIR"; return; }
  [ -z "$FF" ] && { echo ""; return; }
  local real bin exe
  real=$(dirname "$FF")/$(basename "$FF")
  bin="$VDL_HOME/bin"
  mkdir -p "$bin"
  # 目标名要跟平台一致：Windows 认 ffmpeg.exe，Linux/macOS 只认 ffmpeg
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) exe="$bin/ffmpeg.exe" ;;
    *)                    exe="$bin/ffmpeg" ;;
  esac
  [ -f "$exe" ] || ln "$real" "$exe" 2>/dev/null || cp "$real" "$exe" 2>/dev/null || true
  [ -f "$exe" ] && FF_DIR="$bin" || FF_DIR=$(dirname "$real")
  echo "$FF_DIR"
}

if ! python -c "import yt_dlp" 2>/dev/null; then
  echo "缺少 yt-dlp。先执行: bash \"$SKILL_DIR/scripts/setup.sh\"" >&2
  exit 3
fi

# ---------- 代理 ----------
# 只取系统代理端口，不判断该不该用
system_proxy() {
  local raw
  raw=$(powershell -NoProfile -Command "(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyServer" 2>/dev/null | tr -d '\r' | head -1)
  [ -z "$raw" ] && raw="${HTTPS_PROXY:-${https_proxy:-}}"
  [ -z "$raw" ] && return
  case "$raw" in
    *=*) raw=$(echo "$raw" | tr ';' '\n' | grep -E '^https?=' | head -1 | cut -d= -f2) ;;
  esac
  case "$raw" in
    http://*|https://*|socks4://*|socks5://*) echo "$raw" ;;
    "") ;;
    *) echo "http://$raw" ;;
  esac
}

host_of() { echo "$1" | sed -E 's#^[a-zA-Z]+://##; s#[/?].*$##'; }

# 直连可达性：能拿到任何 HTTP 状态码就算通（403/404 也比走代理快）
direct_ok() {
  local host="$1" code
  [ -z "$host" ] && return 1
  for scheme in https http; do
    code=$(curl -sS --noproxy '*' -o /dev/null -m 8 -w "%{http_code}" "$scheme://$host/" 2>/dev/null)
    case "$code" in
      ""|000) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# 每个链接单独决定：显式 -p > 环境变量 > 直连优先，直连不通再用系统代理
# 无差别套代理会让国内站点变得极慢（实测 B 站从数 MB/s 掉到 40KB/s）
resolve_proxy() {
  local url="$1" sys
  [ -n "$PROXY_ARG" ] && { echo "$PROXY_ARG"; return; }
  [ -n "${VDL_PROXY:-}" ] && { echo "$VDL_PROXY"; return; }
  sys=$(system_proxy)
  [ -z "$sys" ] && { echo ""; return; }
  if direct_ok "$(host_of "$url")"; then echo ""; else echo "$sys"; fi
}

PROXY=""
FFDIR=$(ensure_ff_dir)

build_yt() {
  YT=(python -m yt_dlp --no-warnings --no-playlist --concurrent-fragments "$CONC")
  [ -n "$FFDIR" ] && YT+=(--ffmpeg-location "$FFDIR")
  [ -n "$PROXY" ] && YT+=(--proxy "$PROXY")
}
build_yt
yt() { "${YT[@]}" "$@"; }

# ---------- 工具函数 ----------
sanitize() {
  echo "$1" | tr -d '\r\n' | sed 's/[\\/:*?"<>|]/_/g' | sed 's/^[ .]*//; s/[ .]*$//' | cut -c1-80
}

# 从站点元数据推文件名：优先 上传日期_标题
auto_name() {
  local url="$1" meta d t
  meta=$(yt --skip-download --print "%(upload_date>%Y-%m-%d)s|%(title)s" "$url" 2>/dev/null | head -1)
  d=$(echo "$meta" | cut -d'|' -f1)
  t=$(echo "$meta" | cut -d'|' -f2-)
  [ "$d" = "NA" ] && d=""
  [ -z "$t" ] && t=$(basename "${url%%\?*}" | sed 's/\.[a-z0-9]*$//')
  if [ -n "$d" ]; then echo "$(sanitize "$d")_$(sanitize "$t")"; else echo "$(sanitize "$t")"; fi
}

quality_filter() {
  case "$1" in
    max)   echo "bv*+ba/b" ;;
    1080)  echo "bv*[height<=1080]+ba/b[height<=1080]/b" ;;
    720)   echo "bv*[height<=720]+ba/b[height<=720]/b" ;;
    480)   echo "bv*[height<=480]+ba/b[height<=480]/b" ;;
    audio) echo "ba/b" ;;
    *)     echo "bv*+ba/b" ;;
  esac
}

yt_download() {
  local url="$1" base="$2"
  local fmt; fmt=$(quality_filter "$QUALITY")
  local ext="mp4"
  [ "$QUALITY" = "audio" ] && ext="m4a"
  yt -f "$fmt" --merge-output-format mp4 --remux-video mp4 \
     -o "$OUT_DIR/${base}.%(ext)s" "$url"
}

# USP/HLS 阶梯型：交给专用分片管线（能拿到 yt-dlp 看不到的高码率档）
ladder_download() {
  local url="$1" base="$2"
  URL="$url" OUT_FILE="$OUT_DIR/${base}.mp4" FF="$FF" HLS_PROXY="$PROXY" \
  WORK="${VDL_WORK:-D:/VideoDownloads/_tmp}" CONC="$CONC" QUALITY="$QUALITY" \
  bash "$SKILL_DIR/scripts/hls_ladder.sh"
}

handle_url() {
  local url="$1" base stream
  case "$url" in
    http://*|https://*) ;;
    *) url="https://$url" ;;
  esac

  if [ -n "$NAME" ]; then base=$(sanitize "$NAME"); fi

  PROXY=$(resolve_proxy "$url")
  build_yt
  [ -n "$PROXY" ] && echo "  (该站点直连不通，走代理 $PROXY)" >&2

  if [ "$LIST" = "1" ]; then
    yt -F "$url"
    return
  fi

  echo "[1/3] 解析: $url" >&2

  # 情况 A：m3u8 直链
  if echo "$url" | grep -qiE '\.m3u8(\?|$)'; then
    if echo "$url" | grep -qE '\-video=[0-9]+'; then
      echo "  -> USP 阶梯型清单，走分片管线（可枚举更高码率档）" >&2
      [ -z "${base:-}" ] && base=$(auto_name "$url" 2>/dev/null)
      [ -z "${base:-}" ] && base="video_$(date +%Y%m%d_%H%M%S)"
      [ "$DRY" = "1" ] && { echo "DRY: $url -> $OUT_DIR/${base}.mp4" ; return; }
      ladder_download "$url" "$base" && return
      echo "  -> 分片管线失败，回退 yt-dlp" >&2
    fi
    [ -z "${base:-}" ] && base=$(auto_name "$url" 2>/dev/null)
    [ -z "${base:-}" ] && base="video_$(date +%Y%m%d_%H%M%S)"
    [ "$DRY" = "1" ] && { echo "DRY: $url -> $OUT_DIR/${base}.mp4"; return; }
    yt_download "$url" "$base" && return
    if [ -n "$FF" ]; then
      echo "  -> yt-dlp 失败，改用 ffmpeg 直接拉流" >&2
      "$FF" -hide_banner -loglevel warning -y -i "$url" -c copy -bsf:a aac_adtstoasc -movflags +faststart "$OUT_DIR/${base}.mp4" && return
    fi
    echo "RESULT|FAIL|$url" >&2
    return 1
  fi

  # 情况 B：普通页面链接，先看能否拿到 HLS 清单
  stream=$(yt -f "b[protocol=m3u8]/b[protocol=m3u8_native]/b" -g "$url" 2>/dev/null | head -1)

  if echo "$stream" | grep -qi '\.m3u8'; then
    echo "  -> 命中 HLS 清单" >&2
    if echo "$stream" | grep -qE '\-video=[0-9]+'; then
      echo "  -> USP 阶梯型，走分片管线" >&2
      [ -z "${base:-}" ] && base=$(auto_name "$url")
      [ -z "${base:-}" ] && base="video_$(date +%Y%m%d_%H%M%S)"
      [ "$DRY" = "1" ] && { echo "DRY: $stream -> $OUT_DIR/${base}.mp4"; return; }
      ladder_download "$stream" "$base" && return
      echo "  -> 分片管线失败，回退 yt-dlp 直下" >&2
    fi
  else
    echo "  -> 非 HLS，交给 yt-dlp 直接下载最佳画质" >&2
  fi

  [ -z "${base:-}" ] && base=$(auto_name "$url")
  [ -z "${base:-}" ] && base="video_$(date +%Y%m%d_%H%M%S)"
  [ "$DRY" = "1" ] && { echo "DRY: $url -> $OUT_DIR/${base}.mp4"; return; }
  yt_download "$url" "$base" || { echo "RESULT|FAIL|$url" >&2; return 1; }
}

# ---------- 输入分派：文件视为链接清单 ----------
if [ -f "$INPUT" ]; then
  n=0; ok=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue;; esac
    url=$(echo "$line" | awk '{print $1}')
    [ -z "$url" ] && continue
    n=$((n+1))
    if handle_url "$url"; then
      ok=$((ok+1))
      echo "RESULT|OK|$url"
    else
      echo "RESULT|FAIL|$url"
    fi
  done < "$INPUT"
  echo "--- 完成: 成功 $ok / 共 $n ---" >&2
else
  handle_url "$INPUT" && echo "RESULT|OK|$INPUT" || { echo "RESULT|FAIL|$INPUT"; exit 1; }
fi
