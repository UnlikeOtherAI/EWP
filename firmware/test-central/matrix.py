"""Put the board through each host profile, from a clean bond each time."""
import json, time, urllib.request
from pathlib import Path
import serial
TOKEN = Path("~/.config/ewp/ewp-0cb815c55dc4.token").expanduser().read_text().strip()
BOARD_ID = "ewp-0cb815c55dc4"
def board(name, args=None):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
                       "params":{"name":name,"arguments":args or {}}}).encode()
    for a in range(4):
        try:
            req = urllib.request.Request("http://192.168.1.193:80/mcp", data=body, method="POST",
                headers={"Content-Type":"application/json","Accept":"application/json, text/event-stream",
                         "Authorization":"Bearer "+TOKEN})
            with urllib.request.urlopen(req, timeout=20) as r: raw=r.read().decode(); break
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

print(f"{'profile':10} {'bonded':7} {'encrypted':10} {'subscribed':11} {'board saw':9} event")
for profile in ["android", "apple", "legacy", "nobond", "keyboard"]:
    for h in board("list_hosts").get("hosts", []):
        if h["host_id"].startswith("0c:b8:15:c3"):
            board("forget_host", {"host_id": h["host_id"], "confirm": BOARD_ID,
                                  "request_id": f"mx-forget-{profile}"})
    rig({"method":"forget"})
    rig({"method":"profile","name":profile})
    board("start_pairing", {"name": f"rig {profile}", "request_id": f"mx-{profile}"})
    time.sleep(2); rig({"method":"rescan"})
    for i in range(8):
        if rig({"method":"status"}).get("target"): break
        time.sleep(3)
    rig({"method":"connect"}); time.sleep(10)
    r = rig({"method":"status"})
    hosts = board("list_hosts").get("hosts", [])
    saw = any(h["host_id"].startswith("0c:b8:15:c3") for h in hosts)
    print(f"{profile:10} {str(saw):7} {str(r.get('encrypted')):10} "
          f"{str(r.get('subscribed_reports')):11} {str(saw):9} {r.get('event')}")
s.close()
