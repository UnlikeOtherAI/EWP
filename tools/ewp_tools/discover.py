"""Find device-hosted MCP endpoints. This command never forwards MCP traffic."""
import argparse
import json
import threading
from zeroconf import ServiceBrowser, Zeroconf


class Devices:
    def __init__(self):
        self.entries = {}
        self.lock = threading.Lock()

    def add_service(self, zc, kind, name):
        self.update_service(zc, kind, name)

    def remove_service(self, zc, kind, name):
        with self.lock:
            self.entries.pop(name, None)

    def update_service(self, zc, kind, name):
        info = zc.get_service_info(kind, name, timeout=1500)
        if not info:
            return
        props = {k.decode('utf8', 'replace'): v.decode('utf8', 'replace') for k, v in info.properties.items() if v is not None}
        addresses = info.parsed_scoped_addresses()
        host = info.server.rstrip('.')
        value = dict(service=name, device_id=props.get('id', ''), role=props.get('role', ''),
                     endpoint=f"http://{host}:{info.port}{props.get('path', '/mcp')}", addresses=addresses)
        with self.lock:
            self.entries[name] = value


def discover(seconds=5):
    devices = Devices()
    with Zeroconf() as zc:
        browser = ServiceBrowser(zc, '_mcp._tcp.local.', devices)
        try:
            threading.Event().wait(seconds)
            with devices.lock:
                return list(devices.entries.values())
        finally:
            browser.cancel()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=5, choices=range(1, 31))
    args = parser.parse_args()
    print(json.dumps(discover(args.seconds), indent=2))


if __name__ == '__main__':
    main()
