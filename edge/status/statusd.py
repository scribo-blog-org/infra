#!/usr/bin/env python3
"""Operator API for the /status page.

Nginx keeps serving the public page on its own. This process is the only
thing that can sign in, read host memory and disk, and start, stop, or
restart a container. It accepts just those calls.
"""

import hashlib
import hmac
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

HOST_PROC = os.environ.get("HOST_PROC", "/host/proc")
HOST_ROOT = os.environ.get("HOST_ROOT", "/host")
DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
COOKIE = "scribo_status"
SESSION_TTL = 12 * 60 * 60
CPU_SAMPLE_SECONDS = 0.5
STACKS = {"prod", "stage"}
SERVICES = ("frontend", "backend", "socket", "redis", "mongo")
ACTIONS = {"start", "stop", "restart"}
FAILURES = {}
FAILURE_LOCK = threading.Lock()
SNAPSHOT_LOCK = threading.Lock()


def secret_equal(got, expected):
    return hmac.compare_digest(
        hashlib.sha256(got.encode()).digest(),
        hashlib.sha256(expected.encode()).digest(),
    )


def credentials():
    user = os.environ.get("STATUS_USER", "")
    password = os.environ.get("STATUS_PASSWORD", "")
    secret = os.environ.get("STATUS_SECRET", "")
    if user and password and len(secret) >= 16:
        return user, password, secret
    return None


def session_token(secret, now):
    payload = str(int(now) + SESSION_TTL)
    sig = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return payload + "." + sig


def session_ok(secret, token, now):
    if not secret or not token or token.count(".") != 1:
        return False
    payload, sig = token.split(".", 1)
    expected = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        return False
    try:
        return int(payload) > now
    except ValueError:
        return False


def cookie_value(header, name):
    if not header:
        return ""
    prefix = name + "="
    for part in header.split(";"):
        part = part.strip()
        if part.startswith(prefix):
            return part[len(prefix):]
    return ""


def limited(ip, now):
    with FAILURE_LOCK:
        recent = [stamp for stamp in FAILURES.get(ip, []) if now - stamp < 600]
        FAILURES[ip] = recent
        return len(recent) >= 8


def mark_failure(ip, now):
    with FAILURE_LOCK:
        FAILURES.setdefault(ip, []).append(now)


def clear_failures(ip):
    with FAILURE_LOCK:
        FAILURES.pop(ip, None)


def parse_proc_stat(text):
    start = text.find("(")
    end = text.rfind(")")
    if start < 0 or end < start:
        raise ValueError("stat")
    fields = text[end + 2:].split()
    return text[start + 1:end], int(fields[11]), int(fields[12])


def process_name(cmdline, comm):
    if cmdline:
        first = cmdline.split(b"\0", 1)[0].decode("utf-8", "replace")
        base = first.rsplit("/", 1)[-1].strip()
        if base:
            return base[:48]
    return (comm or "?").strip()[:48] or "?"


def read_meminfo(path):
    info = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if ":" not in line:
                continue
            key, rest = line.split(":", 1)
            info[key] = int(rest.split()[0]) * 1024
    return info


def cpu_total(proc_root):
    with open(os.path.join(proc_root, "stat"), encoding="utf-8") as handle:
        parts = handle.readline().split()
    if not parts or parts[0] != "cpu":
        raise ValueError("proc stat")
    return sum(int(part) for part in parts[1:])


