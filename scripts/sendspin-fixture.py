"""Loopback-only interoperability fixture for MA 2.10.7's aiosendspin version.
Run: uv run --python 3.12 --with 'aiosendspin[server]==10.2.0' scripts/sendspin-fixture.py
Only ephemeral test pairing secrets pass through this process; none are logged.
"""
import asyncio
from aiohttp import web
from aiosendspin.noise.keys import Identity
from aiosendspin.noise.pairing import PairingAttempt
from aiosendspin.noise.pairing_token import decode_psk_token
from aiosendspin.noise.trust_store import InMemoryServerPairingStore
from aiosendspin.models.types import PairMethod
from aiosendspin.server.server import SendspinServer

async def main():
    # Matches MA's default "Allow legacy clients"; the pinned SendspinKit predates the current spec.
    server = SendspinServer(loop=asyncio.get_running_loop(), identity=Identity.generate(),
                            server_name='One protocol fixture', pairing_store=InMemoryServerPairingStore(),
                            allow_noncompliant_clients=True)
    async def pair(request):
        token = decode_psk_token((await request.json())['token'])
        await server.initiate_pairing(token.client_id, PairingAttempt(PairMethod.PAIRING_PSK, client_id=token.client_id, pairing_psk=token.pairing_psk))
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
