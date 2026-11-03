"""Tiny independent RFC6455 fixture. No credentials or production server needed."""
import base64
import hashlib
import json
import random
import socket
import struct
import threading
import time

TRACK_SORTS = {f'{key}{suffix}' for key in ('name', 'sort_name', 'track_artist_name', 'timestamp_added',
               'timestamp_modified', 'duration', 'play_count', 'last_played') for suffix in ('', '_desc')} | {'random'}

listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen()
print(listener.getsockname()[1], flush=True)

def exact(conn, count):
    data = b''
    while len(data) < count:
        more = conn.recv(count - len(data))
        if not more:
            raise EOFError
        data += more
    return data

def send(conn, value):
    payload = json.dumps(value).encode()
    header = bytes([129, len(payload)]) if len(payload) < 126 else bytes([129, 126]) + struct.pack('!H', len(payload))
    conn.sendall(header + payload)

def handle(conn):
    try:
        request = b''
        while b'\r\n\r\n' not in request:
            request += exact(conn, 1)
        headers = dict(line.split(': ', 1) for line in request.decode().split('\r\n')[1:] if ': ' in line)
        if not any(name.lower() == 'sec-websocket-key' for name in headers):
            path = request.decode().split(' ')[1]
            status, result = 200, {}
            if headers.get('Authorization') != 'Bearer fixture-token':
                status = 401
            elif 'missing/' in path:
                status = 404
            elif path.endswith('/one/v1/capabilities'):
                result = {'version': 2 if 'legacy/' in path else 3, 'independent_audio': True, 'downloads': True}
            elif path.endswith('/one/v1/resolve'):
                length = int(next((value for name, value in headers.items() if name.lower() == 'content-length'), '0'))
                body = json.loads(exact(conn, length))
                result = {'ready': True, 'path': 'one/v1/audio/11111111-1111-4111-8111-111111111111.m4a'}
                if body.get('uri') == 'library://track/native': result['path'] = 'one/v1/audio/11111111-1111-4111-8111-111111111111.flac'
                if body.get('uri') == 'library://track/external': result['path'] = 'https://other.example/track.m4a'
                if body.get('uri') == 'library://track/streamed':
                    result |= {'stream': 'one/v1/stream/22222222-2222-4222-8222-222222222222/index.m3u8', 'ready': False}
                if body.get('uri') == 'library://track/prepared':
                    result |= {'stream': 'one/v1/stream/22222222-2222-4222-8222-222222222222/index.m3u8', 'ready': True}
                if body.get('uri') == 'library://track/escaped':
                    result |= {'stream': 'one/v1/stream/../../imageproxy/index.m3u8', 'ready': False}
            else:
                status = 404
            payload = json.dumps(result).encode()
            conn.sendall((f'HTTP/1.1 {status} Response\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n').encode() + payload)
            return
        key = next(value for name, value in headers.items() if name.lower() == 'sec-websocket-key')
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
        send(conn, {'server_id': 'test', 'schema_version': 65, 'min_supported_schema_version': 28})
        playback = None
        owner = None
        skew = 0

        def queue_event():
            send(conn, {'event': 'queue_updated', 'object_id': owner, 'data': playback})

        def track(ident, duration):
            return {'queue_item_id': ident, 'duration': duration,
                    'media_item': {'uri': f'library://track/{ident}', 'name': ident},
                    'streamdetails': {'seek_position': 0}}

        while True:
            op, size = exact(conn, 2)
            mask = size & 128
            size &= 127
            if size == 126: size = struct.unpack('!H', exact(conn, 2))[0]
            if size == 127: size = struct.unpack('!Q', exact(conn, 8))[0]
            key = exact(conn, 4) if mask else None
            data = exact(conn, size)
            if key: data = bytes(value ^ key[i % 4] for i, value in enumerate(data))
            if op & 15 == 8: return
            if op & 15 == 9:
                conn.sendall(bytes([138, len(data)]) + data)
                continue
            msg = json.loads(data)
            ident, command = msg['message_id'], msg['command']
            if command == 'auth':
                if msg['args']['token'] != 'fixture-token':
                    send(conn, {'message_id': ident, 'error_code': 20, 'details': 'Invalid token'})
                else: send(conn, {'message_id': ident, 'result': {'user': 'test'}})
            elif command == 'fixture/playback':
                args = msg['args']
                owner = 'universal-sendspin' if args.get('linked', True) else args.get('player_id', 'speaker')
                skew = args.get('skew', 0)
                playback = {'queue_id': owner, 'active': True, 'state': 'playing',
                            'elapsed_time': 80, 'elapsed_time_last_updated': time.time() + skew,
                            'playback_speed': 1, 'flow_mode': args.get('flow', True),
                            'current_index': 0, 'current_item': track('first', 200)}
                send(conn, {'message_id': ident, 'result': playback})
            elif command == 'player_queues/get_active_queue':
                send(conn, {'message_id': ident, 'result': playback})
            elif command == 'fixture/regroup':
                owner = 'sendspin-group'
                playback['queue_id'] = owner
                send(conn, {'message_id': ident, 'result': playback})
            elif command == 'player_queues/seek':
                args = msg['args']
                if args['queue_id'] != owner or not playback['active']:
                    send(conn, {'message_id': ident, 'error_code': 1,
                                'details': f"Queue {args['queue_id']} is not active"})
                    continue
                # MA 2.10.9 publishes the target before rebuilding the flow stream.
                playback['elapsed_time'] = args['position']
                playback['elapsed_time_last_updated'] = time.time() + skew
                queue_event()
                playback['current_item']['streamdetails']['seek_position'] = args['position']
                send(conn, {'event': 'queue_time_updated', 'object_id': owner, 'data': args['position']})
                send(conn, {'message_id': ident, 'result': None})
            elif command in ('players/cmd/next', 'fixture/advance'):
                # Flow stream time can be 200.25; the queue event is track-relative 0.25.
                playback['current_index'] += 1
                playback['current_item'] = track('second', 120)
                playback['elapsed_time'] = 0 if command.endswith('/next') else 0.25
                playback['elapsed_time_last_updated'] = time.time() + skew
                queue_event()
                send(conn, {'message_id': ident, 'result': None})
            elif command in ('players/cmd/pause', 'players/cmd/play'):
                playback['state'] = 'paused' if command.endswith('/pause') else 'playing'
                playback['elapsed_time_last_updated'] = time.time() + skew
                queue_event()
                send(conn, {'message_id': ident, 'result': None})
            elif command == 'partial':
                send(conn, {'message_id': ident, 'result': [1, 2], 'partial': True})
                send(conn, {'event': 'player_updated', 'object_id': 'one', 'data': {'player_id': 'one'}})
                send(conn, {'message_id': ident, 'result': [3], 'partial': False})
            elif command == 'music/tracks/library_items':
                args = msg['args']
                order = args.get('order_by', 'sort_name')
                # Music Assistant 2.10.9 track sort keys. Tracks have no year column, and only the
                # track artist join exists, so other keys fail in SQL there; mirror that as an error.
                if order not in TRACK_SORTS:
                    send(conn, {'message_id': ident, 'error_code': 999, 'details': f'no such column: {order}'})
                    continue
                rows = [{'uri': f'library://track/{i}', 'name': f'Track {i:03}', 'media_type': 'track',
                         'duration': 120 + (i * 37) % 240, 'artists': [{'name': f'Artist {(i * 7) % 13:02}'}]}
                        for i in range(237)]
                query = args.get('search', '').lower()
                rows = [row for row in rows if query in row['name'].lower()]
                base = order.removesuffix('_desc')
                if order == 'random':
                    rows = random.sample(rows, len(rows))
                elif base == 'duration':
                    rows.sort(key=lambda row: (row['duration'], row['name']))
                elif base == 'track_artist_name':
                    rows.sort(key=lambda row: (row['artists'][0]['name'], row['name']))
                if order.endswith('_desc'): rows.reverse()
                offset, limit = args.get('offset', 0), args.get('limit', 100)
                send(conn, {'message_id': ident, 'result': rows[offset:offset + limit]})
            elif command == 'music/search':
                args = msg['args']
                if 'offset' in args:
                    send(conn, {'message_id': ident, 'error_code': 1, 'details': 'Search does not accept offset'})
                    continue
                result = {}
                for kind in args['media_types']:
                    key = 'radio' if kind == 'radio' else kind + 's'
                    result[key] = [{'uri': f'provider://{kind}/{i}', 'name': f'Match {i:03}', 'media_type': kind} for i in range(min(args['limit'], 123))]
                send(conn, {'message_id': ident, 'result': result})
            elif command == 'fail':
                send(conn, {'message_id': ident, 'error_code': 1, 'details': 'Unsupported command'})
            elif command == 'wait': pass
            elif command == 'drop': return
            else: send(conn, {'message_id': ident, 'result': msg['args']})
    except (EOFError, OSError): pass
    finally: conn.close()

while True:
    conn, _ = listener.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
