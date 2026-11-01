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
                     name=props.get('name', ''), firmware=props.get('fw', ''),
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


ROLES = {'app': 'iPhone or iPad', 'screen': 'live screen', 'keyboard': 'keyboard'}


def report(entries):
    """Readable by default; --json stays the machine-facing form."""
    if not entries:
        return ("No EWP endpoints answered.\n\n"
                "Check that this computer is on the same Wi-Fi as the devices, that the\n"
                "EWP app is open on at least one of them, and that the network does not\n"
                "block multicast DNS.")
    def label(entry):
        # A named device is called by its name; otherwise fall back to the
        # instance name with the service type stripped off.
        return entry.get('name') or entry['service'].split('._mcp._tcp.')[0]

    width = max(len(label(entry)) for entry in entries)
    lines = [f"Found {len(entries)} EWP endpoint{'s' if len(entries) > 1 else ''}.", '']
    for entry in sorted(entries, key=lambda item: (item['role'], item['service'])):
        lines.append(f"  {label(entry):<{width}}  {ROLES.get(entry['role'], entry['role'])}")
        lines.append(f"  {'':<{width}}  {entry['endpoint']}")
        lines.append('')
    lines.append('Each endpoint has its own access token and expects it as')
    lines.append('Authorization: Bearer <token>. Call the `help` tool on one to')
    lines.append('learn what it does before using anything else.')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=5, choices=range(1, 31))
    parser.add_argument('--json', action='store_true', help='Machine-readable output')
    args = parser.parse_args()
    entries = discover(args.seconds)
    print(json.dumps(entries, indent=2) if args.json else report(entries))


if __name__ == '__main__':
    main()
