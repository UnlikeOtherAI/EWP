"""Exercise Claude's actual stdio MCP transport, not only Python tool functions."""
import asyncio
import base64
from io import BytesIO
import json
from pathlib import Path
import secrets
import socket
import sys
import tempfile
import unittest
from urllib.request import Request, urlopen

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from PIL import Image

from ewp.server import local_address


class MCPTests(unittest.IsolatedAsyncioTestCase):
    async def test_stdio_schema_and_frame_lifecycle(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        with tempfile.TemporaryDirectory() as directory:
            token = secrets.token_hex(32)
            token_path = Path(directory) / "token"
            token_path.write_text(token)
            params = StdioServerParameters(command=sys.executable, args=[
                "-m", "ewp.server", "--listen", "127.0.0.1", "--advertise-ip", local_address(),
                "--port", str(port), "--token-file", str(token_path)])

            def http(path, body=None, content_type="application/json", method=None):
                request = Request(f"http://127.0.0.1:{port}{path}", data=body, method=method,
                                  headers={"Authorization": f"Bearer {token}", "Content-Type": content_type})
                with urlopen(request, timeout=3) as response:
                    return json.load(response)

            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as client:
                    initialized = await client.initialize()
                    self.assertEqual(initialized.serverInfo.name, "Expensive Wall of Phones")
                    tools = await client.list_tools()
                    self.assertEqual({t.name for t in tools.tools}, {
                        "list_devices", "get_screen", "device_status", "press_key", "move_pointer", "wait_for_capture"})
                    empty = await client.call_tool("list_devices", {})
                    self.assertFalse(empty.isError)
                    missing = await client.call_tool("get_screen", {"session_id": "missing"})
                    self.assertTrue(missing.isError)
                    session = (await asyncio.to_thread(http, "/sessions", json.dumps({"device_id": "test-ipad"}).encode()))["session_id"]
                    waiting = asyncio.create_task(client.call_tool("wait_for_capture", {"device_id": "test-ipad", "timeout_seconds": 2}))
                    await asyncio.sleep(0.2)
                    output = BytesIO()
                    Image.new("RGB", (24, 16), "blue").save(output, "JPEG")
                    await asyncio.to_thread(http, f"/sessions/{session}/frames", output.getvalue(), "image/jpeg")
                    capture = await waiting
                    self.assertFalse(capture.isError)
                    self.assertEqual(capture.structuredContent, {"active": True, "session_id": session})
                    screen = await client.call_tool("get_screen", {"session_id": session})
                    self.assertFalse(screen.isError)
                    self.assertEqual(screen.content[0].type, "image")
                    self.assertEqual(screen.content[0].mimeType, "image/jpeg")
                    with Image.open(BytesIO(base64.b64decode(screen.content[0].data))) as frame:
                        self.assertEqual(frame.size, (24, 16))
                    await asyncio.to_thread(http, f"/sessions/{session}", method="DELETE")
                    stopped = await client.call_tool("get_screen", {"session_id": session})
                    self.assertTrue(stopped.isError)


if __name__ == "__main__":
    unittest.main()
