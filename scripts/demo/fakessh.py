#!/usr/bin/env python3
"""SSH hosts for Conterm on iOS to connect to, all on this Mac's loopback.

  web-01   127.0.0.1:2201   a Linux server: the Host Overview collector gets
                            demo.py's canned answer, a shell gets its banner
                            and prompt
  studio   127.0.0.1:2202   "Studio Mac": runs what the phone asks with HOME
                            set to the demo Conterm's state home, so the
                            phone reads that instance's published sessions
                            and pane mirrors and writes to its inbox

Any user name and any key are accepted: the hosts exist only for the
simulator on this machine and listen on 127.0.0.1 alone. The Mac is also
announced on Bonjour (`_conterm._tcp`, as Conterm does) with a pairing
responder that accepts every phone, and web-01.local / studio.local resolve
to 127.0.0.1 for as long as this runs.

Prints one JSON line when ready — host key fingerprint, client key path —
and serves until interrupted. Needs asyncssh (screenshots-ios.sh installs it
into .build/demo-venv).
"""
import asyncio, base64, contextlib, fcntl, hashlib, io, json, os, pty, signal, struct, sys, termios

import asyncssh

DEMO = "/Users/Shared/conterm-demo"
PLAYER = f"{DEMO}/home/.local/share/conterm-demo/demo.py"
RUN = f"{DEMO}/ios"
HOSTS = {"web-01": 2201, "studio": 2202}
PAIR_PORT = 2299
HOMES = {"web-01": f"{DEMO}/ios/web-01", "studio": f"{DEMO}/state"}
USERS = {"web-01": "deploy", "studio": "sam"}
SHIMS = f"{RUN}/shims"

sys.path.insert(0, os.path.dirname(PLAYER))
import demo  # noqa: E402  (the staged copy, for its host fixtures)

# ── what the hosts say ───────────────────────────────────────────────
MAC_PROBE = {
    "hostname": ["Studio-Mac"], "fqdn": ["Studio-Mac.local"],
    "os": ["ProductName:\tmacOS ProductVersion:\t26.1 "], "kernel": ["Darwin 25.1.0"],
    "arch": ["arm64"], "uptime": [" 9:41  up 12 days,  3:08, 2 users, load averages: 1.84 1.72 1.65"],
    "loadavg": ["{ 1.84 1.72 1.65 }"], "cores": ["10"], "mem": [],
    "disk": ["/dev/disk3s1s1  971350180  11285432  487263296  3%  /",
             "/dev/disk3s5  971350180  401200000  487263296  46%  /System/Volumes/Data"],
    "ips": ["10.0.1.50"], "runtime": ["docker"],
    "containers": ["postgres\tpostgres:17\tUp 2 hours (healthy)", "redis\tredis:7.4-alpine\tUp 2 hours",
                   "localstack\tlocalstack/localstack:4\tUp 41 minutes"],
    "vms": [], "kubelet": [], "kubenodes": [], "timers": [], "cron": ["0"], "failed": ["0"],
    "failedlist": [], "users": ["2"], "reboot": [],
    "procs": ["Conterm          12.1  2.3", "claude            8.4  1.9", "com.docker.backe  3.2  4.1",
              "WindowServer      2.9  0.8", "go                1.7  0.6"],
    "ports": ["*.22", "127.0.0.1.5432", "127.0.0.1.6379"], "journal": [], "kernlog": [],
    "lastlog": [], "updates": [], "tz": ["/var/db/timezone/zoneinfo/Europe/Amsterdam"], "utcoff": ["+0200"],
}

def probe(name):
    if name == "studio":
        out = []
        for key, lines in MAC_PROBE.items():
            out.append(f"\n===conterm:{key}===")
            out.extend(lines)
        out.append("\n===conterm:end===")
        return "\n".join(out) + "\n"
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        demo.probe(name)
    text = buf.getvalue().replace("\n===conterm:end===",
                                  "\n===conterm:tz===\nEtc/UTC\n===conterm:utcoff===\n+0000\n===conterm:end===")
    return text

# The overview's live sampler reads counters and diffs them between calls,
# so they have to move: a few hundred ticks of CPU and some kilobytes of
# traffic per read, the busy share wandering a little.
_counters = {}

