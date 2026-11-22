@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo 正在启动视频下载器…
start "" http://127.0.0.1:8787
python app.py
pause
