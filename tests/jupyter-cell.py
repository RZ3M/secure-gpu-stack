#!/usr/bin/env python3
"""Run one cell in a new JupyterLab kernel, the way a browser does: REST call
to start the kernel, then the cell over the kernel's websocket.

    python3 tests/jupyter-cell.py URL TOKEN_FILE CODE

URL is the tunnel's local end (http://localhost:8888 after
`ssh -N -L 8888:/run/sgs-jupyter/USER/jupyter.sock USER@HOST`); TOKEN_FILE
holds the token (~/.local/share/jupyter/sgs-token on the machine). Prints the
cell's output, deletes the kernel, and exits 1 if the cell raised, or if the
kernel died or the cell ran past CELL_TIMEOUT seconds (default 900). Needs
tornado (any Jupyter install has it).
"""
import asyncio, json, os, sys, uuid
from tornado import httpclient, websocket


async def run(base, token, code):
    auth = {"Authorization": f"token {token}"}
    http = httpclient.AsyncHTTPClient()
    kernel = json.loads((await http.fetch(f"{base}/api/kernels", method="POST", body="{}", headers=auth)).body)["id"]
    try:
        ws = await websocket.websocket_connect(httpclient.HTTPRequest(
            f"{base.replace('http', 'ws', 1)}/api/kernels/{kernel}/channels", headers=auth))
        msg_id = uuid.uuid4().hex
        ws.write_message(json.dumps({
            "header": {"msg_id": msg_id, "msg_type": "execute_request", "username": "test",
                       "session": uuid.uuid4().hex, "version": "5.3"},
            "parent_header": {}, "metadata": {}, "channel": "shell",
            "content": {"code": code, "silent": False, "store_history": False,
                        "user_expressions": {}, "allow_stdin": False}}))
        # The reply and the kernel's "idle" can come in either order; a
        # kernel that dies is restarted by the server, and the cell never
        # finishes (seen on the Lambda A100): both used to wait forever.
        status, idle = None, False
        while True:
            raw = await ws.read_message()
            if raw is None:
                sys.exit("the kernel's websocket closed before the cell finished")
            m = json.loads(raw)
            kind, content = m["msg_type"], m["content"]
            if kind == "status" and content.get("execution_state") in ("restarting", "dead"):
                sys.exit(f"the kernel died during the cell ({content['execution_state']})")
            if m.get("parent_header", {}).get("msg_id") != msg_id:
                continue
            if kind == "stream":
                print(content["text"], end="")
            elif kind in ("execute_result", "display_data"):
                print(content["data"].get("text/plain", ""))
            elif kind == "error":
                print("\n".join(content["traceback"]))
            elif kind == "execute_reply":
                status = content["status"]
            elif kind == "status" and content["execution_state"] == "idle":
                idle = True
            if status and idle:
                return status == "ok"
    finally:
        await http.fetch(f"{base}/api/kernels/{kernel}", method="DELETE", headers=auth)


url, token_file, code = sys.argv[1:4]
timeout = float(os.environ.get("CELL_TIMEOUT", "900"))
try:
    ok = asyncio.run(asyncio.wait_for(run(url.rstrip("/"), open(token_file).read().strip(), code), timeout))
except asyncio.TimeoutError:
    sys.exit(f"the cell didn't finish in {timeout:.0f} s (CELL_TIMEOUT)")
sys.exit(0 if ok else 1)
