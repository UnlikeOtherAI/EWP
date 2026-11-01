"""Opt-in acceptance against a real iOS/ESP32 endpoint, never a proxy or fixture."""
import base64
from io import BytesIO
import json
import os
from pathlib import Path
import unittest
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler

from mcp import ClientSession, McpError
from mcp.client.streamable_http import streamablehttp_client
from PIL import Image

ENDPOINT = os.environ.get('EWP_TEST_ENDPOINT')
TOKEN_FILE = os.environ.get('EWP_TEST_TOKEN_FILE')


@unittest.skipUnless(ENDPOINT and TOKEN_FILE, 'Requires an explicitly selected physical EWP endpoint and private credential file')
class DirectMCPTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_mcp_initialize_tools_and_status(self):
        token = Path(TOKEN_FILE).read_text().strip()
        async with streamablehttp_client(ENDPOINT, headers={'Authorization': 'Bearer ' + token}) as (r, w, _):
            async with ClientSession(r, w) as client:
                initialized = await client.initialize()
                self.assertTrue(initialized.serverInfo.name.startswith('EWP'))
                tools = {tool.name for tool in (await client.list_tools()).tools}
                status_tool = 'device_status' if 'device_status' in tools else 'get_status'
                status = await client.call_tool(status_tool, {})
                self.assertFalse(status.isError)
                self.assertIsInstance(json.loads(status.content[0].text), dict)
                try:
                    unknown = await client.call_tool('no_such_ewp_tool', {})
                    self.assertTrue(unknown.isError)
                except McpError as error:
                    self.assertEqual(error.error.code, -32602)
                if 'get_screen' in tools and os.environ.get('EWP_TEST_SCREEN') == '1':
                    screen = await client.call_tool('get_screen', {})
                    self.assertFalse(screen.isError)
                    content = next(x for x in screen.content if x.type == 'image')
                    with Image.open(BytesIO(base64.b64decode(content.data))) as image:
                        image.load()
                        self.assertLessEqual(max(image.size), 1280)
                        self.assertGreater(min(image.size), 0)

    def test_browser_origins_and_missing_credentials_are_rejected(self):
        token = Path(TOKEN_FILE).read_text().strip()
        opener = build_opener(ProxyHandler({}))
        for headers in ({}, {'Authorization': 'Bearer ' + token, 'Origin': 'https://example.invalid'}):
            request = Request(ENDPOINT, data=b'{}', headers={'Content-Type': 'application/json', **headers})
            with self.assertRaises(HTTPError) as error:
                opener.open(request, timeout=5)
            self.assertIn(error.exception.code, (401, 403))
