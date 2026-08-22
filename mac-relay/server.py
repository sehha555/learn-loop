#!/usr/bin/env python3
"""learn-loop 的 Mac 中繼站。

iPad app 把 prompt＋截圖丟過來，這裡叫本機的 Claude Code（claude -p）處理，
把結果 JSON 原樣回傳 —— 吃訂閱額度，不走 API 計費。

prompt 和輸出格式（JSON Schema）都由 app 端決定，這裡只轉手不加料，
免得同一份 prompt 在 Swift 和 Python 各存一份、改了忘記同步。

跑法：python3 mac-relay/server.py
（只用 Python 內建模組，不用裝任何東西；Mac 要保持不睡才收得到）
"""

import base64
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8787
# 每次呼叫的 prompt 與回答都留一行，之後拿來看使用者都在問什麼、回頭改 app 端的 prompt。
# 放在 Logs 不放 repo：repo 是 public，學習紀錄不該進 git
CALLS_LOG = os.path.expanduser("~/Library/Logs/learn-loop-calls.jsonl")
# claude 一次呼叫含思考可能要一兩分鐘，比照 app 端的等待上限
CLAUDE_TIMEOUT = 180
# 畫圖用的 python（裝了 matplotlib 的獨立 venv，不碰系統 python）。
# 建法：python3 -m venv "$FIGURE_PYTHON 的上兩層" && .../bin/python -m pip install matplotlib
FIGURE_PYTHON = os.path.expanduser("~/Library/Application Support/learn-loop/venv/bin/python")
FIGURE_TIMEOUT = 30
# 模型給的畫圖程式前面接這段：不開視窗、中文字型、統一尺寸；後面接存檔
FIGURE_PRELUDE = '''
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
plt.rcParams["font.family"] = ["PingFang TC", "Heiti TC", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False
plt.figure(figsize=(5, 3.6), dpi=160)
'''
# \le、\ge、\ne 後面不是字母的，補成 \leq、\geq、\neq
FIGURE_MATH_ALIASES = re.compile(r"\\(?:le|ge|ne)(?![A-Za-z])")
FIGURE_EPILOGUE = '''
plt.tight_layout()
plt.savefig("figure.png", transparent=False, facecolor="white")
'''


# 沒跳脫的 LaTeX 反斜線：後面接兩個以上英文字母的是指令（\\frac、\\int、\\neq ——
# 就算開頭撞到 JSON 的 \\f \\n \\t 也一樣），後面接非 JSON 跳脫字元的是符號（\\, \\{ \\ ）
LATEX_BACKSLASH = re.compile(r'\\(?=[A-Za-z]{2,})|\\(?![\"\\/bfnrtu])')


def extract_json(text: str) -> dict:
    """模型偶爾會在 JSON 外面包 markdown 圍欄或多講一句，掐頭去尾只留物件。

    字串裡的 LaTeX 反斜線模型也常忘了跳脫（\\int 在 JSON 裡是非法的 \\i），
    先照原樣解，失敗再把 LaTeX 指令的反斜線補成雙反斜線重解一次。
    strict=False 是讓字串裡直接出現的換行也過關。
    """
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError(f"回應裡沒有 JSON：{text[:200]}")
    raw = text[start : end + 1]
    try:
        return json.loads(raw, strict=False)
    except json.JSONDecodeError:
        return json.loads(LATEX_BACKSLASH.sub(r"\\\\", raw), strict=False)


def result_envelope(stdout: str) -> dict:
    """claude -p 的 stdout 偶爾不只一行 JSON（多帶事件訊息），只要 type=result 那個。"""
    for line in stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") == "result":
            return obj
    raise RuntimeError(f"claude 沒回 result 物件：{stdout[:300]}")


