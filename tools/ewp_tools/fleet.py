"""Check the wall and write per-session MCP client configs. Setup-time only:
it reads mDNS and files, then exits. It never forwards MCP traffic."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
import json
import os
from pathlib import Path
import re
import shlex
import sys
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

from ewp_tools.discover import ROLES as KINDS, discover
from ewp_tools.setup import private_write

CONFIG_DIR = Path.home() / '.config/ewp'
DEVICE_ROLES = ('phone', 'tablet', 'computer', 'controller')
# The endpoint a wall device is judged by. A computer driven by a controller runs no EWP endpoint.
ENDPOINT = {'phone': 'screen', 'tablet': 'screen', 'controller': 'keyboard'}
PORTS = {'keyboard': 80, 'screen': 7802}
STATUS_TOOL = {'keyboard': 'device_status', 'screen': 'get_status'}
FIELDS = {'id', 'name', 'role', 'row', 'col', 'group', 'controller', 'token_file', 'address_hint'}
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]{0,31}')  # Becomes the MCP server key, so it prefixes every tool name.
TAG = re.compile(r'[A-Za-z0-9_-]+')
ID = re.compile(r'[A-Za-z0-9._-]{1,64}')
HOST = re.compile(r'[A-Za-z0-9.-]+')
OPENER = build_opener(ProxyHandler({}))  # Devices are on the LAN; never go through a system proxy.


class WallError(Exception):
    """Something the operator can fix: the inventory, a selector or a token file."""


class Unreachable(Exception):
    def __init__(self, reason, answered=False):
        super().__init__(reason)
        self.answered = answered  # True when the device replied, e.g. rejected the token.


@dataclass(frozen=True)
class Device:
    id: str
    name: str
    role: str
    token_file: Path
    row: int | None = None
    col: int | None = None
    groups: tuple = ()
    controller: str = ''  # The id of the controller that serves this device, once loaded.
    address_hint: str = ''


def parse_device(entry):
    name = entry.get('name') if isinstance(entry, dict) else None
    where = name if isinstance(name, str) else 'a device without a valid name'

    def bad(problem):
        raise WallError(f'{where}: {problem}')

    if not isinstance(entry, dict):
        raise WallError('every device must be an object')
    if 'token' in entry:
        bad('tokens never go in wall.json; point token_file at the private token file')
    unknown = sorted(set(entry) - FIELDS)
    if unknown:
        bad('unknown field ' + ', '.join(unknown))
    if not isinstance(name, str) or not NAME.fullmatch(name):
        bad('name must be 1-32 letters, digits, - or _; it becomes the tool prefix')
    device_id = entry.get('id')
    if not isinstance(device_id, str) or not ID.fullmatch(device_id):
        bad('id must be the device id from its mDNS record or ewp-setup output')
    if entry.get('role') not in DEVICE_ROLES:
        bad('role must be one of ' + ', '.join(DEVICE_ROLES))
    for key in ('row', 'col'):
        if key in entry and (not isinstance(entry[key], int) or isinstance(entry[key], bool)):
            bad(f'{key} must be a whole number')
    groups = entry.get('group', [])
    if not isinstance(groups, list) or not all(isinstance(tag, str) and TAG.fullmatch(tag) for tag in groups):
        bad('group must be a list of tags made of letters, digits, - or _')
    for key in ('controller', 'token_file', 'address_hint'):
        if key in entry and not isinstance(entry[key], str):
            bad(f'{key} must be a string')
    hint = entry.get('address_hint', '')
    if hint and not HOST.fullmatch(hint):
        bad('address_hint is a bare hostname like ewp-240ac4a1b2c3.local, without scheme, port or path')
    token_file = Path(entry.get('token_file') or CONFIG_DIR / f'{device_id}.token').expanduser()
    return Device(device_id, name, entry['role'], token_file, entry.get('row'), entry.get('col'),
                  tuple(groups), entry.get('controller', ''), hint)


def find(wall, ref):
    """A device by id or name, case-insensitively; ids win."""
    for field in ('id', 'name'):
        for device in wall:
            if getattr(device, field).lower() == ref.lower():
                return device
    return None


def load_wall(path):
    path = Path(path).expanduser()
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        raise WallError(f'No inventory at {path}. Create it (see the README) or pass --wall.') from None
    except (OSError, ValueError) as error:
        raise WallError(f'Cannot read {path}: {error}') from None
    entries = data.get('devices') if isinstance(data, dict) else None
    if not isinstance(entries, list) or not entries:
        raise WallError(f'{path} needs a "devices" list with at least one device.')
    try:
        wall = [parse_device(entry) for entry in entries]
        for field in ('id', 'name'):
            seen = set()
            for device in wall:
                value = getattr(device, field).lower()
                if value in seen:
                    raise WallError(f'{getattr(device, field)}: {field} appears more than once')
                seen.add(value)
        for index, device in enumerate(wall):
            if not device.controller:
                continue
            if device.role == 'controller':
                raise WallError(f'{device.name}: a controller is not served by another controller')
            target = find(wall, device.controller)
            if not target or target.role != 'controller':
                raise WallError(f'{device.name}: controller {device.controller!r} is not a device with role "controller"')
            wall[index] = replace(device, controller=target.id)
    except WallError as error:
        raise WallError(f'{path}: {error}') from None
    return wall


def position(device):
    # Row by row, each row led by its controller.
    return (device.row is None, device.row or 0, device.role != 'controller', device.col is None, device.col or 0, device.name)


def read_token(path):
    try:
        mode = path.stat().st_mode
        token = path.read_text().strip()
    except (OSError, ValueError):
        raise WallError(f'token file {path} cannot be read') from None
    if os.name != 'nt' and mode & 0o077:
        raise WallError(f'token file {path} must be private (chmod 600)')
    if len(token.split()) != 1:
        raise WallError(f'token file {path} should hold one token and nothing else')
    return token


def call_tool(url, token, tool, timeout=5):
    """One stateless tools/call; the devices need no session. Returns the tool's JSON result."""
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                       'params': {'name': tool, 'arguments': {}}}).encode()
    request = Request(url, body, {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
    try:
        with OPENER.open(request, timeout=timeout) as response:
            reply = json.load(response)
    except HTTPError as error:
        error.close()
        raise Unreachable('token rejected' if error.code in (401, 403) else f'HTTP {error.code}', answered=True) from None
    except (OSError, ValueError) as error:
        raise Unreachable(str(getattr(error, 'reason', error))) from None
    try:
        result = reply['result']
        status = json.loads(result['content'][0]['text'])
        if result.get('isError') or not isinstance(status, dict):
            raise ValueError
    except (KeyError, IndexError, TypeError, ValueError):
        raise Unreachable('unexpected reply', answered=True) from None
    return status


def index(entries):
    live = {}
    for entry in entries:
        live.setdefault((entry['device_id'].lower(), entry['role']), []).append(entry)
    return live


def resolve(device, role, live):
    """(url, source) for one endpoint: what mDNS sees now, else the operator's address_hint."""
    found = live.get((device.id.lower(), role), [])
    if len(found) == 1:
        return found[0]['endpoint'], 'mdns'
    if device.address_hint:
        return f'http://{device.address_hint}:{PORTS[role]}/mcp', 'hint'
    return None, 'duplicate' if found else 'missing'


def duration(seconds):
    days, minutes = divmod(int(seconds) // 60, 1440)
    hours, minutes = divmod(minutes, 60)
    return ' '.join(([f'{days}d'] if days else []) + ([f'{hours}h'] if days or hours else []) + [f'{minutes}m'])


def describe(role, status):
    if role == 'keyboard':
        parts = ['host connected' if status.get('hid_connected') else
                 'waiting for its host' if status.get('selected_host') else 'no host selected']
    else:
        parts = ['screen live']
        if isinstance(status.get('frame_age_ms'), (int, float)):
            parts.append(f"last frame {status['frame_age_ms'] / 1000:.1f} s ago")
    # Reported once the firmware does (docs/architecture-review.md, P4); absent fields are skipped.
    if isinstance(status.get('uptime_s'), (int, float)):
        parts.append('up ' + duration(status['uptime_s']))
    if status.get('reset_reason'):
        parts.append('reset: ' + str(status['reset_reason']))
    wifi = status['wifi'] if isinstance(status.get('wifi'), dict) else {}
    rssi = wifi.get('rssi', status.get('rssi'))
    if isinstance(rssi, (int, float)):
        parts.append(f'rssi {rssi:g}')
    return ', '.join(parts)


def check(device, wall, live, query):
    """One device's state (ok, degraded, missing or n/a) and the reason, in plain words."""
    result = dict(name=device.name, id=device.id, role=device.role, endpoint=None, status=None)

    def finish(state, detail):
        return dict(result, state=state, detail=detail)

    role = ENDPOINT.get(device.role)
    if role is None:
        via = f'; driven through {find(wall, device.controller).name}' if device.controller else ''
        return finish('n/a', 'no endpoint of its own' + via)
    url, source = resolve(device, role, live)
    if url is None:
        if source == 'duplicate':
            return finish('degraded', 'several endpoints advertise this id; each device needs its own')
        if role == 'screen' and (device.id.lower(), 'app') in live:
            return finish('degraded', 'the app is running but screen sharing is not; resume it on the device')
        return finish('missing', 'not found on the network')
    result['endpoint'] = url
    try:
        status = query(url, read_token(device.token_file), STATUS_TOOL[role])
    except WallError as error:
        return finish('degraded', f'found, but its status was not read: {error}')
    except Unreachable as error:
        if source == 'hint' and not error.answered:
            return finish('missing', f'no answer at {url}: {error}')
        return finish('degraded', f'found, but its status was not read: {error}')
    result['status'] = status
    if role == 'screen' and status.get('live') is not True:
        return finish('degraded', 'screen sharing has no recent frame; resume it on the device')
    return finish('ok', describe(role, status))


def status_report(results, unlisted, seconds):
    """Readable by default; --json stays the machine-facing form."""
    wall = [item for item in results if item['state'] != 'n/a']
    up = sum(item['state'] == 'ok' for item in wall)
    if wall and all(item['state'] == 'missing' for item in wall):
        return ("No wall device answered.\n\n"
                "Check that this computer is on the same Wi-Fi as the devices, that the\n"
                "EWP app is open on the phones, and that the network does not block\n"
                "multicast DNS. Without mDNS, set address_hint on each device in wall.json.")
    width = max(len(item['name']) for item in results)
    kind = max(len(item['role']) for item in results)
    state = max(len(item['state']) for item in results)
    lines = [f"{up} of {len(wall)} wall devices are up.", '']
    for item in results:
        lines.append(f"  {item['name']:<{width}}  {item['role']:<{kind}}  {item['state']:<{state}}  {item['detail']}")
    problems = [item['name'] for item in wall if item['state'] != 'ok']
    if problems:
        lines += ['', 'Needs attention: ' + ', '.join(problems) + '.']
    if any(item['state'] == 'missing' for item in wall):
        lines.append(f'A missing device may only be slow to answer; rerun with --seconds {min(30, seconds * 3)} before walking the wall.')
    if unlisted:
        lines += ['', 'On the network but not in wall.json:']
        for entry in sorted(unlisted, key=lambda item: (item['role'], item['service'])):
            lines.append(f"  {entry['device_id'] or entry['service']}  {KINDS.get(entry['role'], entry['role'])}  {entry['endpoint']}")
    return '\n'.join(lines)


def run_status(args):
    wall = load_wall(args.wall)
    entries = discover(args.seconds)
    live = index(entries)
    with ThreadPoolExecutor(32) as pool:
        results = list(pool.map(lambda device: check(device, wall, live, call_tool), sorted(wall, key=position)))
    known = {device.id.lower() for device in wall}
    unlisted = [entry for entry in entries if entry['device_id'].lower() not in known]
    if args.json:
        up = sum(item['state'] == 'ok' for item in results)
        print(json.dumps(dict(up=up, expected=sum(item['state'] != 'n/a' for item in results),
                              devices=results, unlisted=unlisted), indent=2))
    else:
        print(status_report(results, unlisted, args.seconds))
    return 0 if all(item['state'] in ('ok', 'n/a') for item in results) else 1


def tags(device):
    found = set(device.groups)
    for key in ('row', 'col'):
        if getattr(device, key) is not None:
            found.add(f'{key}{getattr(device, key)}')
    return found


def select(wall, args):
    """The devices a session needs. Anything chosen brings the controller that types on it."""
    chosen = {device.id: device for device in wall} if args.all else {}
    for tag in args.group:
        members = [device for device in wall if tag in tags(device)]
        if not members:
            raise WallError(f'no device is in group {tag!r}')
        chosen.update((device.id, device) for device in members)
    for ref in args.device:
        device = find(wall, ref)
        if not device:
            raise WallError(f'{ref!r} is not in the inventory')
        chosen[device.id] = device
    for ref in args.controller:
        controller = find(wall, ref)
        if not controller or controller.role != 'controller':
            raise WallError(f'{ref!r} is not a controller in the inventory')
        chosen[controller.id] = controller
        chosen.update((device.id, device) for device in wall if device.controller == controller.id)
    if not chosen:
        raise WallError('choose devices with --group, --device or --controller, or pass --all')
    return chosen


def run_compose(args):
    wall = load_wall(args.wall)
    chosen = select(wall, args)
    added = {}
    for device in list(chosen.values()):
        if device.controller and device.controller not in chosen:
            added[device.controller] = find(wall, device.controller)
    chosen.update(added)
    out = Path(args.out).expanduser()
    if out.exists() and not args.force:
        raise WallError(f'{out} already exists; pass --force to replace it')
    live = index(discover(args.seconds))

    servers, left_out, without_endpoint = {}, [], []
    for device in sorted(chosen.values(), key=position):
        role = ENDPOINT.get(device.role)
        if role is None:
            without_endpoint.append(device.name)
            continue
        url, _ = resolve(device, role, live)
        if url is None:
            left_out.append(device.name)
        else:
            servers[device.name] = (device, url)
    if left_out and not args.skip_missing:
        print('Not found on the network, and no address_hint: ' + ', '.join(left_out) + '.\n'
              'Nothing was written. Fix those devices, or pass --skip-missing to compose without them.', file=sys.stderr)
        return 1
    if not servers:
        raise WallError('none of the chosen devices has an endpoint to compose')

    config, problems = {}, []
    for name, (device, url) in servers.items():
        try:
            token = read_token(device.token_file)
        except WallError as error:
            problems.append(str(error))
            continue
        config[name] = {'type': 'http', 'url': url, 'headers': {'Authorization': 'Bearer ' + token}}
    if problems:
        raise WallError('nothing was written:\n  ' + '\n  '.join(problems))
    private_write(out, json.dumps({'mcpServers': config}, indent=2) + '\n')

    width = max(len(name) for name in servers)
    kind = max(len(device.role) for device, _ in servers.values())
    lines = [f"Wrote {len(servers)} MCP server{'s' if len(servers) > 1 else ''} to {out.resolve()}.", '']
    for name, (device, url) in servers.items():
        lines.append(f"  {name:<{width}}  {device.role:<{kind}}  {url}")
    if added:
        lines += ['', 'Added the controllers that type on your devices: ' + ', '.join(d.name for d in added.values()) + '.']
    if without_endpoint:
        lines += ['', 'No endpoint of their own, reached through their controller: ' + ', '.join(without_endpoint) + '.']
    if left_out:
        lines += ['', 'Left out, not found on the network: ' + ', '.join(left_out) + '.']
    protection = ('readable only by you (mode 600)' if os.name != 'nt'
                  else 'not protected by file modes on Windows, so keep it in a private folder')
    lines += ['', f'This file contains access tokens and is {protection}. Keep it out of git and shared folders.',
              f'In Claude Code: claude --mcp-config {shlex.quote(str(out.resolve()))}',
              f'Each tool is prefixed with its device name, for example mcp__{next(iter(servers))}__help.']
    print('\n'.join(lines))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name, text in (('status', 'Report which devices in wall.json are alive'),
                       ('compose', 'Write an MCP client config for a chosen part of the wall')):
        command = commands.add_parser(name, help=text, description=text)
        command.add_argument('--wall', default=str(CONFIG_DIR / 'wall.json'), help='Inventory file (default: %(default)s)')
        command.add_argument('--seconds', type=int, default=5, choices=range(1, 31), help='How long to listen for mDNS')
        if name == 'status':
            command.add_argument('--json', action='store_true', help='Machine-readable output')
        else:
            command.add_argument('--group', action='append', default=[], help='A group tag, or row<N> / col<N>; repeatable')
            command.add_argument('--device', action='append', default=[], help='A device name or id; repeatable')
            command.add_argument('--controller', action='append', default=[], help='A controller and every device it serves; repeatable')
            command.add_argument('--all', action='store_true', help='Every device in the inventory')
            command.add_argument('--out', required=True, help='Where to write the client config (mode 600)')
            command.add_argument('--force', action='store_true', help='Replace --out if it exists')
            command.add_argument('--skip-missing', action='store_true', help='Compose without devices that are not found')
    args = parser.parse_args(argv)
    try:
        return run_status(args) if args.command == 'status' else run_compose(args)
    except WallError as error:
        print(f'ewp-fleet: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
