"""Read-only BLE acceptance check; does not pair, provision, or subscribe to HID."""
import argparse
import asyncio
import json

from bleak import BleakClient, BleakScanner

SERVICE = "e7a00001-7c3d-4d21-a19a-455750000001"
CONFIG = "e7a00002-7c3d-4d21-a19a-455750000001"
STATUS = "e7a00003-7c3d-4d21-a19a-455750000001"
HID = "00001812-0000-1000-8000-00805f9b34fb"


async def check(name):
    found = await BleakScanner.discover(timeout=8, return_adv=True)
    matches = [(device, adv) for device, adv in found.values() if device.name == name]
    if len(matches) != 1:
        raise RuntimeError("Expected one matching ESP32 advertisement")
    device, advertisement = matches[0]
    if not {SERVICE, HID}.issubset(advertisement.service_uuids):
        raise RuntimeError("HID or provisioning UUID missing from advertisement")
    async with BleakClient(device, services=[SERVICE], timeout=12) as client:
        config = client.services.get_characteristic(CONFIG)
        if not config or "write" not in config.properties:
            raise RuntimeError("Provisioning GATT write characteristic is missing")
        status = json.loads(await client.read_gatt_char(STATUS))
        print(json.dumps({"id": status.get("id"), "state": status.get("state"),
                          "setup_open": status.get("setup_open"), "hid_advertised": True,
                          "provisioning_gatt": True, "status_read": True}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    args = parser.parse_args()
    async def bounded_check():
        async with asyncio.timeout(25):
            await check(args.name)
    asyncio.run(bounded_check())
