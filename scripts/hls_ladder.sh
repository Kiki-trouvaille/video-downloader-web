#!/bin/bash
# HLS 阶梯型（USP/piff 风格）分片下载器：自动枚举最高画质档 → 并发拉分片 → 二进制拼接 → 无损封装 mp4
#
# 输入（环境变量）:
#   URL       形如 .../xxx.ism.hlsv2-audio_eng_1=128000-video=5070000.m3u8 的清单地址
#   OUT_FILE  输出 mp4 绝对路径
#   FF        ffmpeg 路径
#   HLS_PROXY 可选，分片请求走的代理（CDN 域名不一定直连可达，按需设置）
#   WORK      临时目录（默认 D:/VideoDownloads/_tmp）
#   CONC      并发数（默认 4；该类 CDN 超过 5 路常被限流）
#   QUALITY   max|1080|720|480，仅用于给码率阶梯设上限
#   MAX_SEGS  只下前 N 片，用于冒烟测试（默认 0 = 全部）
set -u

URL="${URL:?缺少 URL}"
OUT_FILE="${OUT_FILE:?缺少 OUT_FILE}"
FF="${FF:-ffmpeg}"
WORK="${WORK:-D:/VideoDownloads/_tmp}"
CONC="${CONC:-4}"
QUALITY="${QUALITY:-max}"
MAX_SEGS="${MAX_SEGS:-0}"
HLS_PROXY="${HLS_PROXY:-}"
mkdir -p "$WORK" "$(dirname "$OUT_FILE")"

c() { if [ -n "$HLS_PROXY" ]; then curl -sS --proxy "$HLS_PROXY" "$@"; else curl -sS "$@"; fi; }

# 码率阶梯：从高到低枚举。选中的值会再按 QUALITY 上限裁剪。
LADDER_FULL="25000000 20000000 16000000 15000000 13000000 12000000 11000000 10000000 9000000 8000000 7000000 6000000 5070000 4500000 3500000 2500000 1500000 800000"
case "$QUALITY" in
  1080) CAP=12000000 ;;
  720)  CAP=5070000 ;;
  480)  CAP=2500000 ;;
  *)    CAP=999999999 ;;
esac
LADDER=""
for v in $LADDER_FULL; do [ "$v" -le "$CAP" ] && LADDER="$LADDER $v"; done
LADDER="${LADDER# }"

# 分片有效性：首字节为 TS 同步字节 0x47 且体积 >=20KB
# 阈值不能按 1MB 定——实测末片可能只有 0.6 秒 / 42KB，会被误判为缺失；
# 但也不能太低——部分 CDN 对畸形/限流请求回 188 字节占位响应
MIN_SEG="${MIN_SEG:-20000}"
seg_ok() {
  local f="$1" s b
  s=$(stat -c%s "$f" 2>/dev/null || echo 0)
  [ "$s" -ge "$MIN_SEG" ] || return 1
  b=$(od -An -tx1 -N1 "$f" 2>/dev/null | tr -d ' \n')
  [ "$b" = "47" ]
}

fetch_seg() {
  local name="$1" out="$2" base="$3"
  local size attempt prev
  seg_ok "$out" && return 0
  prev=0
  for attempt in $(seq 1 15); do
    size=$(stat -c%s "$out" 2>/dev/null || echo 0)
    if [ "$size" -ge "$MIN_SEG" ] && [ "$size" -gt "$prev" ]; then
      c -L -C - --fail --connect-timeout 20 --max-time 240 -o "$out" "${base}${name}" 2>/dev/null
    else
      c -L --fail --connect-timeout 20 --max-time 240 -o "$out" "${base}${name}" 2>/dev/null
    fi
    prev=$size
    seg_ok "$out" && return 0
    sleep 2
  done
  return 1
}

DIRP=$(dirname "$URL")
FILE=$(basename "$URL")
PREFIX="${FILE%%-audio_*}"
AUD=$(echo "$FILE" | sed -n 's/.*\(audio_[a-z]*_[0-9]*=[0-9]*\).*/\1/p')
AUD="${AUD:-audio_eng_1=128000}"
ASSET=$(echo "$PREFIX" | sed -n 's/^vf_\([a-z0-9]*\)_.*/\1/p')
ASSET="${ASSET:-$(basename "$OUT_FILE" .mp4)}"

