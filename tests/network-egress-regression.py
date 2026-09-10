#!/usr/bin/env python3
"""Isolated Linux/root checks using real WireGuard peers and controlled servers."""
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

if '--live' not in sys.argv:
    print('SKIP: isolated Linux/root egress checks require --live.')
    raise SystemExit(0)
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('--live requires root in an isolated Linux VM')
os.umask(0o077)
ROOT = Path(__file__).resolve().parents[1]
TMP = Path(tempfile.mkdtemp(prefix='cfwarp-egress-test.'))
TAG = f'cfe{os.getpid()}'
NS, HOST_IF, NS_IF, SERVER_IF = TAG, f'{TAG}h', f'{TAG}n', f'{TAG}w'
HOST_IP, PEER_IP, SERVER_IP, CLIENT_IP = '169.254.233.1', '169.254.233.2', '10.233.0.1', '10.233.0.2'
HOST6, PEER6 = 'fd99:233::1', 'fd99:233::2'
CONF = TMP / 'wgtest.conf'
ENV = dict(os.environ, CFWARP_ENV_LOADED='1', CFWARP_MODE='netns-proxy',
           CFWARP_STATE_DIR=str(TMP / 'state'), CFWARP_GLOBAL_STATE_DIR=str(TMP / 'global'),
           NETNS_NAME=NS, NETNS_HOST_IF=HOST_IF, NETNS_NS_IF=NS_IF,
           NETNS_HOST_ADDR=HOST_IP + '/30', NETNS_PEER_ADDR=PEER_IP + '/30',
           NETNS_CIDR='169.254.233.0/30', WG_INTERFACE='wgtest', WG_CONF=str(CONF),
           WG_QUICK_BIN='/usr/bin/wg-quick', BIND_PORT='11080', CFWARP_WG_FWMARK='51820',
           CFWARP_LOCK_WAIT_SECONDS='1')
PROCESSES, SERVERS, UDP_PACKETS = [], [], []


def run(*args, ok=True, timeout=10, input=None):
    result = subprocess.run(list(args), env=ENV, text=True, input=input,
                            capture_output=True, timeout=timeout)
    if ok and result.returncode:
        raise AssertionError(f'{args!r}: exit {result.returncode}\n{result.stderr}')
    return result


def inside(*args, **kwargs):
    return run('ip', 'netns', 'exec', NS, *args, **kwargs)


def netns(action, **kwargs):
    return run('sh', str(ROOT / 'cfwarp-netns.sh'), action, **kwargs)


def safe_exec(*args, **kwargs):
    return run(str(ROOT / 'cfwarp-exec'), *args, **kwargs)


def wait_file(path):
    for _ in range(100):
        if path.exists():
            return
        time.sleep(.05)
    raise AssertionError(f'child did not create {path.name}')


