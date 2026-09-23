"""Loopback-only interoperability fixture for MA 2.10.1's aiosendspin version.
Run: uv run --python 3.12 --with 'aiosendspin[server]==9.1.1' scripts/sendspin-fixture.py
Only ephemeral test pairing secrets pass through this process; none are logged.
"""
import asyncio
from aiohttp import web
from aiosendspin.noise.keys import Identity
from aiosendspin.noise.pairing import PairingAttempt
from aiosendspin.noise.pairing_token import decode_token
from aiosendspin.noise.trust_store import InMemoryServerPairingStore
from aiosendspin.models.types import PairMethod
from aiosendspin.server.server import SendspinServer

async def main():
    server = SendspinServer(loop=asyncio.get_running_loop(), identity=Identity.generate(),
                            server_name='One protocol fixture', pairing_store=InMemoryServerPairingStore())
    async def pair(request):
        token = decode_token((await request.json())['token'])
        await server.initiate_pairing(token.client_id, PairingAttempt(PairMethod.PAIRING_PSK, pairing_psk=token.pairing_psk))
        return web.json_response({'paired': True})
    app = web.Application()
    app.router.add_get('/sendspin', server.on_client_connect)
    app.router.add_post('/pair', pair)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, '127.0.0.1', 0)
    await site.start()
    print('http://127.0.0.1:' + str(site._server.sockets[0].getsockname()[1]), flush=True)
    try:
        await asyncio.Event().wait()
    finally:
        await runner.cleanup()
        await server.close()

asyncio.run(main())
