#!/usr/bin/env python3
"""视频下载器 Web 版 —— 打开网页、粘贴链接、拿到文件。

只做三件事：收链接 → 调 scripts/vdl.sh → 把成品回传给浏览器。
下载逻辑全部复用 vdl.sh，不在这一层重写。
纯标准库实现，不需要 pip install。
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlparse

ROOT = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.join(ROOT, "web")
VDL_SH = os.path.join(ROOT, "scripts", "vdl.sh")

MEDIA_EXT = (".mp4", ".m4a", ".mkv", ".webm", ".ts", ".flv", ".mov", ".mp3")
PROGRESS_RE = re.compile(r"(\d{1,3}(?:\.\d+)?)%\s+of")
# 分片管线自报的进度：[进度] 12/57 (21%)
PROGRESS2_RE = re.compile(r"\[进度\]\s*\d+/\d+\s*\((\d{1,3})%\)")
# 从日志里抓成品路径：兼容 Windows 盘符与 POSIX 路径
PATH_RE = re.compile(r"(?:[A-Za-z]:)?[^\s\"'<>|,;]*?\.(?:mp4|m4a|mkv|webm|ts|flv|mov|mp3)(?![a-z0-9])",
                     re.I)


def _default_downloads() -> str:
    """Windows 上默认落 D 盘（C 盘空间紧张），其他平台落项目内 downloads。"""
    if os.name == "nt" and os.path.isdir("D:/"):
        return "D:/VideoDownloads/web"
    return os.path.join(ROOT, "downloads")


DL_DIR = os.path.abspath(os.environ.get("DOWNLOAD_DIR") or _default_downloads())
WORK_DIR = os.environ.get("VDL_WORK") or os.path.join(DL_DIR, ".work")
VDL_HOME = os.environ.get("VDL_HOME") or ("D:/VideoDownloads/_tools" if os.name == "nt" else os.path.join(ROOT, ".tools"))
PROXY = os.environ.get("VDL_PROXY", "").strip()
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8787"))
MAX_PARALLEL = max(1, int(os.environ.get("MAX_PARALLEL", "2")))
MAX_LOG = 600


def find_bash() -> str | None:
    """Windows 上优先 Git Bash；必须排除 system32\\bash.exe（那是 WSL，路径不通用）。"""
    cands = [
        os.environ.get("VDL_BASH", ""),
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
        "/bin/bash",
        "/usr/bin/bash",
    ]
    for c in cands:
        if c and os.path.isfile(c):
            return c
    w = shutil.which("bash")
    if w and "system32" not in w.lower().replace("/", "\\"):
        return w
    return None


BASH = find_bash()

JOBS: dict[str, dict] = {}
# 必须可重入：public_view() 会在已持锁的路径里再次取锁
LOCK = threading.RLock()
SEM = threading.Semaphore(MAX_PARALLEL)


def log(job: dict, line: str) -> None:
    line = line.replace("\r", "").strip()
    if not line:
        return
    pct = None
    sparse = PROGRESS2_RE.search(line)  # 分片管线自报，本来就稀疏，原样保留
    if sparse:
        pct = float(sparse.group(1))
    else:
        m = PROGRESS_RE.search(line)  # yt-dlp 进度行，很密
        if m:
            pct = float(m.group(1))
    with LOCK:
        if pct is not None:
            job["progress"] = min(100.0, pct)
            # yt-dlp 的进度行只保留 5% 里程碑，避免刷屏
            if not sparse and int(pct) % 5:
                return
        job["lines"].append(line[:400])
        if len(job["lines"]) > MAX_LOG:
            del job["lines"][: len(job["lines"]) - MAX_LOG]
        job["updated"] = time.time()
        # 顺手记录日志里出现的成品路径（最可靠的成品定位依据）
        for cand in PATH_RE.findall(line):
            cand = cand.strip("\"'`()[]")
            if len(cand) > 4 and os.path.isfile(cand) and os.path.getsize(cand) > 1024:
                job.setdefault("paths", [])
                if cand not in job["paths"]:
                    job["paths"].append(cand)


def resolve_output(job: dict) -> str | None:
    """按可靠度依次尝试：日志中出现的路径 → 指定文件名 → 目录内最新媒体文件。"""
    for p in reversed(job.get("paths") or []):
        if os.path.isfile(p) and os.path.getsize(p) > 1024:
            return p
    if job.get("name"):
        for ext in MEDIA_EXT:
            p = os.path.join(DL_DIR, job["name"] + ext)
            if os.path.isfile(p) and os.path.getsize(p) > 1024:
                return p
    return newest_media(job["started"] - 2)


def sanitize_name(name: str) -> str:
    name = re.sub(r'[\\/:*?"<>|]+', "_", name).strip(" .")
    return name[:80]


def newest_media(since: float, prefer: str = "") -> str | None:
    """找本次任务新产生的媒体文件，优先匹配指定文件名。"""
    if not os.path.isdir(DL_DIR):
        return None
    hits = []
    for fn in os.listdir(DL_DIR):
        p = os.path.join(DL_DIR, fn)
        if not os.path.isfile(p) or not fn.lower().endswith(MEDIA_EXT):
            continue
        try:
            st = os.stat(p)
        except OSError:
            continue
        if st.st_mtime + 2 < since or st.st_size < 1024:
            continue
        hits.append((fn, st.st_mtime, st.st_size))
    if not hits:
        return None
    if prefer:
        for fn, _, _ in hits:
            if fn.startswith(prefer):
                return os.path.join(DL_DIR, fn)
    fn = max(hits, key=lambda h: h[1])[0]
    return os.path.join(DL_DIR, fn)


def cleanup_work() -> int:
    """清理分片临时目录，返回释放的字节数。只动本工具自己生成的条目。"""
    freed = 0
    if not os.path.isdir(WORK_DIR):
        return 0
    for name in os.listdir(WORK_DIR):
        p = os.path.join(WORK_DIR, name)
        if not (name.startswith("seg_") or name.startswith("probe_") or name == "merged.ts"):
            continue  # 不是本工具产生的，不碰
        try:
            if os.path.isdir(p):
                for root, _dirs, files in os.walk(p):
                    for f in files:
                        try:
                            freed += os.path.getsize(os.path.join(root, f))
                        except OSError:
                            pass
                shutil.rmtree(p, ignore_errors=True)
            else:
                freed += os.path.getsize(p)
                os.remove(p)
        except OSError:
            pass
    return freed


def kill_tree(pid: int) -> None:
    """只 terminate bash 的话，被它拉起的 curl/ffmpeg 会继续跑完并留下半成品。"""
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)],
                           capture_output=True, timeout=20)
        else:
            import signal
            os.killpg(os.getpgid(pid), signal.SIGKILL)
    except Exception:  # noqa: BLE001
        pass


def run_job(job: dict) -> None:
    with SEM:
        job["status"] = "running"
        job["started"] = time.time()
        log(job, f"[web] 开始下载: {job['url']}")
        cmd = [BASH, VDL_SH, job["url"], "-o", DL_DIR, "-q", job["quality"], "-N", "4"]
        if job.get("name"):
            cmd += ["-n", job["name"]]

        env = os.environ.copy()
        env.update({
            "VDL_HOME": VDL_HOME,
            "VDL_WORK": WORK_DIR,
            "PYTHONIOENCODING": "utf-8",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        })
        # 让 vdl.sh 自己拼 PYTHONPATH（它知道 Windows 用 ';'），继承值可能污染
        env.pop("PYTHONPATH", None)
        if PROXY:
            env["VDL_PROXY"] = PROXY

        try:
            p = subprocess.Popen(
                cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
                start_new_session=(os.name != "nt"),
            )
        except Exception as exc:  # noqa: BLE001
            job["status"] = "error"
            job["error"] = f"启动失败: {exc}"
            log(job, job["error"])
            return

        with LOCK:
            job["proc"] = p

        try:
            assert p.stdout is not None
            for line in p.stdout:
                log(job, line)
            rc = p.wait()
        except Exception as exc:  # noqa: BLE001
            rc = -1
            log(job, f"[web] 读取输出异常: {exc}")

        job["ended"] = time.time()
        if job.get("cancelled"):
            job["status"] = "cancelled"
            log(job, "[web] 已取消")
            return
        out = resolve_output(job)
        if rc == 0 and out:
            st = os.stat(out)
            job["file"] = out
            job["filename"] = os.path.basename(out)
            job["size"] = st.st_size
            job["status"] = "done"
            job["progress"] = 100.0
            log(job, f"[web] 完成: {job['filename']} ({st.st_size / 1048576:.1f} MB)")
        else:
            job["status"] = "error"
            job["error"] = job.get("error") or (
                "下载失败（未生成文件）" if rc == 0 else f"下载脚本退出码 {rc}"
            )
            log(job, f"[web] {job['error']}")


def create_job(url: str, quality: str, name: str) -> dict:
    job = {
        "id": uuid.uuid4().hex[:12],
        "url": url,
        "quality": quality,
        "name": sanitize_name(name) if name else "",
        "status": "queued",
        "progress": 0.0,
        "created": time.time(),
        "updated": time.time(),
        "lines": [],
        "paths": [],
        "file": None,
        "filename": None,
        "size": 0,
        "error": None,
    }
    with LOCK:
        JOBS[job["id"]] = job
    threading.Thread(target=run_job, args=(job,), daemon=True).start()
    return job


def public_view(job: dict, with_log: bool = True) -> dict:
    with LOCK:
        view = {
            "id": job["id"],
            "url": job["url"],
            "quality": job["quality"],
            "status": job["status"],
            "progress": round(job.get("progress", 0.0), 1),
            "size": job.get("size", 0),
            "filename": job.get("filename"),
            "error": job.get("error"),
            "elapsed": round((job.get("ended") or time.time()) - (job.get("started") or job["created"]), 1),
        }
        if with_log:
            view["log"] = job["lines"][-120:]
        return view


def health() -> dict:
    ytdlp = False
    try:
        env = os.environ.copy()
        env["PYTHONPATH"] = os.path.join(VDL_HOME, "pylibs")
        r = subprocess.run([sys.executable, "-c", "import yt_dlp"], env=env,
                           capture_output=True, timeout=25)
        ytdlp = r.returncode == 0
    except Exception:  # noqa: BLE001
        ytdlp = False
    ff = ""
    for cand in (
        os.environ.get("VDL_FFMPEG", ""),
        os.path.join(VDL_HOME, "bin", "ffmpeg.exe"),
        os.path.join(VDL_HOME, "bin", "ffmpeg"),
    ):
        if cand and os.path.isfile(cand):
            ff = cand
            break
    if not ff:
        ff = shutil.which("ffmpeg") or ""
    if not ff:
        base = os.path.join(VDL_HOME, "ffbin", "imageio_ffmpeg", "binaries")
        if os.path.isdir(base):
            for fn in sorted(os.listdir(base)):
                if fn.startswith("ffmpeg"):
                    ff = os.path.join(base, fn)
                    break
    return {
        "bash": BASH or "",
        "ffmpeg": ff,
        "ytdlp": ytdlp,
        "downloads": DL_DIR,
        "proxy": PROXY or "(按链接自动判断)",
        "parallel": MAX_PARALLEL,
        "ready": bool(BASH and ff and ytdlp),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "VideoDL/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # 安静一点，只留错误
        if str(args[1] if len(args) > 1 else "")[:1] in ("4", "5"):
            sys.stderr.write("[http] %s\n" % (fmt % args))

    # ---------- 响应工具 ----------
    def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code: int, data: dict) -> None:
        self._send(code, json.dumps(data, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")

    def _read_json(self) -> dict:
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > 1 << 20:
                return {}
            return json.loads(self.rfile.read(n).decode("utf-8", "replace"))
        except Exception:  # noqa: BLE001
            return {}

    # ---------- 路由 ----------
    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            fp = os.path.join(WEB_DIR, "index.html")
            if not os.path.isfile(fp):
                return self._send(500, b"web/index.html missing", "text/plain; charset=utf-8")
            with open(fp, "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if path == "/api/health":
            return self._json(200, health())
        if path == "/api/jobs":
            with LOCK:
                items = [public_view(j, with_log=False) for j in JOBS.values()]
            items.sort(key=lambda x: x["id"], reverse=True)
            return self._json(200, {"jobs": items})
        m = re.fullmatch(r"/api/jobs/([0-9a-f]{12})", path)
        if m:
            job = JOBS.get(m.group(1))
            if not job:
                return self._json(404, {"error": "任务不存在"})
            return self._json(200, public_view(job))
        m = re.fullmatch(r"/api/jobs/([0-9a-f]{12})/file", path)
        if m:
            return self._serve_file(JOBS.get(m.group(1)))
        return self._send(404, b"not found", "text/plain; charset=utf-8")

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/api/jobs":
            data = self._read_json()
            raw = str(data.get("urls") or "")
            quality = str(data.get("quality") or "max")
            name = str(data.get("name") or "")
            if quality not in ("max", "1080", "720", "480", "audio"):
                quality = "max"
            urls = []
            for line in raw.splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if not re.match(r"^https?://", line, re.I):
                    line = "https://" + line
                urls.append(line)
            if not urls:
                return self._json(400, {"error": "请先粘贴至少一个链接"})
            if not BASH:
                return self._json(500, {"error": "找不到 bash，Windows 请安装 Git for Windows"})
            jobs = [public_view(create_job(u, quality, name if len(urls) == 1 else ""), with_log=False)
                    for u in urls[:20]]
            return self._json(200, {"jobs": jobs})
        if path == "/api/cleanup":
            busy = any(j["status"] in ("running", "queued") for j in JOBS.values())
            if busy:
                return self._json(409, {"error": "有任务正在跑，稍后再清理"})
            return self._json(200, {"ok": True, "freed": cleanup_work()})
        m = re.fullmatch(r"/api/jobs/([0-9a-f]{12})/cancel", path)
        if m:
            job = JOBS.get(m.group(1))
            if not job:
                return self._json(404, {"error": "任务不存在"})
            p = job.get("proc")
            if p and p.poll() is None:
                job["cancelled"] = True
                kill_tree(p.pid)
                return self._json(200, {"ok": True})
            return self._json(200, {"ok": False, "error": "任务未在运行"})
        return self._send(404, b"not found", "text/plain; charset=utf-8")

    def do_DELETE(self) -> None:  # noqa: N802
        m = re.fullmatch(r"/api/jobs/([0-9a-f]{12})", urlparse(self.path).path)
        if not m:
            return self._send(404, b"not found", "text/plain; charset=utf-8")
        job = JOBS.pop(m.group(1), None)
        if not job:
            return self._json(404, {"error": "任务不存在"})
        fp = job.get("file")
        if fp and os.path.isfile(fp) and os.path.abspath(fp).startswith(DL_DIR):
            try:
                os.remove(fp)
            except OSError:
                pass
        return self._json(200, {"ok": True})

    # ---------- 文件服务（支持 Range，便于浏览器内预览） ----------
    def _serve_file(self, job: dict | None) -> None:
        if not job or job.get("status") != "done" or not job.get("file"):
            return self._send(404, b"file not ready", "text/plain; charset=utf-8")
        fp = job["file"]
        if not os.path.isfile(fp):
            return self._send(404, b"file gone", "text/plain; charset=utf-8")
        size = os.path.getsize(fp)
        name = job.get("filename") or os.path.basename(fp)
        ext = os.path.splitext(name)[1].lower()
        ctype = {
            ".mp4": "video/mp4", ".m4a": "audio/mp4", ".mp3": "audio/mpeg",
            ".webm": "video/webm", ".mkv": "video/x-matroska", ".mov": "video/quicktime",
        }.get(ext, "application/octet-stream")
        disp = "attachment; filename=\"video%s\"; filename*=UTF-8''%s" % (ext, quote(name))
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        code = 200
        if rng:
            mm = re.match(r"bytes=(\d*)-(\d*)", rng.strip())
            if mm:
                if mm.group(1):
                    start = int(mm.group(1))
                    if mm.group(2):
                        end = min(int(mm.group(2)), size - 1)
                elif mm.group(2):
                    start = max(0, size - int(mm.group(2)))
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                code = 206
        length = end - start + 1
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Disposition", disp)
        if code == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(fp, "rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(262144, left))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass
    os.makedirs(DL_DIR, exist_ok=True)
    if not BASH:
        print("!! 找不到 bash：Windows 请安装 Git for Windows，或设置 VDL_BASH 指向 bash.exe", file=sys.stderr)

    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.daemon_threads = True
    show = "127.0.0.1" if HOST in ("0.0.0.0", "") else HOST
    print(f"视频下载器已启动  ->  http://{show}:{PORT}")
    print(f"成品目录: {DL_DIR}")
    print(f"bash: {BASH}")
    h = health()
    print(f"ffmpeg: {h['ffmpeg'] or '未找到'} | yt-dlp: {'OK' if h['ytdlp'] else '未找到'}")
    if not h["ready"]:
        print("提示: 依赖不全，执行 bash scripts/setup.sh 安装 ffmpeg + yt-dlp")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")


if __name__ == "__main__":
    main()
