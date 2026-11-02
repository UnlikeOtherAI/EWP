"""Two bonded hosts, switch input between them, prove keys follow the switch."""
import json, sys, threading, time, urllib.request
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
            with urllib.request.urlopen(req, timeout=20) as r: raw=r.read().decode(); break
        except Exception:
            if a==3: raise
            time.sleep(4)
    for line in raw.splitlines():
        if line.startswith("data:"): raw=line[5:].strip(); break
    o=json.loads(raw); c=o.get("result",{}).get("content",[])
    return json.loads(c[0]["text"]) if c else o

s = serial.Serial("/dev/cu.usbserial-3", 115200, timeout=0.3); time.sleep(4)
reports, lock, stop = [], threading.Lock(), False
def pump():
    while not stop:
        try: line = s.readline().decode(errors="replace").strip()
        except Exception: return
        if not line: continue
        try: m = json.loads(line)
        except json.JSONDecodeError: continue
        if "report" in m and "role" not in m:
            with lock: reports.append(m["report"])
threading.Thread(target=pump, daemon=True).start()
def send(m): s.write((json.dumps({"method":m})+"\n").encode()); s.flush(); time.sleep(2)
def drain():
    with lock:
        out = list(reports); reports.clear(); return out

hosts = board("list_hosts").get("hosts", [])
rig = next((h["host_id"] for h in hosts if h["host_id"].startswith("0c:b8:15:c3")), None)
mac = next((h["host_id"] for h in hosts if h["host_id"].startswith("d0:11:e5")), None)
print("hosts:", "rig=", rig, "mac=", mac)
if not rig or not mac: print("need both bonded"); stop=True; s.close(); sys.exit(1)

def select_and_wait(host, label, reconnect_rig):
    board("select_host", {"host_id": host, "request_id": f"sw-{label}"})
    time.sleep(4)
    for attempt in range(6):
        if reconnect_rig: send("rescan"); send("connect")
        time.sleep(6)
        st = board("device_status")
        if st.get("hid_connected"): return True
    return False

print("\n-- switch to the rig")
ok = select_and_wait(rig, "rig", True)
print("   hid_connected:", ok)
if ok:
    drain()
    board("press_key", {"host_id": rig, "usage": 4, "modifiers": 0, "request_id": "sw-k1"})
    time.sleep(1.2)
    got = [r for r in drain() if set(r.split()) != {"00"}]
    print("   rig received :", got[0] if got else "(nothing)")

print("\n-- switch to the Mac, rig must stop receiving")
ok = select_and_wait(mac, "mac", False)
print("   hid_connected:", ok)
drain()
r = board("press_key", {"host_id": mac, "usage": 5, "modifiers": 0, "request_id": "sw-k2"})
time.sleep(1.5)
leaked = [x for x in drain() if set(x.split()) != {"00"}]
print("   notified     :", r.get("notified") if isinstance(r, dict) else r)
print("   rig received :", leaked[0] if leaked else "(nothing, correct)")

print("\n-- a key aimed at the wrong host must be refused")
print("   ", board("press_key", {"host_id": rig, "usage": 6, "modifiers": 0, "request_id": "sw-k3"}))
stop = True; s.close()