def call_claude(prompt: str, image_b64: str | None, schema: dict) -> dict:
    # 圖片落地成暫存檔讓 claude 用 Read 讀。放進獨立目錄並把它當工作目錄，
    # headless 模式下讀工作目錄內的檔案不會卡權限確認
    workdir = tempfile.mkdtemp(prefix="learn-loop-relay-")
    try:
        if image_b64:
            img_path = os.path.join(workdir, "input.jpg")
            with open(img_path, "wb") as f:
                f.write(base64.b64decode(image_b64))
            prompt = f"先用 Read 工具讀這張圖：{img_path}\n\n{prompt}"

        prompt += (
            "\n\n輸出規則：只輸出一個符合下面 JSON Schema 的 JSON 物件，"
            "不要 markdown 圍欄、不要任何其他文字。\n"
            + json.dumps(schema, ensure_ascii=False)
        )

        out = subprocess.run(
            # sonnet：診斷題目夠用、比預設模型快也省額度
            ["claude", "-p", prompt, "--model", "sonnet", "--output-format", "json"],
            capture_output=True,
            text=True,
            timeout=CLAUDE_TIMEOUT,
            cwd=workdir,
        )
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip()[:300] or "claude 執行失敗")
        return extract_json(result_envelope(out.stdout)["result"])
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def render_figure(code: str) -> str | None:
    """模型回的 matplotlib 程式跑成 PNG，回 base64。畫不出來就回 None、原因進 log ——
    圖是附加的，畫失敗不該讓整個回答跟著失敗。"""
    if not os.path.exists(FIGURE_PYTHON):
        print("  ↳ 圖略過：找不到畫圖用的 python", flush=True)
        return None
    # matplotlib 的數學字型只認 \leq 不認 \le（LaTeX 兩種都行，模型愛寫短的）
    code = FIGURE_MATH_ALIASES.sub(lambda m: m.group(0) + "q", code)
    workdir = tempfile.mkdtemp(prefix="learn-loop-figure-")
    try:
        script = os.path.join(workdir, "draw.py")
        png = os.path.join(workdir, "figure.png")
        # 第一次正常畫；標籤裡的數學式還是解析不了就關掉數學字型重畫，文字照印、圖照出
        for extra in ("", 'plt.rcParams["text.parse_math"] = False\n'):
            with open(script, "w") as f:
                f.write(FIGURE_PRELUDE + extra + code + FIGURE_EPILOGUE)
            out = subprocess.run(
                [FIGURE_PYTHON, script], capture_output=True, text=True,
                timeout=FIGURE_TIMEOUT, cwd=workdir,
            )
            if out.returncode == 0 and os.path.exists(png):
                with open(png, "rb") as f:
                    return base64.b64encode(f.read()).decode()
            print(f"  ↳ 圖畫失敗：{out.stderr.strip()[-300:]}", flush=True)
        return None
    except subprocess.TimeoutExpired:
        print("  ↳ 圖畫失敗：超過 30 秒", flush=True)
        return None
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def record_call(prompt: str, has_image: bool, result: dict, seconds: float) -> None:
    entry = {
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "has_image": has_image,
        "seconds": round(seconds),
        "prompt": prompt,
        "result": {k: ("（PNG）" if k == "figure_png" else v) for k, v in result.items()},
    }
    with open(CALLS_LOG, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    def _respond(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # app 用這個快速確認 Mac 醒著，2 秒內沒回就退回 Gemini
    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"ok": True})
        else:
            self._respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/call":
            self._respond(404, {"error": "not found"})
            return
        started = time.monotonic()
        # 開始就印一行：標準 log 是回應完才寫，看 log 尾巴會以為沒人在算，
        # 8/22 就這樣在使用者等答案時裝了新版 app 把連線砍掉
        print(f"{self.log_date_time_string()} {self.client_address[0]} POST /call 開始", flush=True)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
            result = call_claude(
                body["prompt"], body.get("image_base64"), body["schema"]
            )
            # 模型覺得畫圖有幫助時會多回一段 matplotlib 程式：這裡跑成圖一起回去，
            # app 只拿到 PNG，不用知道怎麼畫
            code = result.pop("figure", None)
            if isinstance(code, str) and code.strip():
                png = render_figure(code)
                if png:
                    result["figure_png"] = png
            record_call(
                body["prompt"], bool(body.get("image_base64")), result,
                time.monotonic() - started,
            )
            self._respond(200, result)
        except BrokenPipeError:
            # iPad 等不及先掛斷了（取消、逾時或連線斷掉），結果送不出去
            print(f"  ↳ 算完了但 iPad 已斷線，耗時 {time.monotonic() - started:.0f} 秒")
        except Exception as error:  # 失敗一律回 500，app 端會自動退回 Gemini
            # 原因印出來：之前只回給 iPad，log 裡只剩一行 500，事後查不到為什麼
            print(f"  ↳ 失敗（{time.monotonic() - started:.0f} 秒）：{str(error)[:300]}", flush=True)
            self._respond(500, {"error": str(error)})
        else:
            print(f"  ↳ claude 耗時 {time.monotonic() - started:.0f} 秒")

    def log_message(self, format, *args):  # noqa: A002
        # 預設 log 會印完整路徑很吵，只留時間＋來源 IP＋方法＋狀態
        # （來源 127.0.0.1 是 Mac 自己打的，區網 IP 才是 iPad）
        print(
            f"{self.log_date_time_string()} {self.client_address[0]} "
            f"{self.command} {self.path} -> {args[-2] if len(args) >= 2 else ''}"
        )


if __name__ == "__main__":
    print(f"learn-loop 中繼站跑起來了，port {PORT}（Ctrl+C 停止）")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
