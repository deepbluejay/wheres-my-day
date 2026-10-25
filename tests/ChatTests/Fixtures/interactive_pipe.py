"""Independent open-pipe peer for server and adapter protocol tests."""
import json
import os
import select
import subprocess
import sys
import time


class LinePeer:
    def __init__(self, incoming, outgoing, timeout=3, limit=1048576):
        self.incoming = incoming
        self.outgoing = outgoing
        self.timeout = timeout
        self.limit = limit
        self.pending = bytearray()

    def send(self, value):
        payload = json.dumps(value, ensure_ascii=False).encode() + b'\n'
        # Deliberately split headers, JSON tokens and UTF-8 between writes.
        for size in [1, 2, 5, len(payload)]:
            part, payload = payload[:size], payload[size:]
            while part:
                count = os.write(self.outgoing, part)
                part = part[count:]
            if payload:
                time.sleep(0.002)

    def read(self):
        deadline = None if self.timeout is None else time.monotonic() + self.timeout
        while True:
            end = self.pending.find(b'\n')
            if end >= 0:
                assert end <= self.limit, 'overlong line'
                line = bytes(self.pending[:end])
                del self.pending[:end + 1]
                return json.loads(line)
            assert len(self.pending) <= self.limit, 'overlong partial line'
            remaining = None if deadline is None else deadline - time.monotonic()
            assert (remaining is None or remaining > 0) and select.select([self.incoming], [], [], remaining)[0], 'No reply while pipe remains open'
            chunk = os.read(self.incoming, 65536)
            if not chunk:
                assert not self.pending, 'EOF inside a line'
                return None
            self.pending.extend(chunk)

    def messages(self):
        while True:
            value = self.read()
            if value is None:
                return
            yield value


def verify_query_server(command, environment, expected_minutes=None, timeout=None):
    child = subprocess.Popen([command], env=dict(os.environ, **environment), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    # Adapter tests supply their own lifetime; protocol progress depends on replies and EOF.
    peer = LinePeer(child.stdout.fileno(), child.stdin.fileno(), timeout=timeout)
    requests = [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26'}},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
        {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'day_summary', 'arguments': {'at': 14400}}},
        {'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'write', 'arguments': {}}},
    ]
    try:
        replies = []
        for request in requests:
            peer.send(request)
            reply = peer.read()
            assert reply['id'] == request['id']
            replies.append(reply)
        assert [tool['name'] for tool in replies[1]['result']['tools']] == [
            'recent_work', 'what_was_i_doing', 'search_activity', 'time_breakdown', 'day_summary']
        answer = json.loads(replies[2]['result']['content'][0]['text'])
        if expected_minutes is not None:
            assert answer['totalMinutes'] == expected_minutes
        assert 'error' in replies[3]
        child.stdin.close()
        assert peer.read() is None
        assert child.wait(timeout=timeout) == 0
    finally:
        if child.poll() is None:
            child.kill()
        child.wait()


if __name__ == '__main__':
    # Standalone runs retain a generous deadlock watchdog.
    verify_query_server(sys.argv[1], dict(os.environ), timeout=60)
