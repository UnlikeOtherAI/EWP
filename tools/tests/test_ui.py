import base64
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from ewp_tools.ui import USBControl, make_ui_mcp


class UIToolsTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.control = Mock()
        self.control.command.return_value = {"state": {"snapshot_id": "next", "elements": []}}
        self.mcp = make_ui_mcp(self.control)

    @unittest.skipIf(os.name == "nt", "Physical iPad control requires macOS file permissions")
    async def test_private_credentials_use_clipboard_and_clear_it(self):
        with tempfile.TemporaryDirectory() as folder:
            secret = Path(folder) / "token"
            secret.write_text("private-test-token")
            secret.chmod(0o600)
            await self.mcp.call_tool("ui_paste", {"snapshot_id": "fresh", "ref": "e2", "private_file": str(secret)})
        self.control.command.assert_called_once_with("paste", snapshot_id="fresh", ref="e2", text="private-test-token")
        self.control.run.assert_called_once_with("pasteboard", "copy", input_data=b" ")

    async def test_clipboard_is_cleared_when_action_fails(self):
        self.control.command.side_effect = RuntimeError("stale")
        with self.assertRaises(Exception):
            await self.mcp.call_tool("ui_paste", {"snapshot_id": "stale", "ref": "e2", "text": "public URL"})
        self.control.run.assert_called_once_with("pasteboard", "copy", input_data=b" ")

    @unittest.skipIf(os.name == "nt", "Windows does not enforce POSIX file modes")
    async def test_publicly_readable_credential_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            secret = Path(folder) / "token"
            secret.write_text("private-test-token")
            secret.chmod(0o644)
            with self.assertRaises(Exception):
                await self.mcp.call_tool("ui_paste", {"snapshot_id": "fresh", "ref": "e2", "private_file": str(secret)})
        self.control.command.assert_not_called()

    async def test_ambiguous_text_source_and_invalid_swipe_do_not_act(self):
        for name, args in [("ui_paste", {"text": "text", "private_file": "file"}),
                           ("ui_swipe", {"direction": "diagonal"})]:
            with self.assertRaises(Exception):
                await self.mcp.call_tool(name, dict(args, snapshot_id="fresh", ref="e2"))
        self.control.command.assert_not_called()

    async def test_tap_preserves_snapshot_reference(self):
        await self.mcp.call_tool("ui_tap", {"snapshot_id": "fresh", "ref": "e4"})
        self.control.command.assert_called_once_with("tap", snapshot_id="fresh", ref="e4")


class DeviceCommandTests(unittest.TestCase):
    @patch("ewp_tools.ui.subprocess.run")
    def test_device_output_and_clipboard_never_enter_errors(self, run):
        run.return_value = Mock(returncode=1, stdout=b"sensitive data", stderr=b"sensitive data")
        with self.assertRaisesRegex(RuntimeError, "Apple device command failed") as error:
            USBControl("target").run("pasteboard", "copy", input_data=b"secret")
        self.assertNotIn("sensitive", str(error.exception))
        args, kwargs = run.call_args
        self.assertIsInstance(args[0], list)
        self.assertNotIn("secret", " ".join(args[0]))
        self.assertEqual(kwargs["input"], b"secret")


class DiscoveryReportTests(unittest.TestCase):
    def test_report_names_each_role_and_endpoint(self):
        from ewp_tools.discover import report
        text = report([
            {"service": "EWP app c86caa40", "role": "app", "endpoint": "http://a.local:7801/mcp"},
            {"service": "ewp-c515b80c", "role": "keyboard", "endpoint": "http://k.local:80/mcp"},
        ])
        self.assertIn("Found 2 EWP endpoints.", text)
        self.assertIn("iPhone or iPad", text)
        self.assertIn("keyboard", text)
        self.assertIn("http://k.local:80/mcp", text)

    def test_report_explains_an_empty_result(self):
        from ewp_tools.discover import report
        text = report([])
        self.assertIn("No EWP endpoints answered.", text)
        self.assertIn("multicast DNS", text)
