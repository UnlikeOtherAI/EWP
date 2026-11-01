"""One-off ESP32 USB setup. No runtime service or proxy is started."""
import argparse
import json
import os
from pathlib import Path
import time

import serial


def private_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    if hasattr(os, "fchmod"):
        os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(value)


def request(port, payload, required, seconds=12):
    port.write((json.dumps(payload) + '\n').encode())
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        line = port.read_until(b'\n', 2048)
        try:
            value = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            continue  # Boot messages can include the PIN; never print them.
        if isinstance(value, dict) and required in value:
            return value
    raise TimeoutError('No matching setup response; reset the board and retry. No credential contents were printed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--expected-id', default='')
    parser.add_argument('--name', help='Name this board so people and agents can tell it apart on a wall')
    parser.add_argument('--wifi-file', help='Private JSON file with ssid and password; never put credentials in command arguments')
    parser.add_argument('--output-dir', default=str(Path.home() / '.config/ewp'))
    args = parser.parse_args()
    port = serial.Serial()
    port.port = args.port; port.baudrate = 115200; port.timeout = 0.2
    port.dtr = False; port.rts = False
    with port:
        # CP2102 can pulse reset lines while opening the port. Explicitly boot
        # the application with GPIO0 released, then allow its UART to start.
        port.dtr = False; port.rts = True
        time.sleep(0.1); port.rts = False
        time.sleep(1.5); port.reset_input_buffer()
        access = request(port, {'method': 'access'}, 'token')
        device = access.get('id', '')
        token = access.get('token', '')
        if not device.startswith('ewp-') or not all(c in '0123456789abcdef' for c in device[4:]):
            raise ValueError('Unexpected device identity')
        if args.expected_id and args.expected_id != device:
            raise ValueError('A different board is connected; nothing was provisioned')
        if len(token) != 64 or any(c not in '0123456789abcdef' for c in token):
            raise ValueError('Invalid device access response')
        output = Path(args.output_dir).expanduser()
        private_write(output / (device + '.token'), token)
        private_write(output / (device + '.pin'), str(access['pairing_code']).zfill(6))
        if args.name:
            named = request(port, {'method': 'set_name', 'name': args.name}, 'name')
            print('Name:', named['name'])
        if args.wifi_file:
            source = Path(args.wifi_file).expanduser()
            if os.name != 'nt' and source.stat().st_mode & 0o077:
                raise ValueError('Wi-Fi file must be private (chmod 600)')
            wifi = json.loads(source.read_text())
            if not isinstance(wifi.get('ssid'), str) or not isinstance(wifi.get('password'), str):
                raise ValueError('Wi-Fi file needs ssid and password strings')
            result = request(port, dict(wifi, method='setup_wifi'), 'submitted')
            if result.get('submitted') is not True:
                raise ValueError('Board rejected Wi-Fi setup')
            print('Wi-Fi configuration submitted to the ESP32.')
        print('Device:', device)
        if not args.name and not access.get('name'):
            print('No name set. Pass --name to label this board.')
        print('MCP credential saved privately:', output / (device + '.token'))
        print('Pairing PIN saved privately:', output / (device + '.pin'))


if __name__ == '__main__':
    main()
