"""dsh-gateway - lazy front door for Windows-MCP.

Listens on 127.0.0.1:18080 (the port the SSH tunnel forwards).
Starts Windows-MCP on 127.0.0.1:18083 the first time a client connects,
and kills it again after IDLE_SECONDS of nobody using it.

Idle cost: this proxy only (~20 MB) plus the ssh tunnel (~10 MB).
"""

import os
import socket
import subprocess
import sys
import threading
import time

LISTEN = ("127.0.0.1", 18080)
UPSTREAM = ("127.0.0.1", 18083)
MCP_EXE = r"D:\dsh\mcp\venv\Scripts\windows-mcp.exe"
TOKEN_FILE = r"D:\dsh\mcp\token.txt"
LOG_FILE = r"D:\dsh\logs\gateway.log"
IDLE_SECONDS = int(os.environ.get("DSH_IDLE_SECONDS", "900"))
STACK_IDLE_SECONDS = int(os.environ.get("DSH_STACK_IDLE_SECONDS", "1800"))

TOOLS = (
    "Screenshot,Snapshot,Click,Type,Scroll,Move,Shortcut,Wait,WaitFor,"
    "Clipboard,App,Scrape,ControlStatus,DisplayInventory"
)
EXCLUDE = (
    "explorer.exe,chrome.exe,msedge.exe,firefox.exe,brave.exe,vivaldi.exe,"
    "cmd.exe,powershell.exe,pwsh.exe,WindowsTerminal.exe,wt.exe,conhost.exe,"
    "regedit.exe"
)

_lock = threading.Lock()
_proc = None
_active = 0
_last_activity = time.time()


def log(msg):
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 1024 * 1024:
            os.remove(LOG_FILE)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass


def port_open(host, port, timeout=0.4):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def _pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except Exception:
            pass


def stop_mcp(reason):
    global _proc
    if _proc is not None and _proc.poll() is None:
        log("stopping windows-mcp (%s)" % reason)
        try:
            _proc.terminate()
            _proc.wait(timeout=10)
        except Exception:
            try:
                _proc.kill()
            except Exception:
                pass
    _proc = None


def start_mcp():
    global _proc
    if _proc is not None and _proc.poll() is None and port_open(*UPSTREAM):
        return True
    stop_mcp("restart")
    token = open(TOKEN_FILE, "r", encoding="ascii").read().strip()
    env = os.environ.copy()
    env["WINDOWS_MCP_EXCLUDE_PROCESSES"] = EXCLUDE
    env["WINDOWS_MCP_SCREENSHOT_SCALE"] = "0.7"
    env["TMP"] = r"D:\dsh\tmp"
    env["TEMP"] = r"D:\dsh\tmp"
    log("starting windows-mcp on 127.0.0.1:18083")
    flags = 0x08000000 if os.name == "nt" else 0  # CREATE_NO_WINDOW
    _proc = subprocess.Popen(
        [MCP_EXE, "serve", "--transport", "streamable-http",
         "--host", "127.0.0.1", "--port", "18083",
         "--auth-key", token, "--ip-allowlist", "127.0.0.1,::1",
         "--tools", TOOLS],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=flags,
    )
    deadline = time.time() + 45
    while time.time() < deadline:
        if port_open(*UPSTREAM):
            log("windows-mcp is up")
            return True
        if _proc.poll() is not None:
            log("windows-mcp exited early, code=%s" % _proc.returncode)
            return False
        time.sleep(0.3)
    log("windows-mcp did not open the port in time")
    return False


def ensure_mcp():
    with _lock:
        return start_mcp()


def quit_stack(reason):
    log("shutting down whole stack (%s)" % reason)
    stop_mcp("stack idle")
    try:
        subprocess.run(["taskkill", "/IM", "ssh.exe", "/F"],
                       capture_output=True, creationflags=0x08000000)
    except Exception:
        pass
    os._exit(0)


def idle_watch():
    global _active, _last_activity
    while True:
        time.sleep(20)
        with _lock:
            if _active != 0:
                continue
            idle = time.time() - _last_activity
            if _proc is not None and _proc.poll() is None and idle > IDLE_SECONDS:
                stop_mcp("idle %ds" % IDLE_SECONDS)
            if idle > STACK_IDLE_SECONDS:
                quit_stack("idle %ds" % STACK_IDLE_SECONDS)


def handle(client):
    global _active, _last_activity
    _active += 1
    _last_activity = time.time()
    up = None
    try:
        if not ensure_mcp():
            return
        up = socket.create_connection(UPSTREAM, timeout=10)
        t1 = threading.Thread(target=_pump, args=(client, up), daemon=True)
        t2 = threading.Thread(target=_pump, args=(up, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception as e:
        log("proxy error: %r" % (e,))
    finally:
        _active -= 1
        _last_activity = time.time()
        for s in (client, up):
            try:
                if s:
                    s.close()
            except Exception:
                pass


def main():
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    log("gateway listening on 127.0.0.1:18080 -> 18083 (idle=%ds)" % IDLE_SECONDS)
    threading.Thread(target=idle_watch, daemon=True).start()
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN)
    srv.listen(50)
    try:
        while True:
            client, _ = srv.accept()
            threading.Thread(target=handle, args=(client,), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        stop_mcp("gateway exit")
        srv.close()


if __name__ == "__main__":
    main()
