"""The whole chain with no phone, from a clean slate on both sides."""
import json, sys, time, urllib.request
from pathlib import Path
import serial

TOKEN = Path("~/.config/ewp/ewp-0cb815c55dc4.token").expanduser().read_text().strip()
def board(name, args=None, tries=3):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
                       "params":{"name":name,"arguments":args or {}}}).encode()
    for attempt in range(tries):
        try:
            req = urllib.request.Request("http://192.168.1.193:80/mcp", data=body, method="POST",
                headers={"Content-Type":"application/json","Accept":"application/json, text/event-stream",
                         "Authorization":"Bearer "+TOKEN})
            with urllib.request.urlopen(req, timeout=20) as r: raw=r.read().decode()
            break
        except Exception:
            if attempt == tries-1: raise
            time.sleep(3)
    for line in raw.splitlines():
        if line.startswith("data:"): raw=line[5:].strip(); break
    o=json.loads(raw); c=o.get("result",{}).get("content",[])
    return json.loads(c[0]["text"]) if c else o

s = serial.Serial("/dev/cu.usbserial-3", 115200, timeout=3)
time.sleep(4)
def rig(method):
    s.reset_input_buffer()
    s.write((json.dumps({"method": method}) + "\n").encode()); s.flush()
    end = time.time() + 40
    while time.time() < end:
        line = s.readline().decode(errors="replace").strip()
        if not line: continue
        try: return json.loads(line)
        except json.JSONDecodeError: continue
    return {"error":"no reply"}

RIG_PREFIX = "0c:b8:15:c3"
hosts = board("list_hosts").get("hosts", [])
mine = [h for h in hosts if h["host_id"].startswith(RIG_PREFIX)]

if mine:
    # Already bonded. A pairing window would exclude it, which is the right
    # behaviour: a window is for hosts the board has never met. Re-selecting is
    # the supported way back, and it also closes any window left open.
    hid = mine[0]["host_id"]
    print("already bonded    :", hid)
    print("select            :", board("select_host", {"host_id": hid,
          "request_id":"chain-sel"}).get("selected_host"))
else:
    print("rig forgets       :", rig("forget").get("event"))
    print("window            :", board("start_pairing", {"name":"test rig",
          "request_id":"chain-1"}).get("pairing_open"))
    time.sleep(2); rig("rescan")
    for i in range(10):
        st = rig("status")
        if st.get("target"): break
        time.sleep(3)
    print("rig found         :", st.get("event"))

if not rig("status").get("target"):
    rig("rescan")
    for i in range(10):
        if rig("status").get("target"): break
        time.sleep(3)
time.sleep(4)
# The board restarts advertising with a connection allowlist after select_host,
# so the first attempt can land mid-restart and be refused.
for attempt in range(5):
    rig("connect"); time.sleep(8)
    r = rig("status")
    if r.get("encrypted") and r.get("subscribed_reports"):
        break
    print(f"  connect attempt {attempt+1}: {r.get('event')}")
    rig("rescan"); time.sleep(4)
r = rig("status")
print("rig               :", {k: r.get(k) for k in ("connected","encrypted","subscribed_reports","event")})
hosts = board("list_hosts").get("hosts", [])
mine = [h for h in hosts if h["host_id"].startswith(RIG_PREFIX)]
if not mine: print("rig did not bond"); s.close(); sys.exit(1)
hid = mine[0]["host_id"]
for i in range(10):
    st = board("device_status")
    if st.get("hid_connected"): break
    time.sleep(3)
print("hid_connected     :", st.get("hid_connected"))
if not st.get("hid_connected"):
    print("  diagnostics:", {k: st.get(k) for k in ("pairing_open","selected_host",
          "accept_rejections","subscribe_events","ble_connections")})
    s.close(); sys.exit(1)
rig("reports")
print("--- MCP press_key -> board -> BLE HID -> rig")
for label, usage, mods in [("a",4,0), ("Tab",43,0), ("Shift+b",5,2),
                           ("Ctrl+Alt+Delete",76,5), ("F5",62,0), ("Right arrow",79,0)]:
    res = board("press_key", {"host_id": hid, "usage": usage, "modifiers": mods,
                              "request_id": f"chain-{usage}-{mods}"})
    time.sleep(0.8)
    got = rig("status")
    print(f"  {label:16} notified={res.get('notified')} reports={got.get('reports_seen')} last={got.get('last_report')!r}")
mv = board("move_pointer", {"host_id": hid, "dx": 10, "dy": -5, "request_id": "chain-move"})
time.sleep(0.8); got = rig("status")
pressed = [x for x in (got.get("recent_reports") or []) if x and set(x.split()) != {"00"}]
print(f"  {'move_pointer':16} notified={mv.get('notified')} reports={got.get('reports_seen')} press={pressed[-1] if pressed else '(none)'}")
s.close()
