"""Board 1 is the keyboard; board 2 plays the phone. No human in the loop."""
import json, time, urllib.request
from pathlib import Path
import serial

TOKEN = Path("~/.config/ewp/ewp-0cb815c55dc4.token").expanduser().read_text().strip()
def board(name, args=None):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
                       "params":{"name":name,"arguments":args or {}}}).encode()
    req = urllib.request.Request("http://192.168.1.193:80/mcp", data=body, method="POST",
        headers={"Content-Type":"application/json","Accept":"application/json, text/event-stream",
                 "Authorization":"Bearer "+TOKEN})
    with urllib.request.urlopen(req, timeout=20) as r: raw=r.read().decode()
    for line in raw.splitlines():
        if line.startswith("data:"): raw=line[5:].strip(); break
    o=json.loads(raw); c=o.get("result",{}).get("content",[])
    return json.loads(c[0]["text"]) if c else o

s = serial.Serial("/dev/cu.usbserial-3", 115200, timeout=3)
time.sleep(4)  # the open resets it; let it boot and begin scanning

def central(method, wait=2.0):
    s.reset_input_buffer()
    s.write((json.dumps({"method": method}) + "\n").encode()); s.flush()
    end = time.time() + 12
    while time.time() < end:
        line = s.readline().decode(errors="replace").strip()
        if not line: continue
        try: return json.loads(line)
        except json.JSONDecodeError: continue
    return {"error": "no reply"}

print("1. clearing the rig's bonds :", json.dumps(central("forget")))
print("2. window on the keyboard  :", json.dumps(board("start_pairing",
      {"name":"test rig","request_id":"rig-1"})))
time.sleep(3)
print("3. rig scan                :", json.dumps(central("rescan")))
for i in range(10):
    st = central("status")
    if st.get("target"):
        print(f"4. rig found after {i*3}s   : {st.get('event')} target={st.get('target')}")
        break
    time.sleep(3)
else:
    print("4. rig never saw the keyboard:", json.dumps(st)); raise SystemExit

print("5. rig connects            :", json.dumps(central("connect")))
time.sleep(3)
print("6. rig after               :", json.dumps(central("status")))
b = board("device_status")
print("7. keyboard after          :", {k: b.get(k) for k in
      ("saved_hosts","hid_connected","ble_connections","last_disconnect_reason","pairing_open")})
print("8. hosts                   :", json.dumps(board("list_hosts")))
s.close()