def pulse(name):
    import random, time as _t
    c = _counters.setdefault(name, {"t": _t.time(), "cores": [[1000, 4000] for _ in range(4)],
                                    "rx": 9_812_331_002, "tx": 4_221_908_115})
    now = _t.time(); dt = max(now - c["t"], 0.5); c["t"] = now
    for core in c["cores"]:
        ticks = int(100 * dt)
        busy = int(ticks * random.uniform(0.22, 0.58))
        core[0] += busy; core[1] += ticks - busy
    c["rx"] += int(dt * random.uniform(40_000, 160_000))
    c["tx"] += int(dt * random.uniform(12_000, 60_000))
    tot = [sum(x[0] for x in c["cores"]), sum(x[1] for x in c["cores"])]
    def cpu(label, busy, idle):
        return f"{label} {busy} 0 {busy // 5} {idle} 12 0 9 0 0 0"
    load = f"{random.uniform(0.55, 0.85):.2f} 0.58 0.51 2/311 88213"
    lines = ["\n===conterm:load===", load,
             "\n===conterm:mem===", "MemTotal:        8141820 kB", f"MemAvailable:    {random.randint(3_300_000, 3_420_000)} kB",
             "\n===conterm:stat===", cpu("cpu ", *tot)] + \
            [cpu(f"cpu{i}", *core) for i, core in enumerate(c["cores"])] + \
            ["\n===conterm:net===",
             f"  eth0: {c['rx']} 8123412 0 0 0 0 0 0 {c['tx']} 6012345 0 0 0 0 0 0",
             "\n===conterm:top===", "\n===conterm:macmem===", "\n===conterm:end==="]
    return "\n".join(lines) + "\n"

def env_for(name, term=None):
    env = {"HOME": HOMES[name], "USER": USERS[name], "LOGNAME": USERS[name],
           "PATH": f"{SHIMS}:/usr/bin:/bin", "LANG": "en_US.UTF-8", "SHELL": "/bin/sh"}
    if term: env["TERM"] = term
    return env

# ── sessions ─────────────────────────────────────────────────────────
def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows or 24, cols or 80, 0, 0))

def _controlling_tty():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

async def until_either(proc, process):
    """Whichever ends first, the program or the channel, ends the other."""
    waits = [asyncio.ensure_future(proc.wait()), asyncio.ensure_future(process.wait_closed())]
    await asyncio.wait(waits, return_when=asyncio.FIRST_COMPLETED)
    if proc.returncode is None:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        await proc.wait()
    for w in waits: w.cancel()
    return proc.returncode

async def shell(name, process):
    cols, rows = (process.term_size or (80, 24))[:2]
    master, slave = pty.openpty()
    set_size(master, rows, cols)
    env = env_for(name, process.term_type or "xterm-256color")
    env["SSH_ORIGINAL_COMMAND"] = ""
    env["DEMO_TAIL"] = "1"
    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/python3", PLAYER, "host", name if name in demo.HOSTS else "web-01",
        stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=_controlling_tty)
    os.close(slave)
    loop = asyncio.get_running_loop()

    def readable():
        try: data = os.read(master, 65536)
        except OSError: data = b""
        if not data:
            loop.remove_reader(master)
            return
        process.stdout.write(data)
    loop.add_reader(master, readable)

    async def pump():
        while True:
            try:
                data = await process.stdin.read(4096)
            except asyncssh.TerminalSizeChanged as change:
                set_size(master, change.height, change.width)
                continue
            if not data: break
            os.write(master, data)
    feeder = asyncio.ensure_future(pump())
    rc = await until_either(proc, process)
    feeder.cancel()
    with contextlib.suppress(Exception): loop.remove_reader(master)
    os.close(master)
    return rc

async def command(name, cmd, process):
    if cmd.strip() in ("sh", "/bin/sh"):
        cmd = (await process.stdin.read()).decode(errors="replace")
    if "===conterm:" in cmd or "put load" in cmd:
        # The sampler asks for `load`; the overview's collector for `hostname`.
        text = pulse(name) if "put load" in cmd and "put hostname" not in cmd else probe(name)
        process.stdout.write(text.encode())
        return 0
    proc = await asyncio.create_subprocess_exec(
        "/bin/sh", "-c", cmd, cwd=HOMES[name], env=env_for(name),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE)
    await process.redirect(stdin=proc.stdin, stdout=proc.stdout, stderr=proc.stderr)
    return await until_either(proc, process)