# 枚举最高可用视频档：分片名必须带 -video=，否则拿到的是纯音频回落档（HTTP 仍为 200，极易误判）
probe_best() {
  local v f n vs
  for v in $LADDER; do
    f="$WORK/probe_$v.m3u8"
    c --fail -o "$f" --max-time 25 "${DIRP}/${PREFIX}-${AUD}-video=${v}.m3u8" 2>/dev/null || continue
    n=$(grep -c '\.ts' "$f" 2>/dev/null || true)
    vs=$(grep -c -- '-video=' "$f" 2>/dev/null || true)
    if [ "${n:-0}" -gt 0 ] && [ "${vs:-0}" -eq "${n:-0}" ]; then echo "$v"; return 0; fi
  done
  return 1
}

echo "[$ASSET] 枚举最高画质档..." >&2
V=$(probe_best) || { echo "RESULT|FAIL|$ASSET|无可用视频档（清单可能为纯音频或已失效）"; exit 1; }
M3U8="$WORK/probe_$V.m3u8"

N=$(grep -c '\.ts' "$M3U8")
[ "$MAX_SEGS" -gt 0 ] && [ "$MAX_SEGS" -lt "$N" ] && N=$MAX_SEGS
echo "[$ASSET] 选中 video=$V，$N 片" >&2

DIR="$WORK/seg_$ASSET"
mkdir -p "$DIR"
grep -E '\.ts$' "$M3U8" | head -n "$N" | tr -d '\r' | awk '{printf "%d\t%s\n", NR, $0}' > "$DIR/index.map"
TOTAL=$(wc -l < "$DIR/index.map")
[ "$TOTAL" -eq 0 ] && { echo "RESULT|FAIL|$ASSET|清单内无 .ts 分片（可能是 fMP4，改用 yt-dlp）"; exit 1; }

# 并发拉取：超过 CONC 个在跑就等
for((i=1;i<=TOTAL;i++)); do
  while [ "$(jobs -rp | wc -l)" -ge "$CONC" ]; do wait -n 2>/dev/null || sleep 0.3; done
  name=$(awk -F'\t' -v k="$i" '$1==k{print $2}' "$DIR/index.map")
  ( fetch_seg "$name" "$DIR/$(printf '%05d' "$i").ts" "$DIRP/" ) &
done

# 边下边报进度：每提升 >=3% 打一行（前端据此推进度条），避免刷屏
LAST_PCT=0
while [ "$(jobs -rp | wc -l)" -gt 0 ]; do
  sleep 3
  HAVE_NOW=$(find "$DIR" -maxdepth 1 -name '*.ts' -size +19k 2>/dev/null | wc -l)
  PCT=$(( HAVE_NOW * 100 / TOTAL ))
  if [ "$PCT" -ge $((LAST_PCT + 3)) ] || [ "$HAVE_NOW" -eq "$TOTAL" ]; then
    echo "[进度] $HAVE_NOW/$TOTAL (${PCT}%)" >&2
    LAST_PCT=$PCT
  fi
done
wait

HAVE=0
for((i=1;i<=TOTAL;i++)); do seg_ok "$DIR/$(printf '%05d' "$i").ts" && HAVE=$((HAVE+1)); done
if [ "$HAVE" -ne "$TOTAL" ]; then
  echo "RESULT|FAIL|$ASSET|分片缺失 $HAVE/$TOTAL（重跑脚本会断点续传补齐）"
  exit 1
fi

: > "$DIR/merged.ts"
for((i=1;i<=TOTAL;i++)); do cat "$DIR/$(printf '%05d' "$i").ts" >> "$DIR/merged.ts"; done

H=$("$FF" -hide_banner -i "$DIR/merged.ts" 2>&1 | grep -m1 "Video:" | grep -oE '[0-9]{3,4}x[0-9]{3,4}' | head -1 | cut -dx -f2)
DUR=$("$FF" -hide_banner -i "$DIR/merged.ts" 2>&1 | grep -m1 "Duration:" | sed 's/.*Duration: \([0-9:.]*\).*/\1/')

"$FF" -hide_banner -loglevel error -y -i "$DIR/merged.ts" -c copy -bsf:a aac_adtstoasc -movflags +faststart "$OUT_FILE" \
  || { echo "RESULT|FAIL|$ASSET|封装失败"; exit 1; }

SIZE=$(stat -c%s "$OUT_FILE" 2>/dev/null || echo 0)
rm -f "$DIR"/*.ts
echo "RESULT|OK|$ASSET|${H:-0}p|$DUR|$SIZE|$OUT_FILE"
