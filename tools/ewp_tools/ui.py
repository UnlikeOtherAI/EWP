"""Physical EWP UI control through XCTest and Apple's paired-device file service."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

from mcp.server.fastmcp import FastMCP, Image

BUNDLE = "com.unlikeotherai.ewp.UITests.xctrunner"


class USBControl:
    def __init__(self, device):
        self.device = device

    def run(self, *args, input_data=None):
        result = subprocess.run(
            ["xcrun", "devicectl", "device", *args, "--device", self.device, "--timeout", "15"],
            input=input_data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
        )
        if result.returncode:
            # Never include command payloads, clipboard text, or device output.
            raise RuntimeError("Apple device command failed; check pairing, unlock state, and the EWP UI runner")

    def copy(self, direction, source, destination):
        self.run("copy", direction, "--source", str(source), "--destination", str(destination),
                 "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE)

    def command(self, command, *, text=None, **args):
        if sys.platform != "darwin":
            raise RuntimeError("Physical UI control requires Xcode on macOS")
        import fcntl
        lock_dir = Path.home() / ".config/ewp/ui-locks"
        lock_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        # One mailbox owner per device, including separate MCP client processes.
        lock_name = uuid.uuid5(uuid.NAMESPACE_OID, self.device).hex
        with (lock_dir / lock_name).open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if text is not None:
                self.run("pasteboard", "copy", input_data=text.encode())
            request_id = str(uuid.uuid4())
            request = dict(args, id=request_id, command=command, expires=time.time() + 120)
            with tempfile.TemporaryDirectory(prefix="ewp-ui-") as scratch:
                source = Path(scratch) / "request.json"
                source.write_text(json.dumps(request))
                os.chmod(source, 0o600)
                try:
                    self.copy("to", source, "Documents/EWPControl/request.json")
                except RuntimeError:
                    # The runner may consume the file before devicectl verifies
                    # its destination. Reconcile by ID; never send it twice.
                    pass
                deadline = time.monotonic() + 110
                response_path = Path(scratch) / "response.json"
                while time.monotonic() < deadline:
                    try:
                        self.copy("from", "Documents/EWPControl/response.json", response_path)
                        response = json.loads(response_path.read_text())
                    except (RuntimeError, FileNotFoundError, json.JSONDecodeError):
                        time.sleep(0.3)
                        continue
                    if response.get("id") != request_id:
                        time.sleep(0.3)
                        continue
                    if not response.get("ok"):
                        raise RuntimeError("UI action rejected: " + str(response.get("error", "unknown")))
                    return response
            raise TimeoutError("UI response unavailable; action outcome is unknown. Take a snapshot before acting again.")


def make_ui_mcp(control):
    mcp = FastMCP("EWP physical iPad UI")

    @mcp.tool()
    def ui_snapshot() -> dict:
        """Read the physical EWP/Settings UI and system alerts. Secure values are redacted."""
        return control.command("snapshot")["state"]

    @mcp.tool()
    def ui_tap(snapshot_id: str, ref: str) -> dict:
        """Tap an enabled element from the latest UI snapshot; return the resulting UI."""
        return control.command("tap", snapshot_id=snapshot_id, ref=ref)["state"]

    @mcp.tool()
    def ui_paste(snapshot_id: str, ref: str, text: str = "", private_file: str = "") -> dict:
        """Replace a text field using the device clipboard. For credentials pass a private local file path.

        File contents never enter tool arguments, UI snapshots, or XCTest typing logs.
        The device clipboard is cleared after the action. Use one of text/private_file.
        """
        if bool(text) == bool(private_file):
            raise ValueError("Provide exactly one of text or private_file")
        if private_file:
            path = Path(private_file).expanduser()
            if not path.is_file() or path.stat().st_mode & 0o077:
                raise ValueError("Credential file must be private (chmod 600)")
            text = path.read_text().rstrip("\r\n")
        if len(text.encode()) > 4096:
            raise ValueError("Text exceeds 4096 bytes")
        try:
            return control.command("paste", snapshot_id=snapshot_id, ref=ref, text=text)["state"]
        finally:
            control.run("pasteboard", "copy", input_data=b" ")

    @mcp.tool()
    def ui_swipe(snapshot_id: str, ref: str, direction: str) -> dict:
        """Swipe a scrollable element in up/down/left/right direction and return the UI."""
        if direction not in ("up", "down", "left", "right"):
            raise ValueError("Invalid swipe direction")
        return control.command("swipe", snapshot_id=snapshot_id, ref=ref, direction=direction)["state"]

    @mcp.tool()
    def ui_activate(settings: bool = False) -> dict:
        """Open EWP, or Settings for its network/Bluetooth permissions, on the physical target."""
        return control.command("activate", bundle="com.apple.Preferences" if settings else "com.unlikeotherai.ewp")["state"]

    @mcp.tool()
    def ui_screenshot() -> Image:
        """Capture the physical device screen. May include private screen contents."""
        return Image(data=base64.b64decode(control.command("screenshot")["png"]), format="png")

    @mcp.tool()
    def ui_tap_point(snapshot_id: str, x: float, y: float) -> dict:
        """Tap normalized screen coordinates observed in the latest physical screenshot, then inspect the result."""
        if not 0 <= x <= 1 or not 0 <= y <= 1:
            raise ValueError("Coordinates must be normalized to 0..1")
        return control.command("tap_point", snapshot_id=snapshot_id, x=x, y=y)["state"]

    @mcp.tool()
    def ui_stop() -> dict:
        """End this physical UI automation session."""
        return control.command("stop")

    return mcp


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True, help="Explicit physical device UDID")
    args = parser.parse_args()
    make_ui_mcp(USBControl(args.device)).run(transport="stdio")


if __name__ == "__main__":
    main()
