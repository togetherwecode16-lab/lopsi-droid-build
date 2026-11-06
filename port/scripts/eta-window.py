#!/usr/bin/env python3
"""Open a live window for the LopsiDroid build: process, latest log, and ETA."""

import json
import os
import re
import subprocess
import threading
import time
import webbrowser
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PORT_DIR = Path(__file__).resolve().parents[1]
LOG = PORT_DIR / "logs" / "build-dot-a17-container.log"
IDLE_MSG = "NO PROCESS FOUND FOR ETA BY BILU SINGHI PINGI"
HOST = "127.0.0.1"
PORT_NUM = 8765

NINJA_RE = re.compile(r"\[(\d+)/(\d+)\]")
NINJA_LINE_RE = re.compile(r"^\[(\d+)/(\d+)\]")
SOONG_RE = re.compile(r"\[\s*(\d+)%\s+(\d+)/(\d+)\]")
START_RE = re.compile(r"CONTAINER_BUILD_START (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)")
# This machine's ninja graph load, from NINJA_DIRECT to the first [step/total] line.
GRAPH_LOAD_SEC = 10 * 60

state = {
    "mode": "task",
    "samples": deque(maxlen=8),
    "soong_samples": deque(maxlen=8),
    "scan_pos": 0,
    "carry": "",
    "pending_step": "",
    "step_kept": False,
    "important": deque(maxlen=80),
    "progress": deque(maxlen=16),
    "last_done": None,
    "last_total": None,
    "build_start_ts": None,
    "pace": deque(maxlen=120),
    "modules": {},
    "missing": {},
}
lock = threading.Lock()


