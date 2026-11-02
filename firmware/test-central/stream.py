"""Drive the board over MCP and read the rig's HID reports off the serial stream."""
import json, sys, threading, time, urllib.request
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
            with urllib.request.urlopen(req, timeout=20) as r: raw=r.read().decode(); break
        except Exception:
            if attempt == tries-1: raise
            time.sleep(3)
    for line in raw.splitlines():
        if line.startswith("data:"): raw=line[5:].strip(); break
    o=json.loads(raw); c=o.get("result",{}).get("content",[])
    return json.loads(c[0]["text"]) if c else o

s = serial.Serial("/dev/cu.usbserial-3", 115200, timeout=0.3)
time.sleep(4)
reports, lock = [], threading.Lock()
stop = False
def pump():
    while not stop:
        try: line = s.readline().decode(errors="replace").strip()
        except Exception: return
        if not line: continue
        try: msg = json.loads(line)
        except json.JSONDecodeError: continue
        if "report" in msg:
            with lock: reports.append(msg["report"])
        else:
            with lock: reports.append(("STATUS", msg))
threading.Thread(target=pump, daemon=True).start()

def send(method):
    s.write((json.dumps({"method": method}) + "\n").encode()); s.flush(); time.sleep(2)

def drain():
    with lock:
        out = [r for r in reports if isinstance(r, str)]
        reports.clear()
        return out

RIG = "0c:b8:15:c3"
hosts = board("list_hosts").get("hosts", [])
mine = [h for h in hosts if h["host_id"].startswith(RIG)]
if not mine: print("rig not bonded; run chain.py first"); sys.exit(1)
hid = mine[0]["host_id"]
print("select :", board("select_host", {"host_id": hid, "request_id":"stream-sel"}).get("selected_host"))
time.sleep(4)
for attempt in range(5):
    send("rescan"); time.sleep(3); send("connect"); time.sleep(8)
    st = board("device_status")
    if st.get("hid_connected"): break
    print(f"  attempt {attempt+1}: hid_connected still False")
print("hid_connected:", st.get("hid_connected"))
if not st.get("hid_connected"): stop=True; s.close(); sys.exit(1)

drain()
print("--- MCP press_key -> board -> BLE HID -> rig, bytes as received")
for label, usage, mods in [("a",4,0), ("Tab",43,0), ("Shift+b",5,2),
                           ("Ctrl+Alt+Delete",76,5), ("F5",62,0), ("Right arrow",79,0)]:
    board("press_key", {"host_id": hid, "usage": usage, "modifiers": mods,
                        "request_id": f"stream-{usage}-{mods}"})
    time.sleep(1.2)
    got = drain()
    press = next((r for r in got if set(r.split()) != {"00"}), "(nothing)")
    print(f"  {label:16} expected usage={usage:3} mods={mods:3}  received: {press}")
board("move_pointer", {"host_id": hid, "dx": 10, "dy": -5, "request_id": "stream-move"})
time.sleep(1.2)
got = drain()
press = next((r for r in got if set(r.split()) != {"00"}), "(nothing)")
print(f"  {'move_pointer':16} expected dx=10 dy=-5          received: {press}")
stop = True; s.close()
