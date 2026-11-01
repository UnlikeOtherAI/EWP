import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from ewp_tools import fleet

PORTS = {"keyboard": 80, "app": 7801, "screen": 7802}
DEVICES = [
    {"id": "ewp-aaaaaaaaaaaa", "name": "R4-CTRL-1", "role": "controller", "row": 4},
    {"id": "phone-1", "name": "R4-01", "role": "phone", "row": 4, "col": 1, "controller": "R4-CTRL-1", "group": ["ios18"]},
    {"id": "phone-2", "name": "R4-02", "role": "phone", "row": 4, "col": 2, "controller": "ewp-aaaaaaaaaaaa"},
    {"id": "mac-1", "name": "R4-MAC", "role": "computer", "row": 4, "col": 3, "controller": "R4-CTRL-1"},
    {"id": "tablet-1", "name": "R5-01", "role": "tablet", "row": 5, "col": 1},
]


def seen(device_id, role, host=None):
    """One entry as ewp_tools.discover.discover() returns it."""
    host = host or device_id
    return {"service": f"{host}-{role}._mcp._tcp.local.", "device_id": device_id, "role": role,
            "endpoint": f"http://{host}.local:{PORTS[role]}/mcp", "addresses": []}


def url(device_id, role):
    return seen(device_id, role)["endpoint"]


