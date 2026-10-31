"""Local HTTP frame receiver and stdio MCP server. Never logs credentials or pixels."""
import argparse
import hmac
import ipaddress
import json
import logging
import os
from pathlib import Path
import secrets
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler

from mcp.server.fastmcp import FastMCP, Image
from zeroconf import ServiceBrowser, ServiceInfo, Zeroconf

from .state import MAX_FRAME, State

LOG = logging.getLogger("ewp")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("Device redirects are not allowed")


class Devices:
    def __init__(self, token):
        self.token = token
        self.lock = threading.Lock()
        self.entries = {}

    def add_service(self, zc, kind, name):
        self.update_service(zc, kind, name)

    def remove_service(self, zc, kind, name):
        with self.lock:
            self.entries.pop(name, None)

    def update_service(self, zc, kind, name):
        info = zc.get_service_info(kind, name, timeout=1500)
        if not info or info.port != 80:
            return
        device_id = info.properties.get(b"id", b"").decode("utf-8", "replace")
        addresses = [a for a in info.parsed_addresses() if ipaddress.ip_address(a).is_private
                     and not ipaddress.ip_address(a).is_loopback
                     and ipaddress.ip_address(a).version == 4]
        if device_id and addresses:
            with self.lock:
                self.entries[name] = dict(id=device_id, address=addresses[0])

    def listing(self):
        with self.lock:
            return list(self.entries.values())

    def request(self, device_id, path, payload=None):
        entries = [d for d in self.listing() if d["id"] == device_id]
        if len(entries) != 1:
            raise ValueError("Device missing or duplicate id discovered; check Bonjour and Wi-Fi")
        data = json.dumps(payload).encode() if payload is not None else None
        request = Request(f"http://{entries[0]['address']}{path}", data=data,
                          headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        with build_opener(ProxyHandler({}), NoRedirect()).open(request, timeout=3) as response:
            result = json.loads(response.read(8192))
        if path == "/status" and result.get("id") != device_id:
            raise ValueError("Device identity changed")
        return result


def handler_type(state, token, devices):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def reply(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def handle_request(self):
            if self.headers.get("Origin"):
                return self.reply(403, {"error": "Browser origins are not supported"})
            if not hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {token}"):
                return self.reply(401, {"error": "Bridge token required"})
            try:
                parts = self.path.strip("/").split("/")
                if self.command == "GET" and self.path == "/status":
                    return self.reply(200, {"sessions": state.listing(), "devices": devices.listing()})
                if self.command == "DELETE" and len(parts) == 2 and parts[0] == "sessions":
                    state.remove(parts[1])
                    return self.reply(200, {"stopped": True})
                if self.command == "POST":
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 < length <= MAX_FRAME:
                        return self.reply(413, {"error": "Request too large or empty"})
                    data = self.rfile.read(length)
                    if len(data) != length:
                        raise ValueError("Truncated request")
                    if self.path == "/sessions":
                        key = state.create(json.loads(data)["device_id"])
                        return self.reply(201, {"session_id": key})
                    if len(parts) == 3 and parts[0] == "sessions" and parts[2] == "frames":
                        if self.headers.get("Content-Type") != "image/jpeg":
                            raise ValueError("Expected image/jpeg")
                        state.put(parts[1], data, int(self.headers.get("X-Orientation", "1")))
                        return self.reply(200, {"received": True})
                return self.reply(404, {"error": "Unknown endpoint"})
            except KeyError:
                return self.reply(404, {"error": "Unknown session or missing field"})
            except (ValueError, OSError, TypeError):
                return self.reply(400, {"error": "Invalid request"})

        do_GET = handle_request
        do_POST = handle_request
        do_DELETE = handle_request

    return Handler


def make_mcp(state, devices):
    mcp = FastMCP("Expensive Wall of Phones")

    @mcp.tool()
    def list_devices() -> dict:
        """List discovered ESP32 input bridges and screen-sharing sessions. Only live=true has recent frames."""
        return {"input_devices": devices.listing(), "screens": state.listing(),
                "host_switching": "Not implemented; pair one phone/tablet per ESP32"}

    @mcp.tool()
    def get_screen(session_id: str) -> Image:
        """Get the most recent screen image; fails when capture is older than five seconds."""
        return Image(data=state.screen(session_id), format="jpeg")

    @mcp.tool()
    def device_status(device_id: str) -> dict:
        """Check firmware and HID connection before sending input."""
        return devices.request(device_id, "/status")

    @mcp.tool()
    def press_key(device_id: str, usage: int, modifiers: int = 0) -> dict:
        """Press and release a USB HID keyboard usage on the paired target. Modifiers are a HID bitmask.

        Examples: Enter=40, Tab=43, Escape=41, Space=44; left GUI=8, left Shift=2.
        A successful notification is not proof that iOS acted on the key.
        """
        if type(usage) is not int or not 4 <= usage <= 101 or type(modifiers) is not int or not 0 <= modifiers <= 255:
            raise ValueError("Invalid HID usage or modifier")
        return devices.request(device_id, "/key", {"usage": usage, "modifiers": modifiers})

    @mcp.tool()
    def move_pointer(device_id: str, dx: int = 0, dy: int = 0, wheel: int = 0, click: bool = False) -> dict:
        """Move the relative HID pointer, scroll, or left-click. iPhone requires AssistiveTouch.

        Deltas are -127..127, not absolute screen coordinates. Verify results using get_screen.
        """
        if any(type(n) is not int or not -127 <= n <= 127 for n in (dx, dy, wheel)):
            raise ValueError("Pointer deltas must be -127..127")
        return devices.request(device_id, "/pointer", {"dx": dx, "dy": dy, "wheel": wheel, "click": click})

    @mcp.tool()
    def wait_for_capture(device_id: str, timeout_seconds: int = 20) -> dict:
        """Wait for a NEW frame from the companion installation id after manual broadcast confirmation.

        This does not unlock the device or start Apple's broadcast picker. Use the device_id from screens.
        """
        if not 1 <= timeout_seconds <= 30:
            raise ValueError("Timeout must be 1..30 seconds")
        started = time.monotonic()
        while time.monotonic() - started < timeout_seconds:
            with state.lock:
                for s in state.sessions.values():
                    if s.device_id == device_id and s.frame and s.received >= started:
                        return {"active": True, "session_id": s.id}
            time.sleep(0.1)
        return {"active": False, "reason": "No new frame; check broadcast confirmation and network"}

    return mcp


def read_token(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(descriptor, "w") as output:
            output.write(secrets.token_hex(32))
    token = path.read_text().strip()
    if len(token) != 64 or any(c not in "0123456789abcdef" for c in token):
        raise ValueError("Token file must contain 64 lowercase hex characters")
    return token


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--advertise-ip", required=True, help="This computer's LAN IPv4 address")
    parser.add_argument("--token-file", default=str(Path.home() / ".config/ewp/token"))
    parser.add_argument("--http-only", action="store_true", help="Run receiver without stdio MCP")
    args = parser.parse_args()
    address = ipaddress.IPv4Address(args.advertise_ip)
    if not address.is_private or address.is_loopback or address.is_unspecified:
        parser.error("Use a private LAN address")
    logging.basicConfig(level=logging.INFO)
    token = read_token(args.token_file)
    state, devices = State(), Devices(token)
    server = ThreadingHTTPServer((args.listen, args.port), handler_type(state, token, devices))
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    zc = Zeroconf(interfaces=[str(address)])
    info = ServiceInfo("_ewpbridge._tcp.local.", f"EWP-{socket.gethostname()}._ewpbridge._tcp.local.",
                       addresses=[address.packed], port=server.server_port,
                       properties={"version": "1"}, server=f"{socket.gethostname().split('.')[0]}.local.")
    browser = ServiceBrowser(zc, "_ewp._tcp.local.", devices)
    try:
        zc.register_service(info)
        LOG.info("Receiver listening on port %s; pairing token is in %s", args.port, args.token_file)
        if args.http_only:
            threading.Event().wait()
        else:
            make_mcp(state, devices).run(transport="stdio")
    finally:
        browser.cancel()
        zc.unregister_service(info)
        zc.close()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
