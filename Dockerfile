FROM python:3.12-slim

# ffmpeg: 无损封装与直拉流；curl: 分片下载；bash: 下载脚本运行时
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg curl ca-certificates bash \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir -U yt-dlp

WORKDIR /app
COPY app.py ./
COPY web ./web
COPY scripts ./scripts

ENV HOST=0.0.0.0 \
    PORT=8787 \
    DOWNLOAD_DIR=/downloads \
    VDL_HOME=/opt/vdl-home \
    VDL_FFMPEG=/usr/bin/ffmpeg \
    MAX_PARALLEL=2 \
    PYTHONUNBUFFERED=1

RUN mkdir -p /downloads /opt/vdl-home && chmod +x /app/scripts/*.sh

EXPOSE 8787
VOLUME ["/downloads"]
CMD ["python", "app.py"]