def read_process(proc_root, pid):
    base = os.path.join(proc_root, pid)
    with open(os.path.join(base, "stat"), encoding="utf-8") as handle:
        comm, utime, stime = parse_proc_stat(handle.read())
    rss = 0
    with open(os.path.join(base, "status"), encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("VmRSS:"):
                rss = int(line.split()[1]) * 1024
                break
    try:
        with open(os.path.join(base, "cmdline"), "rb") as handle:
            cmdline = handle.read()
    except OSError:
        cmdline = b""
    return {
        "pid": int(pid),
        "name": process_name(cmdline, comm),
        "rss": rss,
        "cpu": utime + stime,
    }


def read_processes(proc_root):
    found = {}
    for pid in os.listdir(proc_root):
        if not pid.isdigit():
            continue
        try:
            found[pid] = read_process(proc_root, pid)
        except (OSError, ValueError, IndexError):
            continue
    return found


def host_snapshot(proc_root, host_root, pause):
    memory = read_meminfo(os.path.join(proc_root, "meminfo"))
    total = memory["MemTotal"]
    free = min(memory.get("MemAvailable", memory.get("MemFree", 0)), total)
    disk = os.statvfs(host_root)
    first = read_processes(proc_root)
    before = cpu_total(proc_root)
    time.sleep(pause)
    second = read_processes(proc_root)
    after = cpu_total(proc_root)
    elapsed = after - before
    cpu_top = []
    if elapsed > 0:
        for pid, proc in second.items():
            prev = first.get(pid)
            if not prev:
                continue
            delta = proc["cpu"] - prev["cpu"]
            if delta <= 0:
                continue
            cpu_top.append({
                "name": proc["name"],
                "pid": proc["pid"],
                "percent": round(delta / elapsed * 100, 1),
            })
    cpu_top.sort(key=lambda row: (-row["percent"], row["pid"]))
    memory_top = []
    for proc in second.values():
        if proc["rss"] <= 0 or total <= 0:
            continue
        memory_top.append({
            "name": proc["name"],
            "pid": proc["pid"],
            "bytes": proc["rss"],
            "percent": round(proc["rss"] / total * 100, 1),
        })
    memory_top.sort(key=lambda row: (-row["bytes"], row["pid"]))
    return {
        "disk": {
            "total": disk.f_blocks * disk.f_frsize,
            "used": (disk.f_blocks - disk.f_bfree) * disk.f_frsize,
            "free": disk.f_bavail * disk.f_frsize,
        },
        "memory": {
            "total": total,
            "used": max(total - free, 0),
            "free": free,
        },
        "memory_top": memory_top[:5],
        "cpu_top": cpu_top[:10],
    }


def docker_request(method, path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(40)
    try:
        sock.connect(DOCKER_SOCK)
        sock.sendall(f"{method} {path} HTTP/1.0\r\nHost: localhost\r\n\r\n".encode())
        chunks = []
        while True:
            data = sock.recv(65536)
            if not data:
                break
            chunks.append(data)
    finally:
        sock.close()
    raw = b"".join(chunks)
    head, _, body = raw.partition(b"\r\n\r\n")
    status = int(head.split(b"\r\n", 1)[0].split()[1])
    if body[:1] in (b"{", b"["):
        parsed = json.loads(body.decode())
    else:
        parsed = body.decode("utf-8", "replace").strip()
    return status, parsed


def service_rows(stack):
    status, body = docker_request("GET", "/v1.41/containers/json?all=1")
    if status != 200 or not isinstance(body, list):
        message = body.get("message") if isinstance(body, dict) else "docker did not list containers"
        raise RuntimeError(message)
    by_name = {}
    for container in body:
        state = container.get("State") or "unknown"
        for name in container.get("Names") or []:
            by_name[name.lstrip("/")] = state
    rows = []
    for service in SERVICES:
        rows.append({
            "service": service,
            "state": by_name.get(f"{stack}-{service}", "absent"),
        })
    return rows


def control(stack, service, action):
    name = f"{stack}-{service}"
    if action == "start":
        path = f"/v1.41/containers/{name}/start"
    elif action == "stop":
        path = f"/v1.41/containers/{name}/stop?t=10"
    else:
        path = f"/v1.41/containers/{name}/restart?t=10"
    status, body = docker_request("POST", path)
    if status in (204, 304):
        return None
    if status == 404:
        return f"No {name} container yet. On the server: ./scribo up {stack} {service}"
    if isinstance(body, dict) and body.get("message"):
        return body["message"]
    return f"docker returned {status}"


class Handler(BaseHTTPRequestHandler):
    server_version = "statusd"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def handle(self):
        try:
            super().handle()
        except (ConnectionError, socket.timeout, BrokenPipeError):
            return

    def client_ip(self):
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def send_json(self, code, payload, extra=None):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        for key, value in (extra or []):
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def reject(self, code, message):
        self.send_json(code, {"error": message})

    def authed(self):
        creds = credentials()
        if not creds:
            return False
        token = cookie_value(self.headers.get("Cookie"), COOKIE)
        return session_ok(creds[2], token, time.time())

    def guard(self):
        if self.headers.get("X-Status-Request") != "1":
            self.reject(400, "Missing operator header.")
            return False
        if urlsplit(self.path).path != "/status/api/login" and not self.authed():
            self.reject(401, "Sign in required.")
            return False
        return True

    def read_json(self):
        length = int(self.headers.get("Content-Length") or "0")
        if length < 0 or length > 2048:
            raise ValueError("body")
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        data = json.loads(raw.decode())
        if not isinstance(data, dict):
            raise ValueError("body")
        return data

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/status/api/session":
            if not self.guard():
                return
            self.send_json(200, {"ok": True})
            return
        if path == "/status/api/host":
            if not self.guard():
                return
            try:
                with SNAPSHOT_LOCK:
                    payload = host_snapshot(HOST_PROC, HOST_ROOT, CPU_SAMPLE_SECONDS)
            except OSError as exc:
                self.reject(500, "Host metrics are unavailable (%s)." % exc.strerror)
                return
            self.send_json(200, payload)
            return
        if path == "/status/api/services":
            if not self.guard():
                return
            stack = self.headers.get("X-Scribo-Stack", "")
            if stack not in STACKS:
                self.reject(400, "Unknown stack.")
                return
            try:
                self.send_json(200, {"services": service_rows(stack)})
            except (OSError, RuntimeError, socket.error) as exc:
                self.reject(502, "Docker is unavailable (%s)." % exc)
            return
        self.reject(404, "Not found.")

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/status/api/login":
            self.login()
            return
        if path == "/status/api/logout":
            if not self.guard():
                return
            self.send_json(200, {"ok": True}, [("Set-Cookie", cleared_cookie())])
            return
        parts = path.strip("/").split("/")
        if len(parts) == 5 and parts[:3] == ["status", "api", "services"]:
            if not self.guard():
                return
            self.act(parts[3], parts[4])
            return
        self.reject(404, "Not found.")

    def login(self):
        if self.headers.get("X-Status-Request") != "1":
            self.reject(400, "Missing operator header.")
            return
        creds = credentials()
        if not creds:
            sys.stderr.write("status login is not configured\n")
            self.reject(503, "Operator login is not configured.")
            return
        ip = self.client_ip()
        now = time.time()
        if limited(ip, now):
            time.sleep(0.4)
            self.reject(429, "Too many attempts. Wait and try again.")
            return
        try:
            body = self.read_json()
            user = body.get("user")
            password = body.get("password")
            if not isinstance(user, str) or not isinstance(password, str):
                raise ValueError("body")
            if len(user) > 128 or len(password) > 128:
                raise ValueError("body")
        except (ValueError, json.JSONDecodeError, UnicodeError):
            self.reject(400, "Send user and password as JSON.")
            return
        if not (secret_equal(user, creds[0]) and secret_equal(password, creds[1])):
            mark_failure(ip, now)
            time.sleep(0.4)
            self.reject(401, "Wrong user or password.")
            return
        clear_failures(ip)
        cookie = "%s=%s; HttpOnly; Secure; SameSite=Strict; Path=/status; Max-Age=%d" % (
            COOKIE, session_token(creds[2], now), SESSION_TTL
        )
        self.send_json(200, {"ok": True}, [("Set-Cookie", cookie)])

    def act(self, service, action):
        stack = self.headers.get("X-Scribo-Stack", "")
        if stack not in STACKS or service not in SERVICES or action not in ACTIONS:
            self.reject(400, "Unknown service or action.")
            return
        try:
            error = control(stack, service, action)
        except (OSError, socket.error, RuntimeError, json.JSONDecodeError) as exc:
            self.reject(502, "Docker is unavailable (%s)." % exc)
            return
        if error:
            self.reject(409, error)
            return
        try:
            rows = service_rows(stack)
        except (OSError, RuntimeError, socket.error):
            rows = []
        state = next((row["state"] for row in rows if row["service"] == service), "unknown")
        sys.stderr.write("action %s %s %s -> %s\n" % (stack, service, action, state))
        self.send_json(200, {"ok": True, "state": state})


def cleared_cookie():
    return "%s=; HttpOnly; Secure; SameSite=Strict; Path=/status; Max-Age=0" % COOKIE


def serve():
    if credentials() is None:
        sys.stderr.write(
            "status login is not configured: set STATUS_USER, STATUS_PASSWORD, "
            "and STATUS_SECRET (16+ characters) in the edge status env\n"
        )
    server = ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8090"))), Handler)
    server.daemon_threads = True
    server.serve_forever()


def self_test():
    secret = "s" * 16
    now = 1_700_000_000
    token = session_token(secret, now)
    assert session_ok(secret, token, now + 10)
    assert not session_ok(secret, token, now + SESSION_TTL + 5)
    assert not session_ok(secret, token + "ab", now + 10)
    assert not session_ok("t" * 16, token, now + 10)
    assert secret_equal("same", "same")
    assert not secret_equal("same", "other")
    assert parse_proc_stat("12 (a process) S 1 1 1 0 -1 0 1 2 3 4 8 9\n") == ("a process", 8, 9)
    assert process_name(b"/usr/bin/node\0server.js", "node") == "node"
    assert process_name(b"", "kswapd0") == "kswapd0"

    root = os.path.join(
        os.environ.get("TMPDIR", "/tmp"),
        "statusd-self-test-%d" % os.getpid(),
    )
    proc = os.path.join(root, "proc")
    pid = os.path.join(proc, "7")
    os.makedirs(pid)
    try:
        with open(os.path.join(proc, "meminfo"), "w", encoding="utf-8") as handle:
            handle.write("MemTotal:       2048 kB\nMemAvailable:   1024 kB\n")
        with open(os.path.join(proc, "stat"), "w", encoding="utf-8") as handle:
            handle.write("cpu  10 0 0 10 0 0 0 0 0 0\n")
        with open(os.path.join(pid, "stat"), "w", encoding="utf-8") as handle:
            handle.write("7 (python) S 1 1 1 0 -1 0 0 0 0 0 3 1\n")
        with open(os.path.join(pid, "status"), "w", encoding="utf-8") as handle:
            handle.write("VmRSS:\t512 kB\n")
        with open(os.path.join(pid, "cmdline"), "wb") as handle:
            handle.write(b"/usr/local/bin/python\0")
        snap = host_snapshot(proc, root, 0)
    finally:
        for dirpath, _, filenames in os.walk(root, topdown=False):
            for name in filenames:
                os.remove(os.path.join(dirpath, name))
            os.rmdir(dirpath)

    assert snap["memory"] == {"total": 2048 * 1024, "used": 1024 * 1024, "free": 1024 * 1024}
    assert snap["memory_top"] == [{
        "name": "python",
        "pid": 7,
        "bytes": 512 * 1024,
        "percent": 25.0,
    }]
    assert snap["cpu_top"] == []
    assert snap["disk"]["total"] > 0
    print("statusd self-test ok")


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        self_test()
    else:
        serve()
