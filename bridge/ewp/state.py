"""Bounded, in-memory frame storage. A session is live only with a fresh frame."""
import io
import threading
import time
import uuid
from dataclasses import dataclass

from PIL import Image

MAX_FRAME = 512 * 1024
FRESH_SECONDS = 5


@dataclass
class Session:
    id: str
    device_id: str
    created: float
    frame: bytes | None = None
    received: float = 0
    width: int = 0
    height: int = 0
    orientation: int = 1


class State:
    def __init__(self):
        self.lock = threading.RLock()
        self.sessions: dict[str, Session] = {}

    def create(self, device_id: str) -> str:
        if not isinstance(device_id, str) or not 1 <= len(device_id) <= 100:
            raise ValueError("Invalid device id")
        with self.lock:
            # A restarted broadcast replaces the old one for this installation.
            self.sessions = {k: s for k, s in self.sessions.items() if s.device_id != device_id}
            if len(self.sessions) >= 32:
                oldest = min(self.sessions, key=lambda k: self.sessions[k].created)
                del self.sessions[oldest]
            key = str(uuid.uuid4())
            self.sessions[key] = Session(key, device_id, time.monotonic())
            return key

    def put(self, key: str, data: bytes, orientation: int):
        if not 0 < len(data) <= MAX_FRAME or orientation not in range(1, 9):
            raise ValueError("Invalid frame size or orientation")
        try:
            with Image.open(io.BytesIO(data)) as image:
                if image.format != "JPEG" or max(image.size) > 2048:
                    raise ValueError("Expected JPEG, at most 2048 pixels per side")
                # JPEG verify() checks the container but can accept truncated pixel data.
                # Decode before advancing freshness or reporting a live screen.
                image.load()
                width, height = image.size
        except Image.DecompressionBombError as error:
            raise ValueError("Image dimensions exceed the frame limit") from error
        with self.lock:
            session = self.sessions[key]
            session.frame = data
            session.width, session.height = width, height
            session.orientation = orientation
            session.received = time.monotonic()

    def remove(self, key: str):
        with self.lock:
            self.sessions.pop(key, None)

    def listing(self):
        now = time.monotonic()
        with self.lock:
            return [dict(id=s.id, device_id=s.device_id,
                         live=bool(s.frame and now - s.received <= FRESH_SECONDS),
                         age_seconds=round(now - s.received, 2) if s.frame else None,
                         width=s.width, height=s.height, orientation=s.orientation)
                    for s in self.sessions.values()]

    def screen(self, key: str) -> bytes:
        with self.lock:
            s = self.sessions[key]
            if not s.frame or time.monotonic() - s.received > FRESH_SECONDS:
                raise ValueError("No fresh frame. Start or resume screen sharing on the device.")
            # ReplayKit delivers sensor orientation separately from the pixel buffer.
            with Image.open(io.BytesIO(s.frame)) as image:
                operations = {2: Image.Transpose.FLIP_LEFT_RIGHT, 3: Image.Transpose.ROTATE_180,
                              4: Image.Transpose.FLIP_TOP_BOTTOM, 5: Image.Transpose.TRANSPOSE,
                              6: Image.Transpose.ROTATE_270, 7: Image.Transpose.TRANSVERSE,
                              8: Image.Transpose.ROTATE_90}
                if s.orientation in operations:
                    image = image.transpose(operations[s.orientation])
                output = io.BytesIO()
                image.save(output, format="JPEG", quality=80)
                return output.getvalue()
