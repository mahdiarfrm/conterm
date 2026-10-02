#!/usr/bin/env python3
"""Stand-ins for the tools and hosts a demo Conterm talks to.

Every command in the staged home's ~/.local/bin is a two-line wrapper
around this file, so the whole cast lives in one place:

  agent <claude|codex|opencode>   an agent session in a pane: its screen,
                                  the pill's escape sequences and, for
                                  Claude, a transcript the roster reads
  kubectl / helm / docker         canned cluster and runtime answers in the
                                  formats Conterm parses
  terraform / ansible-playbook    a plan and a run, the run feeding the
                                  Ansible cockpit through CONTERM_ANSIBLE_LOG
  host <name>                     the far side of `ssh <name>`: sshd's
                                  ForceCommand, answering the Host Overview
                                  collector or opening a shell

Names, hosts and addresses are made up; addresses are RFC 1918.
"""
import base64, fcntl, json, os, random, sys, time, uuid

HOME = os.environ.get("CONTERM_USER_HOME") or os.environ.get("HOME", "")
OUT = sys.stdout

# ── terminal helpers ─────────────────────────────────────────────────
def c(code, s): return f"\033[{code}m{s}\033[0m"
dim = lambda s: c("2", s)
bold = lambda s: c("1", s)
grey = lambda s: c("90", s)
green = lambda s: c("32", s)
red = lambda s: c("31", s)
yellow = lambda s: c("33", s)
blue = lambda s: c("34", s)
magenta = lambda s: c("35", s)
cyan = lambda s: c("36", s)
orange = lambda s: c("38;5;209", s)

def say(*lines, pause=0.0):
    for line in lines:
        OUT.write(line + "\n")
    OUT.flush()
    if pause: time.sleep(pause)

def forever():
    try:
        while True: time.sleep(3600)
    except KeyboardInterrupt:
        pass

# ── agent escape sequences ───────────────────────────────────────────
# libghostty passes on one desktop notification a second across the
# whole app, so every pane's sequences queue behind one shared clock.
_CLOCK = os.path.join(HOME, ".demo", "osc-clock")

