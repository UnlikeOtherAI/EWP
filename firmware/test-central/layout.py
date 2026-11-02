"""Does changing the keyboard layout reach a host that is already connected?"""
import json, sys, time, urllib.request
from pathlib import Path
import serial
TOKEN = Path("~/.config/ewp/ewp-0cb815c55dc4.token").expanduser().read_text().strip()
def board(name, args=None):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
                       "params":{"name":name,"arguments":args or {}}}).encode()
    for a in range(4):
        try:
            req = urllib.request.Request("http://192.168.1.193:80/mcp", data=body, method="POST",
                headers={"Content-Type":"application/json","Accept":"application/json, text/event-stream",
                         "Authorization":"Bearer "+TOKEN})
            with urllib.request.urlopen(req, timeout=25) as r: raw=r.read().decode(); break
        except Exception:
            if a==3: raise
            time.sleep(4)
    for line in raw.splitlines():
        if line.startswith("data:"): raw=line[5:].strip(); break
    o=json.loads(raw); c=o.get("result",{}).get("content",[])
    return json.loads(c[0]["text"]) if c else o
s = serial.Serial("/dev/cu.usbserial-3", 115200, timeout=2); time.sleep(4)
def rig(payload):
    s.reset_input_buffer(); s.write((json.dumps(payload)+"\n").encode()); s.flush()
    end=time.time()+45
    while time.time()<end:
        line=s.readline().decode(errors="replace").strip()
        if not line: continue
        try:
            m=json.loads(line)
            if "role" in m: return m
        except json.JSONDecodeError: pass
    return {"error":"no reply"}

hosts = board("list_hosts").get("hosts", [])
rigid = next((h["host_id"] for h in hosts if h["host_id"].startswith("0c:b8:15:c3")), None)
if not rigid: print("rig not bonded; run chain.py first"); sys.exit(1)
print("select rig  :", board("select_host", {"host_id": rigid, "request_id":"lay-sel"}).get("selected_host"))
time.sleep(4)
for attempt in range(5):
    rig({"method":"rescan"}); time.sleep(3); rig({"method":"connect"}); time.sleep(8)
    if rig({"method":"status"}).get("subscribed_reports"): break
print("connected   :", {k: rig({"method":"status"}).get(k) for k in ("connected","subscribed_reports")})

print("\n-- before")
print("board says  :", board("device_status").get("keyboard_layout"))
print("rig reads   : country =", rig({"method":"hidinfo"}).get("hid_country"))

print("\n-- set_layout to US (33) while the rig stays connected")
print("board says  :", board("set_layout", {"layout": "us", "request_id": "lay-us"}))
time.sleep(5)
print("rig reads   : country =", rig({"method":"hidinfo"}).get("hid_country"),
      "| still connected:", rig({"method":"status"}).get("connected"))

print("\n-- after a reconnect")
rig({"method":"rescan"}); time.sleep(3)
for attempt in range(5):
    rig({"method":"connect"}); time.sleep(8)
    if rig({"method":"status"}).get("subscribed_reports"): break
print("rig reads   : country =", rig({"method":"hidinfo"}).get("hid_country"))
print("board says  :", board("device_status").get("keyboard_layout"))
s.close()