class WallCase(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.dir = Path(folder.name)
        self.wall = self.write_wall(copy.deepcopy(DEVICES))

    def token(self, device_id):
        return f"secret-token-{device_id}"

    def write_wall(self, devices):
        for device in devices:
            token_file = self.dir / f"{device['id']}.token"
            if not token_file.exists():
                token_file.write_text(self.token(device["id"]) + "\n")
                token_file.chmod(0o600)
            device.setdefault("token_file", str(token_file))
        path = self.dir / "wall.json"
        path.write_text(json.dumps({"devices": devices}))
        return path

    def run_cli(self, *argv, entries=(), answers=None):
        out, err = io.StringIO(), io.StringIO()

        def answer(address, token, tool, timeout=5):
            value = (answers or {})[address]
            if isinstance(value, Exception):
                raise value
            return value

        with patch("ewp_tools.fleet.discover", return_value=list(entries)), \
                patch("ewp_tools.fleet.call_tool", side_effect=answer) as call, \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = fleet.main([argv[0], "--wall", str(self.wall), *argv[1:]])
        return code, out.getvalue(), err.getvalue(), call


class LoadWallTests(WallCase):
    def test_controllers_resolve_by_name_or_id_and_tokens_default_to_the_config_directory(self):
        self.write_wall([dict(DEVICES[0]), {"id": "p", "name": "P1", "role": "phone", "controller": "R4-CTRL-1"}])
        wall = fleet.load_wall(self.wall)
        self.assertEqual(wall[1].controller, "ewp-aaaaaaaaaaaa")
        device = fleet.parse_device({"id": "x-1", "name": "X1", "role": "phone"})
        self.assertEqual(device.token_file, fleet.CONFIG_DIR / "x-1.token")

    def test_each_mistake_is_named_without_a_traceback(self):
        mistakes = {
            "tokens never go in wall.json": {"token": "abc"},
            "unknown field colour": {"colour": "red"},
            "name must be": {"name": "x" * 33},
            "role must be": {"role": "toaster"},
            "bare hostname": {"address_hint": "http://phone.local"},
            "row must be a whole number": {"row": "four"},
            "group must be a list": {"group": "row4"},
            "is not a device with role": {"controller": "nobody"},
            "not served by another controller": {"role": "controller", "controller": "R4-CTRL-1"},
            "name appears more than once": {"name": "r4-ctrl-1"},
            "id appears more than once": {"id": "EWP-AAAAAAAAAAAA"},
        }
        for message, change in mistakes.items():
            with self.subTest(message):
                devices = copy.deepcopy(DEVICES)
                devices[1].update(change)
                self.write_wall(devices)
                with self.assertRaisesRegex(fleet.WallError, message):
                    fleet.load_wall(self.wall)

    def test_a_controller_must_be_a_controller(self):
        devices = copy.deepcopy(DEVICES)
        devices[2]["controller"] = "R4-01"
        self.write_wall(devices)
        with self.assertRaisesRegex(fleet.WallError, "is not a device with role"):
            fleet.load_wall(self.wall)

    def test_missing_empty_and_malformed_files(self):
        with self.assertRaisesRegex(fleet.WallError, "No inventory at"):
            fleet.load_wall(self.dir / "absent.json")
        for text, message in (("{", "Cannot read"), ('{"devices": []}', "at least one device"), ("[]", "at least one device")):
            self.wall.write_text(text)
            with self.assertRaisesRegex(fleet.WallError, message):
                fleet.load_wall(self.wall)

    def test_errors_exit_with_a_message_and_no_traceback(self):
        self.wall.write_text("{")
        code, out, err, _ = self.run_cli("status")
        self.assertEqual(code, 2)
        self.assertIn("ewp-fleet:", err)
        self.assertEqual(out, "")


class StatusTests(WallCase):
    def test_reports_each_state_and_exits_nonzero(self):
        entries = [seen("ewp-aaaaaaaaaaaa", "keyboard"), seen("phone-1", "screen"), seen("phone-2", "app")]
        answers = {url("ewp-aaaaaaaaaaaa", "keyboard"): {"hid_connected": True, "selected_host": "abc"},
                   url("phone-1", "screen"): {"device_id": "phone-1", "live": True}}
        code, out, _, call = self.run_cli("status", entries=entries, answers=answers)
        self.assertEqual(code, 1)
        self.assertIn("2 of 4 wall devices are up.", out)
        self.assertRegex(out, r"R4-CTRL-1\s+controller\s+ok\s+host connected")
        self.assertRegex(out, r"R4-01\s+phone\s+ok\s+screen live")
        self.assertRegex(out, r"R4-02\s+phone\s+degraded\s+the app is running but screen sharing is not")
        self.assertRegex(out, r"R5-01\s+tablet\s+missing\s+not found on the network")
        self.assertRegex(out, r"R4-MAC\s+computer\s+n/a\s+no endpoint of its own; driven through R4-CTRL-1")
        self.assertIn("Needs attention: R4-02, R5-01.", out)
        self.assertIn("rerun with --seconds 15", out)
        self.assertEqual({(c.args[0], c.args[2]) for c in call.call_args_list},
                         {(url("ewp-aaaaaaaaaaaa", "keyboard"), "device_status"), (url("phone-1", "screen"), "get_status")})

    def test_everything_up_exits_zero(self):
        devices = [dict(DEVICES[0]), dict(DEVICES[1])]
        self.write_wall(devices)
        answers = {url("ewp-aaaaaaaaaaaa", "keyboard"): {"hid_connected": False, "selected_host": ""},
                   url("phone-1", "screen"): {"live": True, "frame_age_ms": 400}}
        entries = [seen("ewp-aaaaaaaaaaaa", "keyboard"), seen("phone-1", "screen")]
        code, out, _, _ = self.run_cli("status", entries=entries, answers=answers)
        self.assertEqual(code, 0)
        self.assertIn("2 of 2 wall devices are up.", out)
        self.assertIn("no host selected", out)
        self.assertIn("last frame 0.4 s ago", out)
        self.assertNotIn("Needs attention", out)

    def test_tokens_go_to_the_device_and_never_into_output(self):
        entries = [seen("ewp-aaaaaaaaaaaa", "keyboard"), seen("phone-1", "screen")]
        answers = {url("ewp-aaaaaaaaaaaa", "keyboard"): {}, url("phone-1", "screen"): {"live": True}}
        for flags in ([], ["--json"]):
            code, out, err, call = self.run_cli("status", *flags, entries=entries, answers=answers)
            self.assertEqual({c.args[1] for c in call.call_args_list},
                             {self.token("ewp-aaaaaaaaaaaa"), self.token("phone-1")})
            self.assertNotIn("secret-token", out + err)

    def test_screen_that_stopped_updating_is_degraded(self):
        entries = [seen("phone-1", "screen")]
        code, out, _, _ = self.run_cli("status", entries=entries, answers={url("phone-1", "screen"): {"live": False}})
        self.assertRegex(out, r"R4-01\s+phone\s+degraded\s+screen sharing has no recent frame")

    def test_rejected_token_is_degraded_and_says_so(self):
        entries = [seen("phone-1", "screen")]
        answers = {url("phone-1", "screen"): fleet.Unreachable("token rejected", answered=True)}
        _, out, _, _ = self.run_cli("status", entries=entries, answers=answers)
        self.assertRegex(out, r"R4-01\s+phone\s+degraded\s+found, but its status was not read: token rejected")

    def test_missing_token_file_is_reported_and_nothing_is_queried(self):
        (self.dir / "phone-1.token").unlink()
        _, out, _, call = self.run_cli("status", entries=[seen("phone-1", "screen")])
        self.assertRegex(out, r"R4-01\s+phone\s+degraded\s+found, but its status was not read: token file .* cannot be read")
        call.assert_not_called()

    @unittest.skipIf(os.name == "nt", "Windows does not enforce POSIX file modes")
    def test_group_readable_token_file_is_refused(self):
        (self.dir / "phone-1.token").chmod(0o640)
        _, out, _, call = self.run_cli("status", entries=[seen("phone-1", "screen")])
        self.assertIn("must be private (chmod 600)", out)
        call.assert_not_called()

    def test_address_hint_covers_a_network_without_mdns(self):
        devices = copy.deepcopy(DEVICES[:2])
        devices[1]["address_hint"] = "phone-one.local"
        self.write_wall(devices)
        hinted = "http://phone-one.local:7802/mcp"
        controller = [seen("ewp-aaaaaaaaaaaa", "keyboard")]
        answers = {url("ewp-aaaaaaaaaaaa", "keyboard"): {}, hinted: {"live": True}}
        _, out, _, call = self.run_cli("status", entries=controller, answers=answers)
        self.assertRegex(out, r"R4-01\s+phone\s+ok\s+screen live")
        self.assertIn(hinted, {c.args[0] for c in call.call_args_list})
        answers[hinted] = fleet.Unreachable("timed out")
        _, out, _, _ = self.run_cli("status", entries=controller, answers=answers)
        self.assertRegex(out, r"R4-01\s+phone\s+missing\s+no answer at http://phone-one.local:7802/mcp: timed out")

    def test_two_endpoints_with_one_id_are_not_merged(self):
        entries = [seen("phone-1", "screen", "a"), seen("phone-1", "screen", "b")]
        code, out, _, call = self.run_cli("status", entries=entries)
        self.assertRegex(out, r"R4-01\s+phone\s+degraded\s+several endpoints advertise this id")
        call.assert_not_called()

    def test_devices_outside_the_inventory_are_listed_but_do_not_fail_the_wall(self):
        devices = [dict(DEVICES[0])]
        self.write_wall(devices)
        entries = [seen("ewp-aaaaaaaaaaaa", "keyboard"), seen("stranger", "screen")]
        code, out, _, _ = self.run_cli("status", entries=entries, answers={url("ewp-aaaaaaaaaaaa", "keyboard"): {}})
        self.assertEqual(code, 0)
        self.assertIn("On the network but not in wall.json:", out)
        self.assertIn("stranger  live screen  http://stranger.local:7802/mcp", out)

    def test_an_empty_network_explains_what_to_check(self):
        code, out, _, _ = self.run_cli("status")
        self.assertEqual(code, 1)
        self.assertIn("No wall device answered.", out)
        self.assertIn("multicast DNS", out)
        self.assertIn("address_hint", out)

    def test_fields_the_firmware_will_report_are_shown_when_present(self):
        devices = [dict(DEVICES[0])]
        self.write_wall(devices)
        reply = {"hid_connected": True, "uptime_s": 7500, "reset_reason": "brownout", "wifi": {"rssi": -61}}
        _, out, _, _ = self.run_cli("status", entries=[seen("ewp-aaaaaaaaaaaa", "keyboard")],
                                    answers={url("ewp-aaaaaaaaaaaa", "keyboard"): reply})
        self.assertIn("host connected, up 2h 5m, reset: brownout, rssi -61", out)

    def test_json_is_the_machine_form(self):
        entries = [seen("ewp-aaaaaaaaaaaa", "keyboard"), seen("stranger", "app")]
        answers = {url("ewp-aaaaaaaaaaaa", "keyboard"): {"hid_connected": True}}
        code, out, _, _ = self.run_cli("status", "--json", entries=entries, answers=answers)
        data = json.loads(out)
        self.assertEqual((code, data["up"], data["expected"]), (1, 1, 4))
        by_name = {item["name"]: item for item in data["devices"]}
        self.assertEqual(by_name["R4-CTRL-1"]["state"], "ok")
        self.assertEqual(by_name["R4-CTRL-1"]["status"], {"hid_connected": True})
        self.assertEqual(by_name["R5-01"]["state"], "missing")
        self.assertEqual(data["unlisted"][0]["device_id"], "stranger")


class CallToolTests(unittest.TestCase):
    def reply(self, **result):
        return io.BytesIO(json.dumps({"jsonrpc": "2.0", "id": 1, "result": result}).encode())

    def test_sends_one_authenticated_tool_call(self):
        text = json.dumps({"live": True})
        with patch("ewp_tools.fleet.OPENER") as opener:
            opener.open.return_value = self.reply(content=[{"type": "text", "text": text}], isError=False)
            self.assertEqual(fleet.call_tool("http://d.local:7802/mcp", "hunter2", "get_status"), {"live": True})
        request = opener.open.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer hunter2")
        self.assertEqual(request.get_header("Content-type"), "application/json")
        body = json.loads(request.data)
        self.assertEqual((body["method"], body["params"]["name"]), ("tools/call", "get_status"))
        self.assertNotIn("hunter2", request.full_url + request.data.decode())

    def test_failures_become_reasons_that_never_hold_the_token(self):
        cases = [(HTTPError("http://d.local/mcp", 401, "Unauthorized", {}, None), True, "token rejected"),
                 (HTTPError("http://d.local/mcp", 500, "Oops", {}, None), True, "HTTP 500"),
                 (URLError("timed out"), False, "timed out"),
                 (TimeoutError("timed out"), False, "timed out")]
        for failure, answered, reason in cases:
            with self.subTest(reason), patch("ewp_tools.fleet.OPENER") as opener:
                opener.open.side_effect = failure
                with self.assertRaises(fleet.Unreachable) as caught:
                    fleet.call_tool("http://d.local/mcp", "hunter2", "get_status")
                self.assertEqual((caught.exception.answered, str(caught.exception)), (answered, reason))

    def test_a_tool_error_or_garbled_reply_is_not_a_status(self):
        for body in (self.reply(content=[{"type": "text", "text": "{}"}], isError=True),
                     self.reply(content=[{"type": "text", "text": "not json"}], isError=False),
                     io.BytesIO(b'{"jsonrpc": "2.0", "id": 1, "error": {"code": -32602}}')):
            with patch("ewp_tools.fleet.OPENER") as opener:
                opener.open.return_value = body
                with self.assertRaisesRegex(fleet.Unreachable, "unexpected reply"):
                    fleet.call_tool("http://d.local/mcp", "t", "get_status")


class ComposeTests(WallCase):
    ENTRIES = [seen("ewp-aaaaaaaaaaaa", "keyboard"), seen("phone-1", "screen"), seen("phone-2", "screen"),
               seen("tablet-1", "screen")]

    def compose(self, *flags, entries=None, name="session.json"):
        self.out = self.dir / name
        return self.run_cli("compose", "--out", str(self.out), *flags,
                            entries=self.ENTRIES if entries is None else entries)

    def servers(self):
        return json.loads(self.out.read_text())["mcpServers"]

    def test_a_row_becomes_one_server_per_device_named_after_it(self):
        code, out, err, _ = self.compose("--group", "row4")
        self.assertEqual((code, err), (0, ""))
        servers = self.servers()
        self.assertEqual(list(servers), ["R4-CTRL-1", "R4-01", "R4-02"])
        self.assertEqual(servers["R4-01"], {
            "type": "http", "url": "http://phone-1.local:7802/mcp",
            "headers": {"Authorization": "Bearer " + self.token("phone-1")}})
        self.assertEqual(servers["R4-CTRL-1"]["url"], "http://ewp-aaaaaaaaaaaa.local:80/mcp")
        self.assertIn("Wrote 3 MCP servers to", out)
        self.assertIn("No endpoint of their own, reached through their controller: R4-MAC.", out)
        self.assertIn("mcp__R4-CTRL-1__help", out)

    @unittest.skipIf(os.name == "nt", "Windows does not enforce POSIX file modes")
    def test_the_config_is_private_and_the_output_says_it_holds_tokens(self):
        self.out = self.dir / "session.json"
        self.out.write_text("old")
        self.out.chmod(0o644)
        code, out, err, _ = self.compose("--group", "row4", "--force")
        self.assertEqual(self.out.stat().st_mode & 0o777, 0o600)
        self.assertIn("contains access tokens and is readable only by you (mode 600)", out)
        self.assertNotIn("secret-token", out + err)

    def test_choosing_a_phone_brings_the_controller_that_types_on_it(self):
        code, out, _, _ = self.compose("--device", "R4-01")
        self.assertEqual(list(self.servers()), ["R4-CTRL-1", "R4-01"])
        self.assertIn("Added the controllers that type on your devices: R4-CTRL-1.", out)

    def test_choosing_a_controller_brings_every_device_it_serves(self):
        self.compose("--controller", "R4-CTRL-1")
        self.assertEqual(list(self.servers()), ["R4-CTRL-1", "R4-01", "R4-02"])

    def test_groups_by_tag_and_by_column_combine(self):
        self.compose("--group", "ios18", "--group", "col1")
        self.assertEqual(list(self.servers()), ["R4-CTRL-1", "R4-01", "R5-01"])

    def test_all_is_explicit(self):
        code, _, err, _ = self.compose()
        self.assertEqual(code, 2)
        self.assertIn("pass --all", err)
        self.assertFalse(self.out.exists())
        self.compose("--all")
        self.assertEqual(len(self.servers()), 4)

    def test_unknown_selectors_are_errors_not_empty_configs(self):
        for flags in (("--group", "row9"), ("--device", "nobody"), ("--controller", "R4-01")):
            with self.subTest(flags):
                code, _, err, _ = self.compose(*flags)
                self.assertEqual(code, 2)
                self.assertFalse(self.out.exists())

    def test_devices_that_cannot_be_found_stop_the_run_unless_skipped(self):
        entries = [seen("ewp-aaaaaaaaaaaa", "keyboard"), seen("phone-1", "screen")]
        code, _, err, _ = self.compose("--group", "row4", entries=entries)
        self.assertEqual(code, 1)
        self.assertIn("Not found on the network, and no address_hint: R4-02.", err)
        self.assertFalse(self.out.exists())
        code, out, _, _ = self.compose("--group", "row4", "--skip-missing", entries=entries)
        self.assertEqual(code, 0)
        self.assertEqual(list(self.servers()), ["R4-CTRL-1", "R4-01"])
        self.assertIn("Left out, not found on the network: R4-02.", out)

    def test_live_hostname_wins_and_address_hint_fills_the_gap(self):
        devices = copy.deepcopy(DEVICES[:3])
        devices[1]["address_hint"] = "stale.local"
        devices[2]["address_hint"] = "phone-two.local"
        self.write_wall(devices)
        self.compose("--group", "row4", entries=[seen("ewp-aaaaaaaaaaaa", "keyboard"), seen("phone-1", "screen")])
        servers = self.servers()
        self.assertEqual(servers["R4-01"]["url"], "http://phone-1.local:7802/mcp")
        self.assertEqual(servers["R4-02"]["url"], "http://phone-two.local:7802/mcp")

    def test_a_broken_token_file_writes_nothing(self):
        (self.dir / "phone-2.token").unlink()
        code, _, err, _ = self.compose("--group", "row4")
        self.assertEqual(code, 2)
        self.assertIn("phone-2.token cannot be read", err)
        self.assertFalse(self.out.exists())

    @unittest.skipIf(os.name == "nt", "Windows does not enforce POSIX file modes")
    def test_a_world_readable_token_file_is_refused(self):
        (self.dir / "phone-2.token").chmod(0o644)
        code, _, err, _ = self.compose("--group", "row4")
        self.assertEqual(code, 2)
        self.assertIn("must be private (chmod 600)", err)
        self.assertNotIn("secret-token", err)
        self.assertFalse(self.out.exists())

    def test_an_existing_config_is_replaced_only_on_request(self):
        self.out = self.dir / "session.json"
        self.out.write_text("keep me")
        code, _, err, _ = self.compose("--group", "row4")
        self.assertEqual(code, 2)
        self.assertEqual(self.out.read_text(), "keep me")
        code, _, _, _ = self.compose("--group", "row4", "--force")
        self.assertEqual(code, 0)
        self.assertIn("R4-01", self.servers())


if __name__ == "__main__":
    unittest.main()


class ServerKeyTests(unittest.TestCase):
    def test_a_human_name_becomes_a_usable_server_key(self):
        from ewp_tools.fleet import server_key
        self.assertEqual(server_key('Row 4 Seat 2'), 'Row-4-Seat-2')
        self.assertEqual(server_key('Bench 1'), 'Bench-1')
        self.assertEqual(server_key('R4/C2 (spare)'), 'R4-C2-spare')
        self.assertEqual(server_key('!!!'), 'ewp')


class ReidentifiedTests(unittest.TestCase):
    """A device that comes back under a new identifier is one device, not two."""

    @staticmethod
    def missing(name, device_id):
        return dict(name=name, id=device_id, role='phone', state='missing',
                    detail='not found on the network', endpoint=None, status=None)

    @staticmethod
    def live(name, device_id):
        return dict(seen(device_id, 'app'), name=name)

    def test_one_missing_and_one_live_of_the_same_name_are_paired(self):
        results = [self.missing('R4-01', 'phone-1')]
        unlisted = [self.live('R4-01', 'phone-1-reinstalled')]
        self.assertEqual(fleet.reidentified(results, unlisted),
                         [(results[0], unlisted[0])])

    def test_the_name_is_matched_regardless_of_case_and_padding(self):
        results = [self.missing('  Bench 1', 'old')]
        unlisted = [self.live('bench 1  ', 'new')]
        self.assertEqual(len(fleet.reidentified(results, unlisted)), 1)

    def test_a_device_that_is_answering_is_never_paired(self):
        present = dict(self.missing('R4-01', 'phone-1'), state='ok')
        self.assertEqual(fleet.reidentified([present], [self.live('R4-01', 'other')]), [])

    def test_two_devices_sharing_a_name_are_left_alone(self):
        results = [self.missing('R4-01', 'phone-1'), self.missing('R4-01', 'phone-2')]
        unlisted = [self.live('R4-01', 'new-1')]
        self.assertEqual(fleet.reidentified(results, unlisted), [])
        results = [self.missing('R4-01', 'phone-1')]
        unlisted = [self.live('R4-01', 'new-1'), self.live('R4-01', 'new-2')]
        self.assertEqual(fleet.reidentified(results, unlisted), [])

    def test_an_unnamed_endpoint_is_not_guessed_at(self):
        results = [self.missing('R4-01', 'phone-1')]
        self.assertEqual(fleet.reidentified(results, [self.live('', 'new')]), [])
        self.assertEqual(fleet.reidentified(results, [seen('new', 'app')]), [])

    def test_the_report_names_both_identifiers_and_does_not_list_it_twice(self):
        results = [self.missing('R4-01', 'phone-1')]
        unlisted = [self.live('R4-01', 'phone-1-new')]
        text = fleet.status_report(results, unlisted, 5)
        self.assertIn('wall.json has phone-1, the network has phone-1-new', text)
        self.assertNotIn('On the network but not in wall.json', text)

    def test_a_wall_with_one_device_up_still_reports_the_pairing_once(self):
        up = dict(self.missing('R4-02', 'phone-2'), state='ok', detail='screen live')
        results = [up, self.missing('R4-01', 'phone-1')]
        unlisted = [self.live('R4-01', 'phone-1-new')]
        text = fleet.status_report(results, unlisted, 5)
        self.assertIn('Same name, new identifier', text)
        self.assertIn('wall.json has phone-1, the network has phone-1-new', text)
        self.assertNotIn('On the network but not in wall.json', text)

    def test_endpoints_answering_rule_out_the_network_advice(self):
        results = [self.missing('R4-01', 'phone-1')]
        text = fleet.status_report(results, [self.live('Spare', 'unknown-1')], 5)
        self.assertIn('Multicast DNS is working', text)
        self.assertNotIn('same Wi-Fi', text)

    def test_nothing_on_the_network_still_blames_the_network(self):
        text = fleet.status_report([self.missing('R4-01', 'phone-1')], [], 5)
        self.assertIn('same Wi-Fi', text)
