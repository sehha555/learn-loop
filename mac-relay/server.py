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
import shutil
import subprocess
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8787
# claude 一次呼叫含思考可能要一兩分鐘，比照 app 端的等待上限
CLAUDE_TIMEOUT = 180


def extract_json(text: str) -> dict:
    """模型偶爾會在 JSON 外面包 markdown 圍欄或多講一句，掐頭去尾只留物件"""
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError(f"回應裡沒有 JSON：{text[:200]}")
    return json.loads(text[start : end + 1])


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
        return extract_json(json.loads(out.stdout)["result"])
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


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
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
            result = call_claude(
                body["prompt"], body.get("image_base64"), body["schema"]
            )
            self._respond(200, result)
        except BrokenPipeError:
            # iPad 等不及先掛斷了（取消、逾時或連線斷掉），結果送不出去
            print(f"  ↳ 算完了但 iPad 已斷線，耗時 {time.monotonic() - started:.0f} 秒")
        except Exception as error:  # 失敗一律回 500，app 端會自動退回 Gemini
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
