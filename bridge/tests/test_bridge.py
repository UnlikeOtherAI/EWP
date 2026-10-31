import io
import json
import threading
import time
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from unittest.mock import patch

from PIL import Image

from ewp.server import handler_type
from ewp.state import State, MAX_FRAME


def jpeg(width=24, height=16):
    output = io.BytesIO()
    Image.new("RGB", (width, height), "blue").save(output, "JPEG")
    return output.getvalue()


class StateTests(unittest.TestCase):
    def test_capture_requires_fresh_actual_frame(self):
        state = State()
        key = state.create("ipad")
        self.assertFalse(state.listing()[0]["live"])
        with self.assertRaises(ValueError):
            state.screen(key)
        state.put(key, jpeg(), 6)
        self.assertTrue(state.listing()[0]["live"])
        with Image.open(io.BytesIO(state.screen(key))) as image:
            self.assertEqual(image.size, (16, 24))
        with patch("ewp.state.time.monotonic", return_value=time.monotonic() + 6):
            self.assertFalse(state.listing()[0]["live"])
            with self.assertRaises(ValueError):
                state.screen(key)

    def test_restart_invalidates_old_session_and_stop_clears(self):
        state = State()
        old = state.create("ipad")
        state.put(old, jpeg(), 1)
        new = state.create("ipad")
        with self.assertRaises(KeyError):
            state.put(old, jpeg(), 1)
        self.assertEqual(len(state.listing()), 1)
        state.remove(new)
        self.assertEqual(state.listing(), [])

    def test_rejects_invalid_images_and_bounds_sessions(self):
        state = State()
        key = state.create("ipad")
        for data, orientation in [(b"invalid", 1), (jpeg(2049, 1), 1), (jpeg(), 9), (b"x" * (MAX_FRAME + 1), 1)]:
            with self.assertRaises((ValueError, OSError)):
                state.put(key, data, orientation)
        for i in range(40):
            state.create(str(i))
        self.assertEqual(len(state.listing()), 32)

    def test_rejects_forged_oversized_jpeg_header(self):
        state = State()
        key = state.create("ipad")
        data = bytearray(jpeg())
        start = data.index(b"\xff\xc0")
        data[start + 5:start + 9] = (50000).to_bytes(2, "big") * 2
        with self.assertRaises(ValueError):
            state.put(key, bytes(data), 1)

    def test_truncated_pixel_data_does_not_make_capture_live(self):
        state = State()
        key = state.create("ipad")
        truncated = jpeg()[:-12]
        # The JPEG header is readable, but its pixel scan is incomplete.
        with Image.open(io.BytesIO(truncated)) as image:
            self.assertEqual(image.size, (24, 16))
        with self.assertRaises(OSError):
            state.put(key, truncated, 1)
        self.assertFalse(state.listing()[0]["live"])


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.state = State()
        devices = type("Devices", (), {"listing": lambda self: []})()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler_type(self.state, "test-token", devices))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, method, path, body=None, headers=None):
        connection = HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        connection.request(method, path, body, headers or {})
        response = connection.getresponse()
        data = json.loads(response.read())
        connection.close()
        return response.status, data

    def test_authentication_browser_origin_and_frame_lifecycle(self):
        auth = {"Authorization": "Bearer test-token"}
        self.assertEqual(self.request("GET", "/status")[0], 401)
        self.assertEqual(self.request("GET", "/status", headers={"Authorization": "Bearer \xe9"})[0], 401)
        self.assertEqual(self.request("GET", "/status", headers={**auth, "Origin": "https://example.com"})[0], 403)
        status, data = self.request("POST", "/sessions", json.dumps({"device_id": "ipad"}), auth)
        self.assertEqual(status, 201)
        key = data["session_id"]
        path = f"/sessions/{key}/frames"
        self.assertEqual(self.request("POST", path, jpeg(), {**auth, "Content-Type": "image/jpeg"})[0], 200)
        self.assertTrue(self.request("GET", "/status", headers=auth)[1]["sessions"][0]["live"])
        self.assertEqual(self.request("POST", path, b"bad", {**auth, "Content-Type": "image/jpeg"})[0], 400)
        self.assertEqual(self.request("DELETE", f"/sessions/{key}", headers=auth)[0], 200)
        self.assertEqual(self.request("POST", path, jpeg(), {**auth, "Content-Type": "image/jpeg"})[0], 404)

    def test_invalid_body_is_rejected(self):
        auth = {"Authorization": "Bearer test-token"}
        self.assertEqual(self.request("POST", "/sessions", b"[]", auth)[0], 400)
        self.assertEqual(self.request("POST", "/sessions", b"{", auth)[0], 400)
        self.assertEqual(self.request("POST", "/sessions", b"", auth)[0], 413)


if __name__ == "__main__":
    unittest.main()
