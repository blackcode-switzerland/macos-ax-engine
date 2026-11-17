#!/usr/bin/env python3
"""Drive the engine as an MCP client would, against the fixture program.

    python3 tests/mcp_test.py <axengine> <axfixture> <out folder>

Every action is checked against the state file the fixture writes itself.
Prints one line per check and a table; writes results.json and transcript.jsonl.
Exit code 0 = every core check passed.
"""
import json
import os
import re
import subprocess
import sys
import time

engine_path, fixture_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
state_path = os.path.join(out, "fixture-state.txt")
if os.path.exists(state_path):
    os.remove(state_path)

checks = []
transcript = open(os.path.join(out, "transcript.jsonl"), "w", encoding="utf-8")
server = subprocess.Popen([engine_path, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=open(os.path.join(out, "engine-stderr.txt"), "w"))
next_id = 0


def rpc(method, params=None):
    global next_id
    next_id += 1
    message = {"jsonrpc": "2.0", "id": next_id, "method": method}
    if params is not None:
        message["params"] = params
    line = json.dumps(message)
    transcript.write(line + "\n")
    server.stdin.write((line + "\n").encode("utf-8"))
    server.stdin.flush()
    answer = server.stdout.readline().decode("utf-8")
    transcript.write(answer)
    transcript.flush()
    if not answer:
        raise RuntimeError("the engine closed its output (it ended?)")
    return json.loads(answer)


def call(tool, **arguments):
    answer = rpc("tools/call", {"name": tool, "arguments": arguments})
    if "error" in answer:
        return {"status": "rpc-error", "message": answer["error"].get("message", "")}
    return json.loads(answer["result"]["content"][0]["text"])


def record(name, ok, detail="", core=True):
    status = ("PASS" if ok else "FAIL") if core else ("INFO-PASS" if ok else "INFO-FAIL")
    checks.append({"name": name, "status": status, "detail": str(detail)})
    print(f"[{status}] {name}" + (f" : {detail}" if detail else ""), flush=True)


def state():
    try:
        with open(state_path, encoding="utf-8") as handle:
            return dict(line.split("=", 1) for line in handle.read().splitlines() if "=" in line)
    except OSError:
        return {}


def wait_state(key, value, seconds=5.0):
    end = time.time() + seconds
    while time.time() < end:
        if state().get(key) == value:
            return True
        time.sleep(0.1)
    return state().get(key) == value


def find(view, role, name=None):
    """Id of the first line '#id Role "name"' in a view's canvas."""
    for line in (view or {}).get("canvas", "").splitlines():
        match = re.match(r'#(\d+) (\S+) "((?:[^"\\]|\\.)*)"', line)
        if match and match.group(2) == role and (name is None or match.group(3) == name):
            return int(match.group(1)), line
    return None, None


def brief(answer):
    keep = {key: answer.get(key) for key in ("status", "reason", "verified", "message") if key in answer}
    if isinstance(answer.get("verification"), dict):
        keep["check"] = answer["verification"].get("state")
    return json.dumps(keep)


def run():
    # ---- protocol
    hello = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}})
    record("initialize", hello.get("result", {}).get("serverInfo", {}).get("name") == "ax-desktop", json.dumps(hello.get("result", {}).get("serverInfo")))
    listed = [tool["name"] for tool in rpc("tools/list")["result"]["tools"]]
    expected = ["launch_app", "list_windows", "read_tree", "read_text", "read_cells", "click", "set_text", "run_steps",
                "menu", "send_keys", "verify", "close_app"]
    record("twelve-tools", listed == expected, ", ".join(listed))

    # ---- guards before anything is started
    answer = call("list_windows")
    record("nothing-owned-at-start", answer.get("status") == "ok" and answer.get("windows") == [], brief(answer))
    answer = call("read_tree", window="w1-1")
    record("refuses-window-before-launch", answer.get("reason") == "not-owned", brief(answer))
    for target in ("Safari", "/bin/bash", "Terminal", "/usr/bin/osascript", "System Settings"):
        answer = call("launch_app", path=target)
        record(f"refuses-to-start {target}", answer.get("status") == "refused"
               and answer.get("reason") in ("launch-not-allowed",), brief(answer))
    answer = call("click", snapshot="s0000", id=1)
    record("refuses-unknown-snapshot", answer.get("reason") == "unknown-snapshot", brief(answer))
    answer = call("read_tree", window="w1-1", bogus=True)
    record("refuses-unknown-argument", answer.get("reason") == "bad-arguments", brief(answer))
    answer = call("close_app", pid=1)
    record("refuses-to-close-foreign-process", answer.get("reason") == "not-owned", brief(answer))

    # ---- launch and read
    launched = call("launch_app", path=fixture_path, args=[state_path])
    windows = launched.get("windows") or []
    record("launch_app", launched.get("status") == "ok" and len(windows) == 1,
           f"status {launched.get('status')}, accessibility {launched.get('accessibility')}, windows {len(windows)}; {launched.get('message', '')}")
    if not windows:
        return
    pid, window = launched["pid"], windows[0]["id"]
    answer = call("list_windows")
    record("list_windows", [w["id"] for w in answer.get("windows", [])] == [window], json.dumps(answer.get("windows")))
    answer = call("read_tree", window="w999-999")
    record("refuses-foreign-window-id", answer.get("status") == "refused", brief(answer))

    view = call("read_tree", window=window, limit=50)
    button, _ = find(view, "Button", "Press me")
    record("read_tree", view.get("status") == "ok" and button is not None, f"{view.get('totalControls')} controls")
    print(view.get("canvas", ""))
    secret_line = next((line for line in view.get("canvas", "").splitlines() if "password-field" in line), None)
    record("password-field-marked", secret_line is not None and '="' not in secret_line and secret_line.rstrip().endswith("[]"), secret_line or "no such line")

    # ---- click, verified by expectation and by the fixture itself
    answer = call("click", snapshot=view["snapshot"], id=button, expect_text="Count: 1", limit=50)
    record("click", answer.get("status") == "dispatched" and answer.get("verified") is True, brief(answer))
    record("click-seen-by-fixture", wait_state("count", "1"), f"fixture count={state().get('count')}")
    reused = call("click", snapshot=view["snapshot"], id=button)
    record("snapshot-serves-one-action", reused.get("reason") == "expired-snapshot" and state().get("count") == "1", brief(reused))
    view = answer.get("observation") or {}

    # ---- a wrong expectation must not read as success
    button, _ = find(view, "Button", "Press me")
    answer = call("click", snapshot=view.get("snapshot", ""), id=button or 1, expect_text="Count: 99", limit=50)
    record("wrong-expectation-not-satisfied", answer.get("status") == "dispatched" and answer.get("verified") is False, brief(answer))
    record("second-click-seen-by-fixture", wait_state("count", "2"), f"fixture count={state().get('count')}")
    view = answer.get("observation") or {}

    # ---- verify, read-only
    answer = call("verify", window=window, expect_text="Count: 2")
    record("verify-satisfied", answer.get("verified") is True, brief(answer))
    answer = call("verify", window=window, expect_text="Count: 7")
    record("verify-not-satisfied", answer.get("verified") is False and state().get("count") == "2", brief(answer))
    answer = call("verify", window=window)
    record("verify-needs-an-expectation", answer.get("status") == "refused", brief(answer))

    # ---- set_text
    view = call("read_tree", window=window, limit=50)
    field, _ = find(view, "Edit")
    answer = call("set_text", snapshot=view["snapshot"], id=field or 1, text="hello from mcp", limit=50)
    record("set_text", answer.get("status") == "dispatched" and answer.get("verified") is True, brief(answer))
    record("set_text-seen-by-fixture", wait_state("field", "hello from mcp"), f"fixture field={state().get('field')!r}")
    view = answer.get("observation") or {}
    full = call("read_text", snapshot=view.get("snapshot", ""), id=field or 1)
    record("read_text-value", full.get("value") == "hello from mcp", brief(full) + f" value={full.get('value')!r}")
    lines = call("read_text", window=window)
    record("read_text-lines", "Count: 2" in lines.get("text", ""), lines.get("text", "").replace("\n", " / "))

    # ---- password field: never filled
    password = None
    for line in view.get("canvas", "").splitlines():
        if "password-field" in line:
            password = int(line.split()[0][1:])
    answer = call("set_text", snapshot=view.get("snapshot", ""), id=password or 1, text="secret")
    record("refuses-password-field", password is not None and answer.get("reason") == "password-field"
           and state().get("secretLength") == "0", brief(answer) + f"; fixture secretLength={state().get('secretLength')}")

    # ---- checkbox toggle
    view = call("read_tree", window=window, limit=50)
    box, _ = find(view, "CheckBox", "Option")
    answer = call("click", snapshot=view["snapshot"], id=box or 1, action="toggle", limit=50)
    record("toggle", answer.get("verified") is True and wait_state("check", "1"), brief(answer) + f"; fixture check={state().get('check')}")
    view = answer.get("observation") or {}
    answer = call("click", snapshot=view.get("snapshot", ""), id=box or 1, action="invoke")
    record("refuses-action-not-offered", answer.get("reason") == "unsupported-action" and state().get("check") == "1", brief(answer))

    # ---- run_steps: fill and press in one call
    view = call("read_tree", window=window, limit=50)
    field, _ = find(view, "Edit")
    button, _ = find(view, "Button", "Press me")
    answer = call("run_steps", snapshot=view["snapshot"], limit=50, steps=[
        {"id": field, "action": "set_text", "text": "two steps"},
        {"id": button, "expect_text": "Count: 3"}])
    record("run_steps", answer.get("status") == "dispatched" and answer.get("completed") == 2 and answer.get("verified") is True,
           json.dumps({k: answer.get(k) for k in ("status", "completed", "total", "stoppedBecause", "verified")}))
    record("run_steps-seen-by-fixture", wait_state("count", "3") and wait_state("field", "two steps"),
           f"fixture count={state().get('count')} field={state().get('field')!r}")
    view = call("read_tree", window=window, limit=50)
    answer = call("run_steps", snapshot=view["snapshot"], steps=[{"id": button}, {"id": 999}])
    record("run_steps-invalid-step-sends-nothing", answer.get("status") == "refused" and state().get("count") == "3", brief(answer))
    answer = call("run_steps", snapshot=view["snapshot"], steps=[
        {"id": button, "expect_text": "Count: 50"}, {"id": button}])
    record("run_steps-stops-at-failed-check", answer.get("status") == "stopped" and answer.get("completed") == 0
           and wait_state("count", "4") and not wait_state("count", "5", 1.0),
           json.dumps({k: answer.get(k) for k in ("status", "completed", "total", "stoppedBecause")}) + f"; fixture count={state().get('count')}")

    # ---- table: rows as lines, every column through read_cells, select a row
    view = call("read_tree", window=window, limit=100)
    table, _ = find(view, "Table")
    beta, beta_line = find(view, "Row", "Beta")
    record("table-rows-listed", table is not None and beta is not None, beta_line or view.get("canvas", ""))
    cells = call("read_cells", snapshot=view["snapshot"], id=table or 1)
    record("read_cells", cells.get("totalRows") == 3 and 'row 1: "Beta" | "2"' in cells.get("cells", ""),
           f"rows {cells.get('totalRows')}, columns {cells.get('totalColumns')}: " + cells.get("cells", "").replace("\n", " / ") + brief(cells))
    block = call("read_cells", snapshot=view["snapshot"], id=table or 1, row=2, column=1, rows=1, columns=1)
    record("read_cells-block", block.get("cells", "").strip() == 'row 2: "3"', block.get("cells", "").strip())
    answer = call("read_cells", snapshot=view["snapshot"], id=button)
    record("read_cells-refuses-non-grid", answer.get("reason") == "not-a-grid", brief(answer))
    answer = call("click", snapshot=view["snapshot"], id=beta or 1, action="select", limit=100)
    record("select-row", answer.get("verified") is True and wait_state("selectedRow", "1"),
           brief(answer) + f"; fixture selectedRow={state().get('selectedRow')}")

    # ---- menu
    answer = call("menu", window=window)
    record("menu-list", answer.get("status") == "ok" and "Increment" in answer.get("menu", "") and "Shut Down" not in answer.get("menu", ""),
           answer.get("menu", "").replace("\n", " / "))
    answer = call("menu", window=window, path="Actions > Reset", expect_text="Count: 0")
    record("menu-trigger", answer.get("status") == "dispatched" and answer.get("verified") is True and wait_state("count", "0"),
           brief(answer) + f"; fixture count={state().get('count')}")
    answer = call("menu", window=window, path="Actions > Nothing Here")
    record("menu-unknown-entry", answer.get("reason") == "menu-item-not-found", brief(answer))
    answer = call("menu", window=window, path="Apple > Shut Down…")
    record("refuses-apple-menu", answer.get("status") == "refused", brief(answer))

    # ---- keys to the program (informational: depends on the program being in front)
    view = call("read_tree", window=window, limit=50)
    field, _ = find(view, "Edit")
    answer = call("set_text", snapshot=view["snapshot"], id=field, text="", limit=50)
    view = answer.get("observation") or {}
    answer = call("click", snapshot=view.get("snapshot", ""), id=field, action="focus")
    answer = call("send_keys", window=window, text="abc", expect_text="abc")
    record("send_keys-text", answer.get("verified") is True and wait_state("field", "abc"),
           brief(answer) + f"; in front={answer.get('programInFront')}; fixture field={state().get('field')!r}", core=False)
    answer = call("send_keys", window=window, keys="ctrl+nonsense")
    record("send_keys-bad-key-refused", answer.get("reason") == "bad-keys", brief(answer))

    # ---- close
    answer = call("close_app", pid=pid)
    record("close_app", answer.get("status") == "ok" and answer.get("closed") is True, brief(answer))
    answer = call("list_windows")
    record("nothing-owned-after-close", answer.get("windows") == [] and answer.get("owned") == [], brief(answer))
    answer = call("read_tree", window=window)
    record("refuses-window-after-close", answer.get("status") == "refused", brief(answer))

    # ---- leaving: what the server started ends with it
    relaunched = call("launch_app", path=fixture_path, args=[state_path])
    second = relaunched.get("pid")
    server.stdin.close()
    server.wait(timeout=20)
    time.sleep(0.5)
    gone = True
    if second:
        try:
            os.kill(second, 0)
            gone = False
        except OSError:
            gone = True
    record("programs-end-with-the-server", bool(second) and gone, f"second fixture pid {second} gone={gone}")


try:
    run()
except Exception as problem:  # a crash of the driver or the engine is a failed check, with its reason
    record("test-run-completed", False, f"{type(problem).__name__}: {problem}")
finally:
    try:
        server.kill()
    except OSError:
        pass

failed = [check for check in checks if check["status"] == "FAIL"]
print("\nRESULT     CHECK")
for check in checks:
    print(f"{check['status']:<11}{check['name']}")
verdict = "PASS" if not failed and checks else "FAIL"
print(f"\nengine tools: {verdict} ({sum(c['status'] == 'PASS' for c in checks)} core passed, {len(failed)} core failed)")
with open(os.path.join(out, "results.json"), "w", encoding="utf-8") as handle:
    json.dump({"mode": "engine", "verdict": verdict, "checks": checks}, handle, indent=2)
sys.exit(0 if verdict == "PASS" else 1)