def pids(pattern):
    try:
        out = subprocess.check_output(["pgrep", "-fl", pattern], text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return []
    rows = []
    for line in out.splitlines():
        if "eta-window.py" in line or "pgrep" in line:
            continue
        rows.append(line.strip())
    return rows


def read_tail(path, max_bytes=180_000):
    if not path.exists():
        return ""
    with path.open("rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        fh.seek(max(0, size - max_bytes))
        return fh.read().decode("utf-8", "replace")


def latest_start(text):
    mark = "CONTAINER_BUILD_START "
    idx = text.rfind(mark)
    return text[idx:] if idx >= 0 else text


def format_span(seconds):
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes:02d}m"
    return f"{minutes}m {secs:02d}s"


def graph_load_eta(section):
    match = START_RE.search(section)
    if not match:
        return "--:--", "Ninja is loading the build graph."
    started = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    elapsed = (datetime.now(timezone.utc) - started).total_seconds()
    remain = GRAPH_LOAD_SEC - elapsed
    if remain > 0:
        return format_span(remain), "Chewing through the build graph. Compile resumes when this hits zero."
    return format_span(elapsed), "Still chewing the build graph, past the usual 10 minutes. This clock is time spent loading."


def recent_progress(text):
    return [ln for ln in text.splitlines() if NINJA_LINE_RE.match(ln)][-12:]


def module_of(line):
    body = line.split("] ", 1)[-1]
    if " <= " in body:
        left = body.split(" <= ", 1)[0]
        if ": " in left:
            return left.split(": ")[-1].strip()
        return left.strip()
    token = body.split()
    return token[0][:120] if token else "unknown"


def short_error(line):
    if "fatal error:" in line:
        return line.split("fatal error:", 1)[1].strip()[:220]
    if "Duplicate root dir" in line:
        return "Duplicate root dir: /aosp"
    match = re.search(r":\d+:\d+: error: (.+)$", line)
    if match:
        return match.group(1).strip()[:220]
    return None


def reset_errors():
    state["pending_step"] = ""
    state["step_kept"] = False
    state["important"].clear()
    state["progress"].clear()
    state["last_done"] = None
    state["last_total"] = None
    state["build_start_ts"] = None
    state["pace"].clear()
    state["modules"] = {}
    state["missing"] = {}


def keep_failure(line):
    err = short_error(line)
    failed = line.startswith("FAILED:")
    if not err and not failed:
        return
    pending = state["pending_step"]
    if pending and not state["step_kept"]:
        state["important"].append(pending)
        state["step_kept"] = True
    if failed:
        parts = line.split(None, 1)
        path = parts[1].strip() if len(parts) > 1 else "unknown"
        state["important"].append("FAILED: " + path.rsplit("/", 1)[-1])
        return
    shown = line.strip()
    if len(shown) > 240 or "fatal error:" not in shown:
        shown = err
    state["important"].append(shown)
    name = module_of(pending) if pending else "unknown"
    rec = state["modules"].setdefault(name, [0, []])
    rec[0] += 1
    if err not in rec[1] and len(rec[1]) < 5:
        rec[1].append(err)
    missing = re.search(r"'([^']+)' file not found", err or "")
    if missing:
        key = missing.group(1)
        state["missing"][key] = state["missing"].get(key, 0) + 1


def consume_line(line):
    if line.startswith("CONTAINER_BUILD_START "):
        reset_errors()
        match = START_RE.search(line)
        if match:
            state["build_start_ts"] = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        return
    step = NINJA_LINE_RE.match(line)
    if step and len(line) < 400:
        done = int(step.group(1))
        total = int(step.group(2))
        # Parallel ninja prints steps out of order. Keep the highest step seen.
        if state["last_done"] is None or done >= state["last_done"]:
            state["last_done"] = done
            state["last_total"] = total
        state["pending_step"] = line
        state["step_kept"] = False
        state["progress"].append(line)
        return
    if line.startswith("ninja:") and any(word in line for word in ("error", "stopped", "FAILED")):
        state["important"].append(line[:240])
        return
    keep_failure(line)


def scan_log():
    if not LOG.exists():
        return
    size = LOG.stat().st_size
    if state["scan_pos"] > size:
        state["scan_pos"] = 0
        state["carry"] = ""
        reset_errors()
    with LOG.open("rb") as fh:
        fh.seek(state["scan_pos"])
        data = fh.read()
        state["scan_pos"] = fh.tell()
    if not data and not state["carry"]:
        return
    text = state["carry"] + data.decode("utf-8", "replace")
    if text.endswith("\n"):
        state["carry"] = ""
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
    else:
        parts = text.split("\n")
        state["carry"] = parts.pop()
        lines = parts
    for line in lines:
        consume_line(line)


def format_important():
    if not state["important"]:
        return "No compilation errors in this run yet."
    return "\n".join(state["important"])


def format_deps():
    modules = state["modules"]
    missing = state["missing"]
    if not modules and not missing:
        return "No dependencies with compilation errors in this run yet."
    lines = []
    if missing:
        lines.append("Missing files")
        for name, count in sorted(missing.items(), key=lambda item: -item[1])[:24]:
            lines.append(f"  {count:4}  {name}")
        lines.append("")
    ranked = sorted(modules.items(), key=lambda item: -item[1][0])[:24]
    lines.append(f"{len(modules)} dependencies failed")
    for name, (count, errors) in ranked:
        lines.append(f"{name}  ({count} failed)")
        for err in errors:
            lines.append(f"  {err}")
    return "\n".join(lines)


def note_pace(done, total):
    now = time.time()
    pace = state["pace"]
    if pace and done < pace[-1][1]:
        return
    if pace and done == pace[-1][1] and now - pace[-1][0] < 20:
        return
    pace.append((now, done, total))
    while len(pace) > 2 and now - pace[0][0] > 20 * 60:
        pace.popleft()


def compile_eta(done, total):
    """Average pace since this ninja started compiling.

    A single slow file must not be multiplied by the remaining step count.
    """
    note_pace(done, total)
    now = time.time()
    started = state.get("build_start_ts")
    if not started:
        return "--:--", "Measuring compile speed."
    # Graph load is not compile time. Count pace only after that window.
    compile_elapsed = now - started - GRAPH_LOAD_SEC
    if compile_elapsed < 120 or done < 30:
        return "--:--", "Measuring compile speed. Need a couple of minutes of real steps."
    average = (total - done) / (done / compile_elapsed)
    pace = state["pace"]
    message = "Average pace since this compile resumed. One slow file does not reset this."
    if len(pace) >= 2:
        dt = pace[-1][0] - pace[0][0]
        dd = pace[-1][1] - pace[0][1]
        if dt >= 90 and dd >= 8:
            recent = (total - done) / (dd / dt)
            # Trust a recent pace only when it is in the same range as the average.
            if average / 3 <= recent <= average * 3:
                blended = (average * 2 + recent) / 3
                return format_span(blended), message
            if recent > average * 3:
                message = "Average pace since this compile resumed. The last files are slower, and they are not used as the whole ETA."
    return format_span(average), message


def snapshot():
    with lock:
        return _snapshot()


def _snapshot():
    scan_log()
    build = pids("[b]uild-dot-a17-container.sh")
    full = read_tail(LOG)
    section = latest_start(full)
    soong = "SOONG_UI_DIRECT" in section and "NINJA_DIRECT" not in section
    running = bool(build)
    mode = state["mode"]
    if mode == "graph" and not soong:
        mode = "task"
        state["mode"] = "task"

    if not running:
        state["samples"].clear()
        state["soong_samples"].clear()
        return {
            "clock": "00:00",
            "message": IDLE_MSG,
            "process": "none",
            "log": "No build process is running.",
            "important": format_important(),
            "deps": format_deps(),
            "soong": False,
            "mode": mode,
        }

    proc = build[-1]
    progress = list(state["progress"]) or recent_progress(full)
    this_run_step = state["last_done"] is not None or bool(NINJA_LINE_RE.search(section))
    if mode == "graph" and soong:
        match = None
        for match in SOONG_RE.finditer(section):
            pass
        if match:
            clock, message = compile_eta(int(match.group(2)), int(match.group(3)))
            message = "ETA until Soong finishes this graph, from the average pace."
        else:
            clock, message = "--:--", "Soong is running. ETA appears after it prints progress."
        kind = "soong"
        log = "\n".join(progress) if progress else "(no soong progress yet)"
    elif this_run_step:
        if state["last_done"] is not None:
            done, total = state["last_done"], state["last_total"]
        else:
            match = None
            for match in NINJA_RE.finditer(section):
                pass
            done, total = int(match.group(1)), int(match.group(2))
        clock, message = compile_eta(done, total)
        kind = "ninja"
        log = "\n".join(progress[-16:])
    else:
        clock, message = graph_load_eta(section)
        kind = "ninja"
        last = progress[-1] if progress else "(no earlier step)"
        log = "\n".join([
            "Ninja is chewing through the build graph. No new compile line yet.",
            "Resume point, last saved step:",
            last,
            "",
            section.strip(),
        ])
    return {
        "clock": clock,
        "message": message,
        "process": f"{kind}\n{proc[:240]}",
        "log": log,
        "important": format_important(),
        "deps": format_deps(),
        "soong": soong,
        "mode": mode,
    }


PAGE = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>LopsiDroid ETA</title>
<style>
  body { margin: 0; font-family: Menlo, monospace; background: #fff; color: #111; }
  main { padding: 20px 24px; }
  #clock { font-size: 64px; font-weight: 700; letter-spacing: -1px; }
  #message { color: #9a3412; margin: 8px 0 16px; font-size: 14px; }
  label { margin-right: 16px; font-size: 14px; }
  h2 { font-size: 13px; margin: 18px 0 6px; letter-spacing: 0.04em; }
  #proc { white-space: pre-wrap; margin: 12px 0; font-size: 13px; }
  .pane { white-space: pre; overflow: auto; border: 1px solid #111; padding: 10px; font-size: 12px; }
  #log { height: 220px; }
  #important { height: 220px; background: #fff7ed; }
  #deps { height: 260px; background: #fef2f2; }
  button, label { font-family: inherit; font-size: 14px; }
  button { margin-right: 8px; }
  label { margin-left: 12px; }
</style>
</head>
<body>
<main>
  <div id="clock">00:00</div>
  <div id="message">loading</div>
  <div>
    <button id="task" type="button">next task</button>
    <button id="graph" type="button">next graph</button>
    <label><input id="autoscroll" type="checkbox" checked> auto scroll</label>
  </div>
  <div id="proc"></div>
  <h2>LATEST LOG</h2>
  <div id="log" class="pane"></div>
  <h2>IMPORTANT PARTS OF LOG</h2>
  <div id="important" class="pane"></div>
  <h2>DEPENDENCIES WITH COMPILATION ERRORS</h2>
  <div id="deps" class="pane"></div>
</main>
<script>
async function setMode(mode) {
  await fetch("/mode?value=" + mode, {method: "POST"});
  tick();
}
document.getElementById("task").onclick = () => setMode("task");
document.getElementById("graph").onclick = () => setMode("graph");
function setPane(id, text, follow) {
  const el = document.getElementById(id);
  const prev = el.scrollTop;
  if (el.textContent !== text) el.textContent = text;
  if (follow) el.scrollTop = el.scrollHeight;
  else el.scrollTop = prev;
}
async function tick() {
  const data = await (await fetch("/status")).json();
  const follow = document.getElementById("autoscroll").checked;
  document.getElementById("clock").textContent = data.clock;
  document.getElementById("message").textContent = data.message;
  document.getElementById("proc").textContent = "process: " + data.process;
  setPane("log", data.log, follow);
  setPane("important", data.important, follow);
  setPane("deps", data.deps, false);
  const graph = document.getElementById("graph");
  graph.disabled = !data.soong;
  document.getElementById("task").style.fontWeight = data.mode === "task" ? "700" : "400";
  graph.style.fontWeight = data.mode === "graph" ? "700" : "400";
}
tick();
setInterval(tick, 2000);
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/status":
            body = json.dumps(snapshot()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if path in ("/", "/index.html"):
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/mode":
            value = parse_qs(parsed.query).get("value", ["task"])[0]
            if value in ("task", "graph"):
                with lock:
                    state["mode"] = value
            self.send_response(204)
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()


def main():
    server = ThreadingHTTPServer((HOST, PORT_NUM), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://{HOST}:{PORT_NUM}/"
    print(url, flush=True)
    webbrowser.open(url)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
