"""dsh-gateway - lazy front door for Windows-MCP + human-confirmed deletion.

Listens on 127.0.0.1:18080 (what the SSH tunnel forwards).
Starts Windows-MCP on 127.0.0.1:18083 the first time a client connects and
stops it again after IDLE_SECONDS of nobody using it.

Deletion: the agent cannot delete anything. It can only drop a request file into
  D:\\dsh\\work\\trash-requests\\<id>.json
containing {"id", "reason", "paths"}. This process shows a native dialog with the
reason and the file list, and only after the human clicks Yes moves those paths
to the Recycle Bin. While the dialog is up, every MCP connection is refused so
the agent cannot click the dialog itself.
"""

import ctypes
import json
import os
import socket
import subprocess
import threading
import time

LISTEN = ("127.0.0.1", 18080)
UPSTREAM = ("127.0.0.1", 18083)
MCP_EXE = r"D:\dsh\mcp\venv\Scripts\windows-mcp.exe"
TOKEN_FILE = r"D:\dsh\mcp\token.txt"
LOG_FILE = r"D:\dsh\logs\gateway.log"
TRASH_DIR = r"D:\dsh\work\trash-requests"
IDLE_SECONDS = int(os.environ.get("DSH_IDLE_SECONDS", "900"))
STACK_IDLE_SECONDS = int(os.environ.get("DSH_STACK_IDLE_SECONDS", "1800"))
MAX_PATHS = 50
MIN_REASON = 10

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
_frozen = False
_conns = set()
_handled = set()

FO_DELETE = 3
FOF_ALLOWUNDO = 0x40
FOF_SILENT = 0x04
FOF_NOCONFIRMATION = 0x10
FOF_NOERRORUI = 0x400


class SHFILEOPSTRUCTW(ctypes.Structure):
    _fields_ = [
        ("hwnd", ctypes.c_void_p),
        ("wFunc", ctypes.c_uint),
        ("pFrom", ctypes.c_wchar_p),
        ("pTo", ctypes.c_wchar_p),
        ("fFlags", ctypes.c_ushort),
        ("fAnyOperationsAborted", ctypes.c_int),
        ("hNameMappings", ctypes.c_void_p),
        ("lpszProgressTitle", ctypes.c_wchar_p),
    ]


def ask_yes_no(title, text):
    MB_YESNO, MB_ICONWARNING, MB_TOPMOST, MB_SETFOREGROUND = 0x04, 0x30, 0x10000, 0x1000
    r = ctypes.windll.user32.MessageBoxW(
        None, text, title, MB_YESNO | MB_ICONWARNING | MB_TOPMOST | MB_SETFOREGROUND
    )
    return r == 6


def drive_is_fixed(path):
    root = os.path.splitdrive(os.path.abspath(path))[0]
    if not root:
        return False
    return ctypes.windll.kernel32.GetDriveTypeW(root + "\\") == 3


def human(n):
    for unit in ("B", "KB", "MB"):
        if n < 1024:
            return "%d %s" % (n, unit)
        n /= 1024.0
    return "%.1f GB" % n


def path_size(p, budget=None):
    if budget is None:
        budget = [4000]
    try:
        if os.path.isfile(p):
            return os.path.getsize(p)
        total = 0
        for root, _dirs, files in os.walk(p):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
                budget[0] -= 1
                if budget[0] <= 0:
                    return total
        return total
    except OSError:
        return 0


