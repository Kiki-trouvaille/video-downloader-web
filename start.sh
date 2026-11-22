#!/usr/bin/env bash
# 本机启动脚本：起服务并打开浏览器
set -e
cd "$(dirname "$0")"
python app.py &
pid=$!
sleep 2
url="http://127.0.0.1:${PORT:-8787}"
( command -v xdg-open >/dev/null && xdg-open "$url" ) \
  || ( command -v open >/dev/null && open "$url" ) \
  || echo "请手动打开 $url"
wait "$pid"