def start_process(args):
    process = subprocess.Popen(args, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    PROCESSES.append(process)
    return process


def toggle_guard(enabled):
    for binary in ('iptables', 'ip6tables'):
        if enabled:
            inside(binary, '-P', 'OUTPUT', 'DROP')
            inside(binary, '-I', 'OUTPUT', '1', '-j', 'CFWARP_EGRESS')
        else:
            inside(binary, '-D', 'OUTPUT', '-j', 'CFWARP_EGRESS')
            inside(binary, '-P', 'OUTPUT', 'ACCEPT')


class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.client_address[0].encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class HTTP6(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(1024):
            self.request.sendall(data)


class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        UDP_PACKETS.append(self.request[0])


class EchoServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def serve(server):
    SERVERS.append(server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


def curl(host, port, ok=True):
    address = f'[{host}]' if ':' in host else host
    return inside('curl', '--noproxy', '*', '-gfsS', '--connect-timeout', '1', '--max-time', '2',
                  f'http://{address}:{port}/', ok=ok)


def persistent(label, port, bind_port=0):
    ready, go, result = [TMP / f'{label}.{suffix}' for suffix in ('ready', 'go', 'result')]
    code = '''import pathlib,socket,sys,time
host,port,bind,ready,go,result=sys.argv[1:]
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.settimeout(1)
s.bind(("0.0.0.0",int(bind)));s.connect((host,int(port)));s.sendall(b"first")
assert s.recv(5)==b"first";pathlib.Path(ready).touch()
while not pathlib.Path(go).exists(): time.sleep(.02)
try:
 s.sendall(b"second"); outcome="leaked" if s.recv(6)==b"second" else "blocked"
except (TimeoutError,OSError): outcome="blocked"
pathlib.Path(result).write_text(outcome)
'''
    process = start_process(['ip', 'netns', 'exec', NS, 'python3', '-c', code, SERVER_IP,
                             str(port), str(bind_port), str(ready), str(go), str(result)])
    wait_file(ready)
    return process, go, result


def assert_persistent_blocked(client):
    process, go, result = client
    go.touch()
    process.communicate(timeout=5)
    assert process.returncode == 0
    assert result.read_text() == 'blocked'


initial_forward = run('sysctl', '-n', 'net.ipv4.ip_forward').stdout.strip()
try:
    # A real listener remains reachable throughout the negative checks. The
    # response identifies whether traffic used the plain veth or WG source IP.
    server_key = run('wg', 'genkey').stdout
    client_key = run('wg', 'genkey').stdout
    (TMP / 'server.key').write_text(server_key)
    server_public = run('wg', 'pubkey', input=server_key).stdout.strip()
    client_public = run('wg', 'pubkey', input=client_key).stdout.strip()
    run('ip', 'link', 'add', SERVER_IF, 'type', 'wireguard')
    run('ip', 'addr', 'add', SERVER_IP + '/32', 'dev', SERVER_IF)
    run('wg', 'set', SERVER_IF, 'private-key', str(TMP / 'server.key'), 'listen-port', '0',
        'peer', client_public, 'allowed-ips', CLIENT_IP + '/32')
    run('ip', 'link', 'set', SERVER_IF, 'up')
    run('ip', 'route', 'add', CLIENT_IP + '/32', 'dev', SERVER_IF)
    server_port = run('wg', 'show', SERVER_IF, 'listen-port').stdout.strip()
    CONF.write_text(f'[Interface]\nPrivateKey = {client_key.strip()}\nAddress = {CLIENT_IP}/32\n'
                    f'FwMark = 51820\n[Peer]\nPublicKey = {server_public}\n'
                    f'AllowedIPs = 0.0.0.0/0\nEndpoint = {HOST_IP}:{server_port}\nPersistentKeepalive = 1\n')
    http_port = serve(http.server.ThreadingHTTPServer((SERVER_IP, 0), HTTP))
    echo_port = serve(EchoServer((SERVER_IP, 0), Echo))
    udp_port = serve(socketserver.ThreadingUDPServer((SERVER_IP, 0), UDP))
    netns('up')
    run('ip', '-6', 'addr', 'add', HOST6 + '/64', 'dev', HOST_IF, 'nodad')
    inside('ip', '-6', 'addr', 'add', PEER6 + '/64', 'dev', NS_IF, 'nodad')
    host_mac = json.loads(run('ip', '-j', 'link', 'show', HOST_IF).stdout)[0]['address']
    peer_mac = json.loads(inside('ip', '-j', 'link', 'show', NS_IF).stdout)[0]['address']
    inside('ip', '-6', 'neigh', 'replace', HOST6, 'lladdr', host_mac, 'nud', 'permanent', 'dev', NS_IF)
    run('ip', '-6', 'neigh', 'replace', PEER6, 'lladdr', peer_mac, 'nud', 'permanent', 'dev', HOST_IF)
    inside('ip', '-6', 'route', 'add', 'default', 'via', HOST6, 'dev', NS_IF)
    http6_port = serve(HTTP6((HOST6, 0), HTTP))
    marker = TMP / 'executed'
    assert safe_exec('touch', str(marker), ok=False).returncode != 0 and not marker.exists()
    assert curl(SERVER_IP, http_port, ok=False).returncode != 0
    assert curl(HOST6, http6_port, ok=False).returncode != 0
    toggle_guard(False)
    assert curl(SERVER_IP, http_port).stdout == PEER_IP
    assert curl(HOST6, http6_port).stdout == PEER6
    inside('python3', '-c', 'import socket,sys;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.sendto(b"control",(sys.argv[1],int(sys.argv[2])))', SERVER_IP, str(udp_port))
    for _ in range(20):
        if UDP_PACKETS:
            break
        time.sleep(.05)
    assert UDP_PACKETS == [b'control']
    plain_client = persistent('plain', echo_port, bind_port=11080)
    toggle_guard(True)
    assert_persistent_blocked(plain_client)
    inside('python3', '-c', 'import socket,sys;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.sendto(b"blocked",(sys.argv[1],int(sys.argv[2])))', SERVER_IP, str(udp_port), ok=False)
    time.sleep(.2)
    assert UDP_PACKETS == [b'control']
    assert curl(SERVER_IP, http_port, ok=False).returncode != 0
    assert curl(HOST6, http6_port, ok=False).returncode != 0
    print('PASS: controlled IPv4/IPv6/UDP baselines succeed; startup and existing plain TCP are blocked')

    # Real lock contention exercises the recovery/conditional release path.
    lock_ready = TMP / 'lock.ready'
    holder = start_process(['flock', str(TMP / 'global/ip_forward.flock'), 'sh', '-c',
                            'touch "$1"; sleep 5', 'holder', str(lock_ready)])
    wait_file(lock_ready)
    refs = (TMP / 'global/ip_forward.refs').read_bytes()
    before = run('sysctl', '-n', 'net.ipv4.ip_forward').stdout
    assert netns('down', ok=False).returncode != 0
    assert (TMP / 'global/ip_forward.refs').read_bytes() == refs
    assert (TMP / f'state/{NS}.env').exists()
    assert run('sysctl', '-n', 'net.ipv4.ip_forward').stdout == before
    holder.communicate(timeout=6)
    netns('down')
    netns('up')
    print('PASS: real forwarding lock timeout preserves refs and recovery state; retry succeeds')

    inside('/usr/bin/wg-quick', 'up', str(CONF))
    assert curl(SERVER_IP, http_port).stdout == CLIENT_IP
    safe_exec('touch', str(marker))
    assert marker.exists()
    resident_ready, resident_go, resident_result = [TMP / f'resident.{suffix}' for suffix in ('ready', 'go', 'result')]
    resident_code = '''import json,os,pathlib,subprocess,sys,time
ready,go,result,url=sys.argv[1:]; inode=os.stat("/proc/self/ns/net").st_ino
pathlib.Path(ready).touch()
while not pathlib.Path(go).exists():time.sleep(.02)
guard=subprocess.check_output(["iptables","-S","OUTPUT"],text=True)
r=subprocess.run(["curl","--noproxy","*","-fsS","--max-time","1",url],capture_output=True)
pathlib.Path(result).write_text(json.dumps(dict(inode=inode,guard=guard,status=r.returncode)))
'''
    resident = start_process([str(ROOT / 'cfwarp-exec'), 'python3', '-c', resident_code,
                              str(resident_ready), str(resident_go), str(resident_result),
                              f'http://{SERVER_IP}:{http_port}/'])
    wait_file(resident_ready)
    inside('iptables', '-A', 'FORWARD', '-j', 'ACCEPT')
    assert safe_exec('true', ok=False).returncode != 0
    inside('iptables', '-D', 'FORWARD', '-j', 'ACCEPT')
    tunnel_client = persistent('tunnel', echo_port)
    inside('ip', '-4', 'route', 'del', 'default', 'table', '51820')
    assert_persistent_blocked(tunnel_client)
    assert curl(SERVER_IP, http_port, ok=False).returncode != 0
    assert safe_exec('true', ok=False).returncode != 0
    inside('ip', '-4', 'route', 'add', 'default', 'dev', 'wgtest', 'table', '51820')
    assert curl(SERVER_IP, http_port).stdout == CLIENT_IP
    inside('ip', 'link', 'del', 'wgtest')
    assert curl(SERVER_IP, http_port, ok=False).returncode != 0
    assert safe_exec('true', ok=False).returncode != 0
    print('PASS: real WG transport works; route deletion/interface loss block new and existing TCP fallback')

    # The sole TCP exemption permits replies to incoming proxy clients, not
    # existing locally initiated flows (the bound-port control above tested it).
    proxy_ready = TMP / 'proxy.ready'
    proxy_code = '''import pathlib,socket,sys
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind((sys.argv[1],11080));s.listen(1);pathlib.Path(sys.argv[2]).touch()
c,_=s.accept();c.sendall(c.recv(64));c.close();s.close()
'''
    proxy = start_process(['ip', 'netns', 'exec', NS, 'python3', '-c', proxy_code, PEER_IP, str(proxy_ready)])
    wait_file(proxy_ready)
    with socket.create_connection((PEER_IP, 11080), timeout=2) as connection:
        connection.sendall(b'proxy-reply')
        assert connection.recv(64) == b'proxy-reply'
    proxy.communicate(timeout=3)
    assert proxy.returncode == 0
    netns('down')
    # A command already entered via cfwarp-exec must neither retain the action
    # lock nor follow a new namespace that later reuses the deleted name.
    run('ip', 'netns', 'add', NS)
    replacement_inode = int(run('stat', '-Lc', '%i', '/run/netns/' + NS).stdout)
    resident_go.touch()
    resident.communicate(timeout=4)
    result = json.loads(resident_result.read_text())
    assert result['inode'] != replacement_inode
    assert result['guard'].startswith('-P OUTPUT DROP\n-A OUTPUT -j CFWARP_EGRESS\n')
    assert result['status'] != 0
    run('ip', 'netns', 'del', NS)
    print('PASS: proxy replies work without WG; entered commands retain their guard across teardown/name reuse')
    print('PASS: all isolated egress and forwarding-lock regressions')
finally:
    for process in PROCESSES:
        if process.poll() is None:
            process.kill()
        process.communicate()
    run('sh', str(ROOT / 'cfwarp-netns.sh'), 'down', ok=False)
    run('ip', 'link', 'del', HOST_IF, ok=False)
    run('ip', 'netns', 'del', NS, ok=False)
    run('ip', 'link', 'del', SERVER_IF, ok=False)
    run('sysctl', '-w', 'net.ipv4.ip_forward=' + initial_forward, ok=False)
    for server in SERVERS:
        server.shutdown()
        server.server_close()
    shutil.rmtree(TMP)
