#!/usr/bin/env python3
"""Build the shipped proxy through installer helpers; use only loopback sockets."""
import os
from pathlib import Path
import select
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
USER = b'audit-user'
PASSWORD = b'dummy-test-password'


def read_exact(sock, length):
    data = bytearray()
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise AssertionError(f'connection closed after {len(data)} of {length} expected bytes')
        data.extend(chunk)
    return bytes(data)


class Proxy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in ('cc', 'make'):
            if not shutil.which(tool):
                raise RuntimeError(f'{tool} is required to test the shipped proxy')
        cls.work = tempfile.TemporaryDirectory(prefix='cfwarp-microsocks-')
        cls.base = Path(cls.work.name)
        source = (ROOT / 'install.sh').read_text()
        helpers = source[source.index('CFWARP_BUILD_TMP='):source.index('prepare_private_wg_quick() {')]
        (cls.base / 'build.sh').write_text('#!/bin/sh\nset -eu\n' + helpers + '''
release_install_runtime_locks() { :; }
restore_quiesced_upgrade() { :; }
trap cleanup_install_temporary_files EXIT
SKIP_BUILD=0
MICROSOCKS_REPO=https://github.com/rofl0r/microsocks.git
MICROSOCKS_COMMIT=98421a21c4adc4c77c0cf3a5d650cc28ad3e0107
build_microsocks
publish_microsocks
''')
        cls.binary = cls.base / 'bin/microsocks'
        result = subprocess.run(['sh', str(cls.base / 'build.sh')], env=os.environ | {
            'SCRIPT_DIR': str(ROOT), 'BIN_DIR': str(cls.binary.parent),
            'MICROSOCKS_CFLAGS': '-O2 -Wall -Wextra -Werror -Wno-unknown-pragmas -std=c99 '
                                '-DCFWARP_HANDSHAKE_TIMEOUT_SECONDS=2 -DCFWARP_MAX_CLIENTS=4',
        }, capture_output=True, text=True, timeout=30)
        if result.returncode:
            cls.work.cleanup()
            raise AssertionError(result.stdout + result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def setUp(self):
        self.clients = []
        self.processes = []
        self.start_proxy()

    def tearDown(self):
        for client in self.clients:
            client.close()
        for process in self.processes:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            process.stderr.close()

    def start_proxy(self, auth=True):
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            self.port = reservation.getsockname()[1]
        args = [str(self.binary), '-q', '-i', '127.0.0.1', '-p', str(self.port)]
        if auth:
            args += ['-u', USER.decode(), '-P', PASSWORD.decode()]
        self.process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.processes.append(self.process)
        deadline = time.monotonic() + 3
        while True:
            try:
                probe = self.connect()
                probe.close()
                return
            except OSError:
                self.assertIsNone(self.process.poll(), 'proxy exited before startup')
                self.assertLess(time.monotonic(), deadline, 'proxy did not start')
                time.sleep(.01)

    def connect(self):
        client = socket.create_connection(('127.0.0.1', self.port), timeout=4)
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.clients.append(client)
        return client

    def send_fragmented(self, client, packet):
        for value in packet:
            client.sendall(bytes([value]))
            time.sleep(.005)

    def authenticate(self, client, fragmented=False):
        send = self.send_fragmented if fragmented else lambda sock, packet: sock.sendall(packet)
        send(client, b'\x05\x01\x02')
        self.assertEqual(read_exact(client, 2), b'\x05\x02')
        send(client, b'\x01' + bytes([len(USER)]) + USER + bytes([len(PASSWORD)]) + PASSWORD)
        self.assertEqual(read_exact(client, 2), b'\x01\x00')

    def tunnel(self, client, address, family=socket.AF_INET, fragmented=False, payload=b'echo-through-proxy'):
        with socket.socket(family) as listener:
            listener.settimeout(4)
            listener.bind((address, 0))
            listener.listen()
            port = listener.getsockname()[1]
            if address == 'localhost':
                host = address.encode()
                request = b'\x05\x01\x00\x03' + bytes([len(host)]) + host
            else:
                atyp = b'\x01' if family == socket.AF_INET else b'\x04'
                request = b'\x05\x01\x00' + atyp + socket.inet_pton(family, address)
            request += port.to_bytes(2, 'big')
            if fragmented:
                self.send_fragmented(client, request)
                client.sendall(payload)
            else:
                # A single write carries CONNECT and the first application bytes.
                client.sendall(request + payload)
            self.assertEqual(read_exact(client, 10), b'\x05\x00\x00\x01' + b'\0' * 6)
            target, _ = listener.accept()
            with target:
                target.settimeout(4)
                self.assertEqual(read_exact(target, len(payload)), payload)
                target.sendall(payload)
                self.assertEqual(read_exact(client, len(payload)), payload)

    def test_fragmented_greeting_credentials_and_ipv4_connect_forward_data(self):
        client = self.connect()
        self.authenticate(client, fragmented=True)
        self.tunnel(client, '127.0.0.1', fragmented=True)

    def test_coalesced_auth_connect_and_application_data_are_not_discarded(self):
        client = self.connect()
        # Pipeline greeting and credentials. Each frame must be consumed separately.
        client.sendall(b'\x05\x01\x02\x01' + bytes([len(USER)]) + USER + bytes([len(PASSWORD)]) + PASSWORD)
        self.assertEqual(read_exact(client, 4), b'\x05\x02\x01\x00')
        self.tunnel(client, '127.0.0.1')

    def test_fragmented_domain_connect(self):
        client = self.connect()
        self.authenticate(client)
        # Match the first libc answer used by the proxy; localhost may prefer ::1.
        family = socket.getaddrinfo('localhost', 0, socket.AF_UNSPEC, socket.SOCK_STREAM,
                                    0, socket.AI_PASSIVE)[0][0]
        self.tunnel(client, 'localhost', family=family, fragmented=True)

    def test_fragmented_ipv6_connect(self):
        try:
            with socket.socket(socket.AF_INET6) as probe:
                probe.bind(('::1', 0))
        except OSError:
            self.skipTest('IPv6 loopback is unavailable')
        client = self.connect()
        self.authenticate(client)
        self.tunnel(client, '::1', family=socket.AF_INET6, fragmented=True)

    def test_unauthenticated_mode_still_forwards_data(self):
        self.start_proxy(auth=False)
        client = self.connect()
        self.send_fragmented(client, b'\x05\x01\x00')
        self.assertEqual(read_exact(client, 2), b'\x05\x00')
        self.tunnel(client, '127.0.0.1')

    def test_wrong_credentials_are_rejected(self):
        client = self.connect()
        client.sendall(b'\x05\x01\x02')
        self.assertEqual(read_exact(client, 2), b'\x05\x02')
        packet = b'\x01' + bytes([len(USER)]) + USER + b'\x05wrong'
        self.send_fragmented(client, packet)
        self.assertEqual(read_exact(client, 2), b'\x01\x02')
        self.assertEqual(client.recv(1), b'')

    def test_maximum_length_frames_are_read_without_accepting_bad_credentials(self):
        client = self.connect()
        client.sendall(b'\x05\xff' + b'\x01' * 254 + b'\x02')
        self.assertEqual(read_exact(client, 2), b'\x05\x02')
        client.sendall(b'\x01\xff' + b'u' * 255 + b'\xff' + b'p' * 255)
        self.assertEqual(read_exact(client, 2), b'\x01\x02')
        self.assertEqual(client.recv(1), b'')

    def test_idle_unauthenticated_client_is_closed_by_deadline(self):
        client = self.connect()
        started = time.monotonic()
        self.assertEqual(client.recv(1), b'')
        elapsed = time.monotonic() - started
        self.assertGreater(elapsed, 1.3)
        self.assertLess(elapsed, 3.5)

    def test_slow_credentials_cannot_extend_whole_handshake_deadline(self):
        client = self.connect()
        started = time.monotonic()
        client.sendall(b'\x05\x01\x02')
        self.assertEqual(read_exact(client, 2), b'\x05\x02')
        client.sendall(b'\x01\xff')
        while time.monotonic() - started < 3.5:
            client.sendall(b'x')
            if select.select([client], [], [], .2)[0]:
                self.assertEqual(client.recv(1), b'')
                break
        else:
            self.fail('sending occasional bytes extended the handshake deadline')
        self.assertGreater(time.monotonic() - started, 1.3)
        self.assertLess(time.monotonic() - started, 3.5)

    def test_client_cap_rejects_excess_and_reuses_released_slot(self):
        clients = [self.connect() for _ in range(4)]
        for client in clients:
            client.sendall(b'\x05\x01\x02')
            self.assertEqual(read_exact(client, 2), b'\x05\x02')
        excess = self.connect()
        self.assertEqual(excess.recv(1), b'')
        tasks = Path(f'/proc/{self.process.pid}/task')
        if tasks.exists():
            self.assertLessEqual(len(list(tasks.iterdir())), 5)
        clients[0].close()
        deadline = time.monotonic() + 1
        while True:
            replacement = self.connect()
            try:
                replacement.sendall(b'\x05\x01\x02')
                reply = replacement.recv(2)
            except (ConnectionResetError, BrokenPipeError):
                # Closing a full-capacity connection with unread greeting bytes
                # produces RST rather than EOF. The old worker may still be exiting.
                reply = b''
            if reply:
                self.assertEqual(reply, b'\x05\x02')
                break
            replacement.close()
            self.assertLess(time.monotonic(), deadline, 'released worker slot was not reclaimed')
            time.sleep(.01)
        self.assertIsNone(self.process.poll())


if __name__ == '__main__':
    unittest.main(verbosity=2)
