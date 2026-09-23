"""Tiny independent RFC6455 fixture. No credentials or production server needed."""
import base64
import hashlib
import json
import socket
import struct
import threading

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
        key = next(value for name, value in headers.items() if name.lower() == 'sec-websocket-key')
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
        send(conn, {'server_id': 'test', 'schema_version': 65, 'min_supported_schema_version': 28})
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
            elif command == 'partial':
                send(conn, {'message_id': ident, 'result': [1, 2], 'partial': True})
                send(conn, {'event': 'player_updated', 'object_id': 'one', 'data': {'player_id': 'one'}})
                send(conn, {'message_id': ident, 'result': [3], 'partial': False})
            elif command == 'music/tracks/library_items':
                args = msg['args']
                rows = [{'uri': f'library://track/{i}', 'name': f'Track {i:03}', 'media_type': 'track'} for i in range(237)]
                query = args.get('search', '').lower()
                rows = [row for row in rows if query in row['name'].lower()]
                if args.get('order_by') == 'timestamp_added_desc': rows.reverse()
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