def handler(name):
    async def handle(process):
        try:
            rc = await (shell(name, process) if process.command is None
                        else command(name, process.command, process))
        except Exception as error:  # a broken session must not take the server down
            print(f"{name}: {error!r}", file=sys.stderr)
            rc = 1
        with contextlib.suppress(Exception):
            process.exit(rc or 0)
    return handle

class AnyLogin(asyncssh.SSHServer):
    def connection_made(self, conn):
        print(f"connect {conn.get_extra_info('sockname')[1]}", file=sys.stderr, flush=True)
    def begin_auth(self, username): return True
    def public_key_auth_supported(self): return True
    def validate_public_key(self, username, key): return True
    def password_auth_supported(self): return True
    def validate_password(self, username, password): return True

# ── the Mac on the network ───────────────────────────────────────────
def fingerprint(key):
    """As Conterm on iOS shows and compares it: SHA256 of the key blob,
    base64 without padding, the way ssh-keygen prints it."""
    blob = key.export_public_key("openssh").split()[1]
    digest = base64.b64encode(hashlib.sha256(base64.b64decode(blob)).digest()).decode()
    return "SHA256:" + digest.rstrip("=")

async def pairing(reader, writer, fp):
    print("pairing", file=sys.stderr, flush=True)
    with contextlib.suppress(Exception):
        await reader.readline()
        reply = {"ok": True, "user": USERS["studio"], "port": HOSTS["studio"], "lhost": "studio",
                 "sshOn": True, "hostKeys": [{"type": "ssh-ed25519", "fingerprint": fp}]}
        writer.write((json.dumps(reply) + "\n").encode())
        await writer.drain()
    writer.close()

async def main():
    os.makedirs(SHIMS, exist_ok=True)
    os.makedirs(HOMES["web-01"], exist_ok=True)
    # Whatever the phone runs beyond the collector, no real tool answers
    # about this Mac: these are empty.
    for tool in ("tmux", "who", "ps", "ifconfig", "hostname", "sw_vers", "docker", "last"):
        path = f"{SHIMS}/{tool}"
        with open(path, "w") as f: f.write("#!/bin/sh\nexit 0\n")
        os.chmod(path, 0o755)
    host_key = asyncssh.generate_private_key("ssh-ed25519")
    client_key = asyncssh.generate_private_key("ssh-ed25519", comment="conterm-demo")
    key_path = f"{RUN}/client_key"
    client_key.write_private_key(key_path, "openssh")
    client_key.write_public_key(key_path + ".pub", "openssh")
    os.chmod(key_path, 0o600)
    fp = fingerprint(host_key)

    servers = [await asyncssh.create_server(
        AnyLogin, "127.0.0.1", port, server_host_keys=[host_key],
        process_factory=handler(name), encoding=None, line_editor=False)
        for name, port in HOSTS.items()]
    pair = await asyncio.start_server(lambda r, w: pairing(r, w, fp), "127.0.0.1", PAIR_PORT)

    announce = [
        ["dns-sd", "-P", "web-01", "_ssh._tcp", "local", str(HOSTS["web-01"]), "web-01.local", "127.0.0.1"],
        ["dns-sd", "-P", "Studio Mac", "_conterm._tcp", "local", str(HOSTS["studio"]),
         "studio.local", "127.0.0.1", f"user={USERS['studio']}", "host=Studio Mac", "lhost=studio",
         "ssh=on", "version=7.1.1", f"pair={PAIR_PORT}"],
    ]
    children = [await asyncio.create_subprocess_exec(*a, stdout=asyncio.subprocess.DEVNULL,
                                                     stderr=asyncio.subprocess.DEVNULL) for a in announce]
    print(json.dumps({"fingerprint": fp, "key": key_path, "hosts": HOSTS, "pair": PAIR_PORT}), flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM): loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    for child in children:
        with contextlib.suppress(ProcessLookupError): child.terminate()
    for server in servers: server.close()
    pair.close()

if __name__ == "__main__":
    asyncio.run(main())