def osc(body):
    os.makedirs(os.path.dirname(_CLOCK), exist_ok=True)
    with open(_CLOCK, "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        try: last = float(f.read().strip() or 0)
        except ValueError: last = 0
        wait = last + 1.25 - time.time()
        if wait > 0: time.sleep(wait)
        OUT.write(f"\033]9;conterm-agent:{body}\a"); OUT.flush()
        f.seek(0); f.truncate(); f.write(str(time.time()))

def excerpt(text):
    escaped = json.dumps(text)[1:-1]
    return base64.b64encode(escaped.encode()).decode()

def iso(t=None):
    t = time.time() if t is None else t
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + f".{int(t % 1 * 1000):03d}Z"

class Transcript:
    """A Claude Code session file, written the way the CLI writes it."""
    def __init__(self, cwd, branch, model="claude-opus-5-5"):
        slug = cwd.replace("/", "-").replace(".", "-")
        d = os.path.join(HOME, ".claude", "projects", slug)
        os.makedirs(d, exist_ok=True)
        self.path = os.path.join(d, f"{uuid.uuid4()}.jsonl")
        self.branch, self.model, self.n = branch, model, 0
        open(self.path, "w").close()

    def _w(self, obj):
        with open(self.path, "a") as f:
            f.write(json.dumps(obj) + "\n")

    def user(self, text):
        self._w({"type": "user", "gitBranch": self.branch, "timestamp": iso(),
                 "message": {"role": "user", "content": text}})

    def tool_use(self, tid, name, inp):
        self.n += 1
        self._w({"type": "assistant", "timestamp": iso(), "gitBranch": self.branch,
                 "message": {"id": f"msg_{uuid.uuid4().hex[:20]}", "model": self.model,
                             "role": "assistant",
                             "content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}],
                             "usage": {"input_tokens": random.randint(900, 2400),
                                       "output_tokens": random.randint(250, 900),
                                       "cache_creation_input_tokens": random.randint(1500, 4000),
                                       "cache_read_input_tokens": 30000 + self.n * 3800}}})

    def result(self, tid, text, error=False):
        self._w({"type": "user", "timestamp": iso(), "gitBranch": self.branch,
                 "message": {"role": "user", "content": [
                     {"type": "tool_result", "tool_use_id": tid, "content": text, "is_error": error}]}})

def tool_line(name, arg):
    return f"{c('37', '⏺')} {bold(name)}({arg})"

def boxed(rows, w):
    """rows: (plain text, styled text) pairs, padded on the plain width."""
    say(orange("╭" + "─" * w + "╮"))
    for plain, styled in rows:
        say(orange("│") + " " + styled + " " * max(0, w - 1 - len(plain)) + orange("│"))
    say(orange("╰" + "─" * w + "╯"))

def claude_header(cwd):
    short = cwd.replace(HOME, "~", 1)
    # Clear, and leave the top rows to the pane's own pills.
    OUT.write("\033[H\033[2J\n\n"); OUT.flush()
    boxed([("✻ Welcome to Claude Code!", orange("✻") + " Welcome to " + bold("Claude Code") + "!"),
           ("", ""), (f"  cwd: {short}", grey(f"  cwd: {short}"))], 50)
    say("")

def run_claude(scene):
    cwd = os.getcwd()
    s = SCENES[scene]
    t = Transcript(cwd, s["branch"])
    claude_header(cwd)
    say(grey("> ") + s["task"], "")
    t.user(s["task"])
    # One sequence opens the session; finished calls reach the History
    # capsule through the transcript, which the app polls, so only the
    # pill's state and the calls still in flight spend the shared clock.
    osc(f"claude:prompt:{t.path}")
    for name, arg, inp, result, shown in s["done"]:
        tid = f"toolu_{uuid.uuid4().hex[:24]}"
        t.tool_use(tid, name, inp)
        say(tool_line(name, arg))
        time.sleep(0.3)
        t.result(tid, result)
        say(grey("  ⎿  ") + shown, "")
    for line in s.get("said", []):
        say(c("37", "⏺ ") + line if line else "")
    say("")
    if s.get("ask"):
        name, arg, inp = s["ask"]
        tid = f"toolu_{uuid.uuid4().hex[:24]}"
        t.tool_use(tid, name, inp)
        boxed([("Bash command", bold("Bash command")), ("", ""),
               (f"  {inp['command']}", f"  {inp['command']}"),
               (f"  {s['ask_why']}", grey(f"  {s['ask_why']}")), ("", ""),
               ("Do you want to proceed?", "Do you want to proceed?"),
               ("❯ 1. Yes", cyan("❯ 1. Yes")),
               ("  2. Yes, and don't ask again for kubectl apply", "  2. Yes, and don't ask again for kubectl apply"),
               ("  3. No, and tell Claude what to do differently", grey("  3. No, and tell Claude what to do differently"))], 56)
        # "Needs you" lapses to ready after 30 s, and repeating it changes
        # nothing, so the wait is restated through a moment of work.
        osc(f"claude:attention:{t.path}")
        while True:
            time.sleep(20)
            osc(f"claude:prompt:{t.path}")
            osc(f"claude:attention:{t.path}")
    for name, arg, inp in s.get("running", []):
        tid = f"toolu_{uuid.uuid4().hex[:24]}"
        t.tool_use(tid, name, inp)
        osc(f"claude:tool:start:{tid}:{name}:{excerpt(inp.get('command') or arg)}")
        say(tool_line(name, arg))
    say("", orange("✻ ") + orange("Waiting on terraform and the rollout…") + grey("  (4m 12s · esc to interrupt)"))
    forever()

SCENES = {
    "api-gateway": {
        "branch": "feat/webhook-retries",
        "task": "Retry failed webhooks with backoff and roll it out to staging",
        "done": [
            ("Read", "internal/webhooks/deliver.go", {"file_path": "internal/webhooks/deliver.go"},
             "184 lines", "Read 184 lines"),
            ("Grep", 'pattern: "RetryPolicy"', {"pattern": "RetryPolicy"},
             "6 files", "Found 6 files"),
            ("Update", "internal/webhooks/deliver.go", {"file_path": "internal/webhooks/deliver.go"},
             "ok", f"Updated with {green('41 additions')} and {red('9 removals')}"),
            ("Bash", "go test ./internal/webhooks/...", {"command": "go test ./internal/webhooks/..."},
             "ok", green("ok") + "  api/internal/webhooks  1.284s"),
        ],
        "said": ["Backoff is in place: 30s, 2m, 10m, 1h, then the delivery is parked.",
                 "  Tests pass. Planning the queue change and watching the rollout."],
        "running": [
            ("Bash", "terraform plan -target=module.webhook_queue",
             {"command": "terraform plan -target=module.webhook_queue"}),
            ("Bash", "kubectl rollout status deploy/api -n api",
             {"command": "kubectl rollout status deploy/api -n api --context staging"}),
            ("Task", "Review the retry edge cases",
             {"description": "Review the retry edge cases", "prompt": "Review deliver.go retries"}),
        ],
    },
    "billing": {
        "branch": "fix/refund-idempotency",
        "task": "Make refunds idempotent and ship the manifest",
        "done": [
            ("Read", "internal/refunds/handler.go", {"file_path": "internal/refunds/handler.go"},
             "122 lines", "Read 122 lines"),
            ("Update", "internal/refunds/handler.go", {"file_path": "internal/refunds/handler.go"},
             "ok", f"Updated with {green('27 additions')} and {red('4 removals')}"),
            ("Bash", "go test ./internal/refunds/...", {"command": "go test ./internal/refunds/..."},
             "ok", green("ok") + "  billing/internal/refunds  0.611s"),
        ],
        "said": ["Refunds now take an Idempotency-Key and replay the first response."],
        "ask": ("Bash", "kubectl apply -f k8s/refunds.yaml", {"command": "kubectl apply -f k8s/refunds.yaml"}),
        "ask_why": "Apply the refunds deployment to prod-eu-1",
    },
}

def run_codex():
    say(bold("codex") + grey("  ·  gpt-5.5-codex  ·  ~/code/docs"), "",
        grey("› ") + "Regenerate the API reference from the OpenAPI spec", "",
        cyan("•") + " Reading openapi.yaml", cyan("•") + " Rendering 42 endpoints into docs/reference", "",
        magenta("◦ Working") + grey(" (38s · esc to interrupt)"))
    osc("codex:working:")
    forever()

def run_opencode():
    say(bold("opencode") + grey("  ·  ~/code/docs/site"), "", grey("Ask anything…"))
    osc("opencode:start:")
    forever()

# ── kubectl / helm / docker ──────────────────────────────────────────
PODS = [
    ("api", "api-7d9f6c5b8-2kq4x", "1/1", "Running", "0", "3h12m"),
    ("api", "api-7d9f6c5b8-8vt7n", "1/1", "Running", "0", "3h12m"),
    ("api", "api-7d9f6c5b8-x9m2p", "1/1", "Running", "0", "3h11m"),
    ("hooks", "webhooks-5b6c8d9f7-l2wq8", "1/1", "Running", "1", "2d4h"),
    ("billing", "refunds-6c7f9b4d5-qq8tr", "1/1", "Running", "0", "6h40m"),
    ("billing", "ledger-0", "1/1", "Running", "0", "12d"),
    ("worker", "worker-5c4d8b7f9-hq2lz", "1/1", "Running", "0", "1d2h"),
    ("worker", "worker-5c4d8b7f9-p7r2c", "0/1", "CrashLoopBackOff", "7", "1d2h"),
    ("worker", "cron-digest-29071440-5wz9q", "0/1", "Completed", "0", "41m"),
    ("monitoring", "prometheus-0", "2/2", "Running", "0", "12d"),
    ("monitoring", "grafana-7f8d9c6b5-mm4xs", "1/1", "Running", "0", "12d"),
    ("kube-system", "coredns-5d78c9869d-7kq2v", "1/1", "Running", "0", "34d"),
    ("kube-system", "coredns-5d78c9869d-xw8bn", "1/1", "Running", "0", "34d"),
    ("ingress", "ingress-nginx-controller-6b8f-7tnq2", "1/1", "Running", "0", "34d"),
]
DEPLOYS = [("api", "api", "3/3"), ("api", "webhooks", "1/1"), ("billing", "refunds", "1/1"),
           ("worker", "worker", "1/2"), ("monitoring", "grafana", "1/1"),
           ("kube-system", "coredns", "2/2"), ("ingress", "ingress-nginx-controller", "1/1")]
NODES = [("node-eu1-a", "Ready", "control-plane", "34d", "v1.33.2", 38, 61),
         ("node-eu1-b", "Ready", "<none>", "34d", "v1.33.2", 64, 72),
         ("node-eu1-c", "Ready", "<none>", "12d", "v1.33.2", 21, 44)]

def table(rows, header=None, also=()):
    """kubectl's layout: each column as wide as its longest cell plus three.
    `also` widens columns for rows a watch prints later."""
    allrows = ([header] if header else []) + list(rows)
    sized = allrows + list(also)
    widths = [max(len(str(r[i])) for r in sized) + 3 for i in range(len(sized[0]))]
    for r in allrows:
        print("".join(str(v).ljust(w) for v, w in zip(r, widths)).rstrip())
    return widths

def kubectl(args):
    a = [x for x in args if not x.startswith("--request-timeout")]
    if "--context" in a:
        i = a.index("--context"); del a[i:i + 2]
    allns = "-A" in a or "--all-namespaces" in a
    a = [x for x in a if x not in ("-A", "--all-namespaces")]
    watch = "-w" in a
    a = [x for x in a if x != "-w"]
    ns = None
    if "-n" in a:
        i = a.index("-n"); ns = a[i + 1]; del a[i:i + 2]
    headers = "--no-headers" not in a
    a = [x for x in a if x != "--no-headers"]
    custom = next((x for x in a if x.startswith("custom-columns=")), None)
    verb, what = (a + ["", ""])[:2]

    if verb == "config" and what == "current-context":
        print("prod-eu-1"); return
    if verb == "get" and what in ("pods", "pod", "po"):
        rows = [p for p in PODS if allns or p[0] == (ns or "default")]
        if custom:
            for p in rows:
                phase = "Succeeded" if p[3] == "Completed" else "Running"
                print(f"{p[0]}   {p[1]}   {phase}")
            return
        head = ("NAMESPACE", "NAME", "READY", "STATUS", "RESTARTS", "AGE")
        if allns:
            table(rows, head if headers else None)
        else:
            later = [("api-7d9f6c5b8-x9m2p", "1/1", "Terminating", "0", "3h12m"),
                     ("api-6c8b7d9f4-r4tqz", "0/1", "Pending", "0", "0s"),
                     ("api-6c8b7d9f4-r4tqz", "0/1", "ContainerCreating", "0", "1s"),
                     ("api-6c8b7d9f4-r4tqz", "1/1", "Running", "0", "9s")]
            widths = table([p[1:] for p in rows], head[1:] if headers else None,
                           also=later if watch else ())
            if watch:
                sys.stdout.flush()
                time.sleep(3)
                for r in later:
                    print("".join(str(v).ljust(w) for v, w in zip(r, widths)).rstrip())
                    sys.stdout.flush(); time.sleep(2.5)
                forever()
        return
    if verb == "get" and what in ("deployments", "deploy"):
        for d in DEPLOYS:
            print(f"{d[0]:<14}{d[1]:<28}{d[2]:<8}{d[2].split('/')[0]:<12}{d[2].split('/')[0]:<11}34d")
        return
    if verb == "get" and what in ("nodes", "node", "no"):
        if custom:
            for n in NODES: print(f"{n[0]}   Ready")
            return
        if headers: print("NAME          STATUS   ROLES           AGE   VERSION")
        table([n[:5] for n in NODES], [14, 9, 16, 6, 9])
        return
    if verb == "top" and what in ("nodes", "node"):
        for n in NODES:
            print(f"{n[0]:<14}{n[5] * 40}m{'':<6}{n[5]}%{'':<5}{n[6] * 160}Mi{'':<6}{n[6]}%")
        return
    if verb == "get" and what in ("services", "svc"):
        for s in [("api", "api", "ClusterIP", "10.96.12.40", "<none>", "80/TCP,9090/TCP", "34d"),
                  ("api", "webhooks", "ClusterIP", "10.96.12.77", "<none>", "8080/TCP", "34d"),
                  ("billing", "refunds", "ClusterIP", "10.96.31.9", "<none>", "8080/TCP", "6h"),
                  ("ingress", "ingress-nginx", "LoadBalancer", "10.96.0.15", "10.0.0.80", "80:30080/TCP,443:30443/TCP", "34d"),
                  ("monitoring", "grafana", "ClusterIP", "10.96.40.2", "<none>", "3000/TCP", "12d")]:
            print("   ".join(s))
        return
    if verb == "get" and what in ("events", "ev"):
        print("worker   2m    Warning   BackOff            pod/worker-5c4d8b7f9-p7r2c   Back-off restarting failed container worker")
        print("worker   9m    Warning   Unhealthy          pod/worker-5c4d8b7f9-p7r2c   Liveness probe failed: HTTP probe failed with statuscode: 503")
        print("api      14m   Warning   FailedScheduling   pod/api-6c8b7d9f4-r4tqz      0/3 nodes are available: 3 Insufficient memory")
        return
    if verb == "rollout" and what == "status":
        print('Waiting for deployment "api" rollout to finish: 2 of 3 updated replicas are available...')
        forever(); return
    sys.exit(0)

def helm(args):
    if "list" in args and "json" in args:
        print(json.dumps([
            {"name": "ingress-nginx", "namespace": "ingress", "revision": "7", "status": "deployed", "chart": "ingress-nginx-4.11.2"},
            {"name": "kube-prometheus", "namespace": "monitoring", "revision": "12", "status": "deployed", "chart": "kube-prometheus-stack-65.1.0"},
            {"name": "api", "namespace": "api", "revision": "41", "status": "deployed", "chart": "api-2.8.1"},
            {"name": "worker", "namespace": "worker", "revision": "18", "status": "failed", "chart": "worker-1.9.0"}]))

def docker(args):
    if args[:1] == ["ps"]:
        for r in [("api-gateway-dev", "ghcr.io/acme/api:dev", "Up 2 hours"),
                  ("postgres", "postgres:17", "Up 2 hours (healthy)"),
                  ("redis", "redis:7.4-alpine", "Up 2 hours"),
                  ("localstack", "localstack/localstack:4", "Up 41 minutes"),
                  ("mailpit", "axllent/mailpit", "Exited (0) 3 hours ago")]:
            print("\t".join(r))

def claude_cli(args):
    if args[:2] == ["agents", "--json"]:
        print(json.dumps([{"kind": "background", "sessionId": "5f0c9e4e-7a1b-4c1e-9d55-2b8f1d6a0c3e",
                           "id": "bg-7k2q", "name": "Bump Go dependencies and fix what breaks",
                           "cwd": os.path.join(HOME, "code", "worker"), "state": "running"}]))
        return
    run_claude(os.path.basename(os.getcwd()))

# ── terraform / ansible ──────────────────────────────────────────────
def terraform(args):
    if args[:1] != ["plan"]: return
    say(grey("module.webhook_queue.aws_sqs_queue.dlq: Refreshing state... [id=https://sqs.eu-west-1.amazonaws.com/000000000000/webhooks-dlq]"),
        grey("module.webhook_queue.aws_sqs_queue.main: Refreshing state... [id=https://sqs.eu-west-1.amazonaws.com/000000000000/webhooks]"),
        "", "Terraform will perform the following actions:", "",
        bold("  # module.webhook_queue.aws_sqs_queue.main") + " will be updated in-place",
        yellow("  ~") + ' resource "aws_sqs_queue" "main" {',
        yellow("      ~") + " visibility_timeout_seconds = 30 " + yellow("->") + " 120",
        yellow("      ~") + " redrive_policy             = jsonencode(" + yellow("# whitespace changes") + ")",
        "        # (14 unchanged attributes hidden)", "    }", "",
        bold("  # module.webhook_queue.aws_cloudwatch_metric_alarm.dlq_depth") + " will be created",
        green("  +") + ' resource "aws_cloudwatch_metric_alarm" "dlq_depth" {',
        green("      +") + ' alarm_name          = "webhooks-dlq-depth"',
        green("      +") + " threshold           = 25", "    }", "",
        bold("  # module.webhook_queue.aws_lambda_function.replayer") + " must be " + red("replaced"),
        red("-/+") + ' resource "aws_lambda_function" "replayer" {',
        red("      ~") + ' runtime = "go1.x" ' + red("->") + ' "provided.al2023" ' + red("# forces replacement"),
        "    }", "",
        bold("Plan:") + " 1 to add, 1 to change, 1 to destroy.")
    forever()

def ansible_playbook(args):
    feed = os.environ.get("CONTERM_ANSIBLE_LOG")
    def emit(**o):
        if feed:
            o["ts"] = time.time()
            with open(feed, "a") as f: f.write(json.dumps(o) + "\n")
    hosts = ["web-01", "web-02", "web-03", "db-01"]
    tasks = [("Gathering Facts", {}),
             ("common : apt dist-upgrade", {"web-02": "changed", "web-03": "changed"}),
             ("nginx : render site config", {"web-01": "changed", "web-02": "changed", "web-03": "changed", "db-01": "skipped"}),
             ("app : pull api image v2.8.1", {"db-01": "skipped"}),
             ("app : run database migrations", {"web-01": "changed", "web-02": "skipped", "web-03": "skipped"}),
             ("app : restart api", {"web-01": "changed", "web-02": "changed", "web-03": "failed", "db-01": "skipped"}),
             ("app : wait for /healthz", {"web-03": "skip-failed", "db-01": "skipped"}),
             ("monitoring : node exporter", {})]
    emit(e="playbook", name="deploy.yml")
    say("", bold("PLAY [Deploy api v2.8.1] ") + "*" * 52)
    emit(e="play", name="Deploy api v2.8.1")
    failed = set()
    for name, outcome in tasks:
        time.sleep(1.4)
        emit(e="task", name=name)
        say("", bold(f"TASK [{name}] ") + "*" * max(4, 68 - len(name)))
        for h in hosts:
            if h in failed: continue
            r = outcome.get(h, "ok")
            if r == "skip-failed": continue
            time.sleep(0.25)
            if r == "failed":
                failed.add(h)
                msg = "Unable to restart service api: Job for api.service failed because the control process exited with error code."
                emit(e="failed", host=h, task=name, msg=msg)
                say(red(f'fatal: [{h}]: FAILED! => {{"changed": false, "msg": "{msg}"}}'))
            elif r == "skipped":
                emit(e="skipped", host=h, task=name)
                say(cyan(f"skipping: [{h}]"))
            else:
                emit(e="ok", host=h, task=name, changed=(r == "changed"))
                say(yellow(f"changed: [{h}]") if r == "changed" else green(f"ok: [{h}]"))
    emit(e="stats", hosts={})
    say("", bold("PLAY RECAP ") + "*" * 66,
        green("web-01") + "                     : " + green("ok=8") + "    " + yellow("changed=4") + "    unreachable=0    failed=0",
        green("web-02") + "                     : " + green("ok=7") + "    " + yellow("changed=3") + "    unreachable=0    failed=0",
        red("web-03") + "                     : " + green("ok=5") + "    " + yellow("changed=2") + "    unreachable=0    " + red("failed=1"),
        green("db-01") + "                      : " + green("ok=4") + "    changed=0    unreachable=0    failed=0", "")

# ── hosts behind sshd ────────────────────────────────────────────────
HOSTS = {
    "web-01": dict(os="Ubuntu 24.04.1 LTS", kernel="Linux 6.8.0-45-generic", ip="10.0.1.21", up="41 days,  2:11",
                   load="0.64 0.58 0.51 2/311 88213", cores=4, mem=(7951, 3320), disks=[("/dev/nvme0n1p1", 81_000_000, 65_600_000, "/"), ("/dev/nvme1n1", 200_000_000, 61_000_000, "/var/lib/docker")],
                   containers=[("nginx", "nginx:1.27", "Up 41 days"), ("api", "ghcr.io/acme/api:2.8.1", "Up 3 hours"),
                               ("webhooks", "ghcr.io/acme/webhooks:2.8.1", "Up 3 hours"), ("node-exporter", "prom/node-exporter:v1.8.2", "Up 41 days"),
                               ("api-canary", "ghcr.io/acme/api:2.9.0-rc1", "Exited (1) 2 hours ago")],
                   failed=[], updates="12 updates can be applied immediately.", reboot=False,
                   journal=["Oct 02 09:14:07 web-01 api[88120]: level=error msg=\"upstream timeout\" route=/v1/refunds",
                            "Oct 02 08:51:33 web-01 kernel: nvme nvme1: I/O 412 QID 3 timeout, completion polled"]),
    "web-02": dict(os="Ubuntu 24.04.1 LTS", kernel="Linux 6.8.0-45-generic", ip="10.0.1.22", up="41 days,  2:09",
                   load="0.41 0.39 0.40 1/298 77102", cores=4, mem=(7951, 4410), disks=[("/dev/nvme0n1p1", 81_000_000, 41_000_000, "/")],
                   containers=[("nginx", "nginx:1.27", "Up 41 days"), ("api", "ghcr.io/acme/api:2.8.1", "Up 3 hours")],
                   failed=[], updates=None, reboot=False, journal=[]),
    "web-03": dict(os="Ubuntu 24.04.1 LTS", kernel="Linux 6.8.0-45-generic", ip="10.0.1.23", up="12 days,  6:40",
                   load="3.12 2.80 2.41 6/330 99120", cores=4, mem=(7951, 910), disks=[("/dev/nvme0n1p1", 81_000_000, 74_000_000, "/")],
                   containers=[("nginx", "nginx:1.27", "Up 12 days"), ("api", "ghcr.io/acme/api:2.8.1", "Restarting (1) 8 seconds ago")],
                   failed=["api.service"], updates="3 updates can be applied immediately.", reboot=True,
                   journal=["Oct 02 09:20:41 web-03 systemd[1]: api.service: Main process exited, code=exited, status=1/FAILURE",
                            "Oct 02 09:20:41 web-03 api[99101]: panic: dial tcp 10.0.2.10:5432: connect: connection refused"]),
    "db-01": dict(os="Debian GNU/Linux 12 (bookworm)", kernel="Linux 6.1.0-25-amd64", ip="10.0.2.10", up="88 days,  4:02",
                  load="1.10 1.24 1.19 3/240 41870", cores=8, mem=(31890, 9120), disks=[("/dev/sda1", 40_000_000, 18_000_000, "/"), ("/dev/sdb1", 500_000_000, 441_000_000, "/var/lib/postgresql")],
                  containers=[], failed=["pg-backup.service"], updates=None, reboot=False,
                  journal=["Oct 02 03:00:12 db-01 pg-backup[3301]: upload failed: storage quota exceeded"]),
    "bastion": dict(os="Alpine Linux v3.20", kernel="Linux 6.6.52-0-virt", ip="10.0.0.5", up="203 days,  1:15",
                    load="0.02 0.03 0.00 1/61 2210", cores=1, mem=(984, 610), disks=[("/dev/vda3", 9_000_000, 2_100_000, "/")],
                    containers=[], failed=[], updates=None, reboot=False, journal=[]),
}

def probe(name):
    h = HOSTS[name]
    out = []
    def put(k, *lines):
        out.append(f"\n===conterm:{k}===")
        out.extend(lines)
    put("hostname", name); put("fqdn", f"{name}.eu1.internal"); put("os", h["os"])
    put("kernel", h["kernel"]); put("arch", "x86_64")
    put("uptime", f" 09:24:51 up {h['up']},  1 user,  load average: {', '.join(h['load'].split()[:3])}")
    put("loadavg", h["load"]); put("cores", str(h["cores"]))
    tot, avail = h["mem"]
    put("mem", "               total        used        free      shared  buff/cache   available",
        f"Mem:           {tot}        {tot - avail}         {avail // 3}          41        {avail // 2}        {avail}")
    put("disk", *[f"{d}  {t}  {u}  {t - u}  {u * 100 // t}%  {m}" for d, t, u, m in h["disks"]])
    put("ips", f"{h['ip']} 172.17.0.1" if h["containers"] else h["ip"])
    put("runtime", "docker" if h["containers"] else "")
    put("containers", *["\t".join(r) for r in h["containers"]])
    put("vms"); put("kubelet", "inactive"); put("kubenodes")
    put("timers", "Thu 2026-10-02 12:00:00 UTC 2h 35min left Thu 2026-10-02 00:00:00 UTC 9h ago logrotate.timer logrotate.service",
        "Fri 2026-10-03 03:00:00 UTC 17h left Thu 2026-10-02 03:00:00 UTC 6h ago apt-daily-upgrade.timer apt-daily-upgrade.service")
    put("cron", "3"); put("failed", str(len(h["failed"]))); put("failedlist", *h["failed"])
    put("users", "1"); put("reboot", "yes" if h["reboot"] else "")
    put("procs", "api              38.2  6.1", "nginx             4.1  0.8", "dockerd           2.0  1.9",
        "node_exporter     0.6  0.3", "sshd              0.1  0.1")
    put("ports", "0.0.0.0:22", "0.0.0.0:80", "0.0.0.0:443", "127.0.0.1:9100")
    put("journal", *h["journal"]); put("kernlog")
    put("lastlog", "deploy   pts/0        10.0.0.5         Thu Oct  2 09:24   still logged in",
        "deploy   pts/1        10.0.0.5         Wed Oct  1 17:02 - 18:44  (01:42)")
    if h["updates"]: put("updates", h["updates"])
    else: put("updates")
    put("end")
    print("\n".join(out))

def host(name):
    cmd = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    if cmd.strip() == "sh":
        sys.stdin.read()
        probe(name); return
    if cmd:
        # Remote commands (docker, virsh, routine steps) get a plain answer.
        if cmd.startswith("docker") or "docker" in cmd:
            for r in HOSTS[name]["containers"]: print("\t".join(r))
        return
    h = HOSTS[name]
    print(f"Welcome to {h['os']}\n")
    print(f"  System load:   {h['load'].split()[0]}")
    print(f"  Usage of /:    {h['disks'][0][2] * 100 // h['disks'][0][1]}% of 77.2GB")
    print(f"  Memory usage:  {(h['mem'][0] - h['mem'][1]) * 100 // h['mem'][0]}%")
    print(f"  IPv4 address:  {h['ip']}\n")
    if h["updates"]: print(f"{h['updates']}\n")
    print("Last login: Thu Oct  2 08:12:44 2026 from 10.0.0.5")
    sys.stdout.flush()
    home = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hosts", name)
    os.makedirs(home, exist_ok=True)
    rc = os.path.join(home, ".zshrc")
    with open(rc, "w") as f:
        f.write(f"PROMPT='%F{{green}}deploy@{name}%f:%F{{blue}}%~%f$ '\nHISTFILE=/dev/null\ncd ~\n")
    os.execve("/bin/zsh", ["-zsh", "-i"], {"HOME": home, "ZDOTDIR": home, "TERM": os.environ.get("TERM", "xterm-256color"),
                                            "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"})

# ── entry ────────────────────────────────────────────────────────────
def main():
    if len(sys.argv) < 2: sys.exit(2)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "agent":
        who = args[0] if args else "claude"
        {"claude": lambda: claude_cli(args[1:]), "codex": run_codex, "opencode": run_opencode}[who]()
    elif cmd == "kubectl": kubectl(args)
    elif cmd == "helm": helm(args)
    elif cmd == "docker": docker(args)
    elif cmd == "terraform": terraform(args)
    elif cmd == "ansible-playbook": ansible_playbook(args)
    elif cmd == "host": host(args[0])

if __name__ == "__main__":
    try: main()
    except (KeyboardInterrupt, BrokenPipeError): pass