def recycle(paths):
    op = SHFILEOPSTRUCTW()
    op.hwnd = None
    op.wFunc = FO_DELETE
    op.pFrom = "\0".join(paths) + "\0\0"
    op.pTo = None
    op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI
    op.fAnyOperationsAborted = 0
    op.hNameMappings = None
    op.lpszProgressTitle = None
    rc = ctypes.windll.shell32.SHFileOperationW(ctypes.byref(op))
    return rc, bool(op.fAnyOperationsAborted)


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
    _proc = subprocess.Popen(
        [MCP_EXE, "serve", "--transport", "streamable-http",
         "--host", "127.0.0.1", "--port", "18083",
         "--auth-key", token, "--ip-allowlist", "127.0.0.1,::1",
         "--tools", TOOLS],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=0x08000000,
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


def freeze():
    global _frozen
    _frozen = True
    for s in list(_conns):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            s.close()
        except Exception:
            pass
    _conns.clear()


def unfreeze():
    global _frozen
    _frozen = False


def handle(client):
    global _active, _last_activity
    if _frozen:
        try:
            client.close()
        except Exception:
            pass
        return
    _active += 1
    _last_activity = time.time()
    _conns.add(client)
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
        _conns.discard(client)
        for s in (client, up):
            try:
                if s:
                    s.close()
            except Exception:
                pass


def validate(req):
    paths = req.get("paths") or []
    reason = (req.get("reason") or "").strip()
    if not isinstance(paths, list) or not paths:
        return "路径列表为空"
    if len(paths) > MAX_PATHS:
        return "一次最多 %d 项" % MAX_PATHS
    if len(reason) < MIN_REASON:
        return "理由太短（至少 %d 字）" % MIN_REASON
    for p in paths:
        if not isinstance(p, str) or not os.path.isabs(p):
            return "路径不是绝对路径: %r" % (p,)
        if not drive_is_fixed(p):
            return "不是本机固定磁盘（网络盘/移动盘没有回收站）: %s" % p
        if not os.path.exists(p):
            return "不存在: %s" % p
    return None


def build_dialog_text(reason, paths):
    lines = ["为什么删：", reason, "", "删什么："]
    for p in paths[:8]:
        lines.append("  %s   %s" % (p, human(path_size(p))))
    if len(paths) > 8:
        lines.append("  …… 另外 %d 项" % (len(paths) - 8))
    lines.append("")
    lines.append("共 %d 项。" % len(paths))
    lines.append("")
    lines.append("这些会【移入回收站】，可以还原。")
    lines.append("清空回收站需要你本人操作，我永远没有这个能力。")
    return "\n".join(lines)


def process_request(path):
    name = os.path.basename(path)
    rid = name[:-5] if name.endswith(".json") else name
    result_path = os.path.join(TRASH_DIR, rid + ".result.json")

    def write_result(status, message):
        with open(result_path, "w", encoding="utf-8") as f:
            json.dump({"id": rid, "status": status, "message": message},
                      f, ensure_ascii=False)

    try:
        with open(path, "r", encoding="utf-8") as f:
            req = json.load(f)
    except Exception as e:
        write_result("error", "请求文件无法解析: %r" % (e,))
        return

    paths = req.get("paths") or []
    reason = (req.get("reason") or "").strip()

    err = validate(req)
    if err:
        log("trash %s rejected: %s" % (rid, err))
        write_result("error", err)
        return

    freeze()
    try:
        log("trash %s asking human for %d path(s)" % (rid, len(paths)))
        if not ask_yes_no("DSH 请求删除文件", build_dialog_text(reason, paths)):
            log("trash %s denied" % rid)
            write_result("rejected", "你点了拒绝，什么都没发生。")
            return
        before = [p for p in paths if os.path.exists(p)]
        rc, aborted = recycle(before)
        if rc != 0 or aborted:
            log("trash %s failed rc=%s aborted=%s" % (rid, rc, aborted))
            write_result("error", "移入回收站失败 (rc=%s)" % rc)
            return
        left = [p for p in before if os.path.exists(p)]
        if left:
            write_result("error", "部分未移动: %s" % ", ".join(left[:5]))
            return
        log("trash %s moved %d item(s)" % (rid, len(before)))
        write_result("approved",
                     "已移入回收站 %d 项。清空回收站需要你本人操作。" % len(before))
    finally:
        unfreeze()


def trash_watch():
    os.makedirs(TRASH_DIR, exist_ok=True)
    while True:
        time.sleep(2)
        if _frozen:
            continue
        try:
            names = [n for n in os.listdir(TRASH_DIR)
                     if n.endswith(".json") and not n.endswith(".result.json")]
        except OSError:
            continue
        for n in sorted(names):
            rid = n[:-5]
            if rid in _handled:
                continue
            _handled.add(rid)
            try:
                process_request(os.path.join(TRASH_DIR, n))
            except Exception as e:
                log("trash watcher error: %r" % (e,))


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
            if _frozen or _active != 0:
                continue
            idle = time.time() - _last_activity
            if _proc is not None and _proc.poll() is None and idle > IDLE_SECONDS:
                stop_mcp("idle %ds" % IDLE_SECONDS)
            if idle > STACK_IDLE_SECONDS:
                quit_stack("idle %ds" % STACK_IDLE_SECONDS)


def main():
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    log("gateway listening on 127.0.0.1:18080 -> 18083 (idle=%ds, stack=%ds)"
        % (IDLE_SECONDS, STACK_IDLE_SECONDS))
    threading.Thread(target=idle_watch, daemon=True).start()
    threading.Thread(target=trash_watch, daemon=True).start()
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
