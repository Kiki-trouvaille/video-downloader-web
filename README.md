# Video Downloader Web

粘贴一个视频链接，选画质，点下载 —— 浏览器里直接拿到 MP4。

后端复用一套实战打磨过的 HLS 分片管线：自动枚举最高码率档、4 路并发、断点续传、无损封装（不转码）。

## 特性

- **两种输入都吃**：页面链接（YouTube/B 站/BBC…）和 `.m3u8` 直链，一行一个，支持批量
- **画质不将就**：HLS 阶梯清单会自动枚举 `video=` 档位。yt-dlp 只能看到 720p 的源，这里能拿到 1080p
- **零转码**：`ffmpeg -c copy` 直封装，画质即源画质
- **进度可见**：解析 / 分片 / 封装三阶段实时日志与进度条，支持浏览器内预览与断点 Range 取回
- **零第三方依赖**：后端只用 Python 标准库，不需要 `pip install`（下载器本身用 yt-dlp + ffmpeg）
- **断线可续**：分片级重试 15 次 + `.part` 原子替换，CDN 抽风（返回 188 字节占位响应）也能自愈

## 快速开始

### 依赖

| 组件 | 说明 |
|---|---|
| Python 3.9+ | 运行 Web 服务（只用标准库） |
| bash | Windows 需装 [Git for Windows](https://git-scm.com/download/win) |
| yt-dlp | `python -m pip install yt-dlp` |
| ffmpeg | 或用 `bash scripts/setup.sh` 自动装（含 Windows 免安装版） |

一条命令装齐：

```bash
bash scripts/setup.sh
```

### 启动

```bash
python app.py
# 打开 http://127.0.0.1:8787
```

Windows 上成品默认落在 `D:/VideoDownloads/web`，其他平台落在 `./downloads`。

## 用法

1. 把链接粘进输入框，多个链接一行一个
2. 选画质（最高 / 1080 / 720 / 480 / 仅音频）
3. 点「开始下载」，进度条走完后点「下载文件」

服务端会先解析出真实媒体地址，再决定走哪条路：

```
m3u8 + 含 -video= 阶梯   →  分片管线（能拿 1080p）
m3u8 普通清单            →  yt-dlp，失败再退 ffmpeg 直拉
普通页面链接             →  先探 HLS 清单，否则交给 yt-dlp
```

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `HOST` | `127.0.0.1` | 监听地址，部署时设 `0.0.0.0` |
| `PORT` | `8787` | 监听端口 |
| `DOWNLOAD_DIR` | `D:/VideoDownloads/web`（Windows） | 成品目录 |
| `VDL_HOME` | `D:/VideoDownloads/_tools` | 依赖目录（放 yt-dlp / ffmpeg 的入口） |
| `VDL_FFMPEG` | 自动探测 | 显式指定 ffmpeg 路径 |
| `VDL_PROXY` | 空 | 固定代理，如 `http://127.0.0.1:7897`；留空则按链接自动判断 |
| `VDL_BASH` | 自动探测 | 显式指定 bash 路径（Windows 用 Git Bash） |
| `MAX_PARALLEL` | `2` | 同时进行的任务数 |

**代理策略**：留空时逐个链接判断——先试直连（8 秒超时），不通才回落系统代理。无差别套代理会让国内站点掉到几十 KB/s；需要登录或地区限制的站点，用 `VDL_PROXY` 固定走代理。

## Docker

```bash
docker compose up -d --build
# 打开 http://127.0.0.1:8787
```

镜像内已装 ffmpeg + yt-dlp。如果目标站点需要代理，在 `docker-compose.yml` 里设 `VDL_PROXY`（本机代理用 `http://host.docker.internal:7897`）。

## 目录结构

```
app.py                  HTTP 服务：任务队列 / 进度 / 文件回传（含 Range）
web/index.html          单页前端，零构建
scripts/vdl.sh          调度层：解析链接 → 选路 → 调下载
scripts/hls_ladder.sh   分片管线：枚举档位 → 并发拉取 → 拼接 → 封装
scripts/setup.sh        安装 yt-dlp + ffmpeg
```

## 常见坑（都已处理，列出来便于排查）

| 现象 | 真实原因 |
|---|---|
| 每个分片都"成功"，整片只有几 KB | 拼 base URL 时漏了结尾 `/`，CDN 对畸形路径返回 **HTTP 200 + 188 字节** 的 fMP4 init 段，不是 404 |
| 末片被判"缺失"，整集失败 | 分片完整性阈值不能按 1MB 定——末片可能只有 0.6 秒 / 42KB。判据是 **≥20KB 且首字节 `0x47`** |
| 码率枚举返回 200 但画质没变 | 该档不存在时服务端仍回 200，但清单里分片名不带 `-video=`（那是纯音频档）。必须校验分片名 |
| 下载"成功"却只有分离的音视频文件 | yt-dlp 只认名为 `ffmpeg`/`ffmpeg.exe` 的可执行文件。`imageio-ffmpeg` 的二进制名带版本号，会静默不合并 |
| 国内站点下载掉到 40KB/s | 代理被无差别套用了。应按链接判断是否走代理 |

## 部署到公网

这台服务要做真实下载，所以**宿主机必须能访问目标站点**。两点现实约束：

1. 中国大陆机房的服务器访问不了 YouTube / BBC，这类站点需要境外机房
2. 公开部署等于给别人开下载代理，建议加访问控制（反代加 Basic Auth / Cloudflare Access），或只在内网使用

## License

MIT
