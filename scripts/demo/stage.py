#!/usr/bin/env python3
"""Build the demo's user home and state home from scratch.

  /Users/Shared/conterm-demo/home    the user's files: shell, ssh, kube,
                                     repos, the stand-in tools
  /Users/Shared/conterm-demo/state   the instance's own state: session
                                     layout, preferences, cards to open

Nothing of the real home's content comes across. Its look may: with
DEMO_LOOK=own (the default) the runner's Conterm config — fonts, colours,
opacity, with anything that would size the window or change what runs
stripped — and an allowlist of appearance preferences are copied in.
DEMO_LOOK=plain stages Conterm's defaults instead. Run by screenshots.sh
before every shot so each one starts from the same place.
"""
import json, os, plistlib, shutil, subprocess, sys, tempfile, time, uuid

ROOT = "/Users/Shared/conterm-demo"
HOME = f"{ROOT}/home"
STATE = f"{ROOT}/state"
KIT = os.path.dirname(os.path.abspath(__file__))
SSHD = "/opt/homebrew/opt/openssh/sbin/sshd"
NOW = time.time()
APPLE_EPOCH = 978307200  # Foundation dates count from 2001-01-01

REAL_HOME = os.path.expanduser("~")
REAL_DOMAIN = "app.conterm.Conterm"
# Config keys that would size or place the window, or change what a pane
# runs; the demo decides those.
STRIP_KEYS = {"config-file", "maximize", "window-width", "window-height",
              "window-save-state", "window-position-x", "window-position-y",
              "shell-integration", "shell-integration-features", "command",
              "initial-command", "working-directory", "initial-window"}
# Appearance only — never a key that holds hosts, paths, history or state.
LOOK_PREFS = ["actionAccent", "agentPillLite", "autoGlass", "coolGlass", "glassiness",
              "glassMode", "glassStyle", "interfaceStyle", "lightGlass", "liquidGlass",
              "liquidGlassOverlays", "liquidGlassPanels", "lowPowerGlass", "newTabAccent",
              "paneBackgroundBlur", "paneCornerRadius", "paneFrostiness", "redActionBar",
              "showLayoutSwitcher", "showPaneTitleBar", "statsShowCPU", "statsShowMemory",
              "statsShowNetwork", "themeFromConfig", "uiScale", "useLegacyGlass",
              "windowOpacity", "clock24Hour", "clockShowDate", "clockShowSeconds", "sidebarWidth"]

HOSTS = {"web-01": "10.0.1.21", "web-02": "10.0.1.22", "web-03": "10.0.1.23",
         "db-01": "10.0.2.10", "bastion": "10.0.0.5"}

def run(*cmd, cwd=None, env=None):
    subprocess.run(cmd, cwd=cwd, check=True, env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def write(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f: f.write(text)
    if mode: os.chmod(path, mode)

def suite_name(home):
    # InstanceState.suiteName(for:)
    return "app.conterm.instance" + home.replace("/", "-")

# ── user home ────────────────────────────────────────────────────────
def repo(path, branch, files, commits, dirty):
    """A git repo with history and uncommitted work, for Review Changes."""
    env = {**os.environ, "GIT_AUTHOR_NAME": "Sam Rivera", "GIT_AUTHOR_EMAIL": "sam@example.com",
           "GIT_COMMITTER_NAME": "Sam Rivera", "GIT_COMMITTER_EMAIL": "sam@example.com",
           "HOME": HOME, "GIT_CONFIG_NOSYSTEM": "1"}
    os.makedirs(path, exist_ok=True)
    run("git", "init", "-q", "-b", "main", cwd=path, env=env)
    # The kit's own marker stays out of the work under review.
    write(f"{path}/.git/info/exclude", ".demo-run\n")
    for name, text in files.items(): write(f"{path}/{name}", text)
    run("git", "add", "-A", cwd=path, env=env)
    run("git", "commit", "-q", "-m", "initial import", cwd=path, env=env)
    run("git", "checkout", "-q", "-b", branch, cwd=path, env=env)
    for msg, changes in commits:
        for name, text in changes.items(): write(f"{path}/{name}", text)
        run("git", "add", "-A", cwd=path, env=env)
        run("git", "commit", "-q", "-m", msg, cwd=path, env=env)
    for name, text in dirty.items(): write(f"{path}/{name}", text)

def go(lines):
    return "package webhooks\n\n" + "\n".join(lines) + "\n"

def stage_home():
    shutil.copytree(f"{KIT}/home", HOME, symlinks=True)

    # Each pane's directory says what runs in it (see .zshrc).
    runs = {
        "code/api-gateway": "claude",
        "k8s": "kubectl get pods -n api -w",
        "code/billing": "claude",
        "code/docs": "codex",
        "code/docs/site": "opencode",
        "ops/web-01": "ssh web-01",
        "infra/ansible": "ansible-playbook -i inventory/prod deploy.yml",
        "infra/terraform": "terraform plan",
    }
    base = [f"func attempt{i}() error {{ return nil }}" for i in range(40)]
    repo(f"{HOME}/code/api-gateway", "feat/webhook-retries",
         {"go.mod": "module github.com/acme/api\n\ngo 1.23\n",
          "internal/webhooks/deliver.go": go(base),
          "internal/webhooks/policy.go": go(["type RetryPolicy struct{ Max int }"]),
          "deploy/api.yaml": "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: api\n",
          "README.md": "# api-gateway\n"},
         [("webhooks: retry with exponential backoff",
           {"internal/webhooks/deliver.go": go(base + [f"func backoff{i}() int {{ return {i} }}" for i in range(30)])}),
          ("webhooks: park deliveries after the last attempt",
           {"internal/webhooks/policy.go": go(["type RetryPolicy struct{ Max int; Park bool }"] + [f"// step {i}" for i in range(12)])})],
         {"internal/webhooks/deliver_test.go": go([f"func TestBackoff{i}(t *testing.T) {{}}" for i in range(24)]),
          "deploy/api.yaml": "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: api\nspec:\n  replicas: 3\n",
          "internal/webhooks/deliver.go": go(base[:30] + [f"func backoff{i}() int {{ return {i * 2} }}" for i in range(36)])})
    repo(f"{HOME}/code/billing", "fix/refund-idempotency",
         {"go.mod": "module github.com/acme/billing\n", "internal/refunds/handler.go": go(base[:20])},
         [], {"internal/refunds/handler.go": go(base[:20] + ["// Idempotency-Key replays the first response"] * 8),
              "k8s/refunds.yaml": "kind: Deployment\n"})
    repo(f"{HOME}/code/docs", "docs/api-reference", {"README.md": "# docs\n"}, [], {})
    repo(f"{HOME}/code/worker", "chore/deps", {"go.mod": "module github.com/acme/worker\n"}, [], {})
    write(f"{HOME}/infra/ansible/deploy.yml", "- hosts: web\n  roles: [common, nginx, app]\n")
    write(f"{HOME}/infra/ansible/inventory/prod", "[web]\nweb-0[1:3]\n[db]\ndb-01\n")
    write(f"{HOME}/infra/terraform/main.tf", 'module "webhook_queue" { source = "./modules/queue" }\n')
    for d, cmd in runs.items(): write(f"{HOME}/{d}/.demo-run", cmd + "\n")

    # ssh: a key, and one inetd-mode sshd per host behind ProxyCommand.
    os.makedirs(f"{HOME}/.ssh", mode=0o700, exist_ok=True)
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "sam@studio", "-f", f"{HOME}/.ssh/id_ed25519")
    sd = f"{HOME}/.demo/sshd"
    os.makedirs(sd, exist_ok=True)
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", f"{sd}/host_key")
    shutil.copy(f"{HOME}/.ssh/id_ed25519.pub", f"{sd}/authorized_keys")
    player = f"{HOME}/.local/share/conterm-demo/demo.py"
    cfg = []
    for name, ip in HOSTS.items():
        write(f"{sd}/{name}.conf", "\n".join([
            f"HostKey {sd}/host_key", f"AuthorizedKeysFile {sd}/authorized_keys",
            "StrictModes no", "UsePAM no", "PasswordAuthentication no",
            "KbdInteractiveAuthentication no", "PidFile none", "PrintMotd no", "PrintLastLog no",
            f"ForceCommand /usr/bin/python3 {player} host {name}", ""]))
        cfg += [f"Host {name}", f"  HostName {ip}", f"  ProxyCommand {SSHD} -i -f {sd}/{name}.conf", ""]
    cfg += ["Host web-07", "  HostName 10.0.1.27", "  ProxyCommand /usr/bin/false", "",
            "Host *", f"  IdentityFile {HOME}/.ssh/id_ed25519", "  IdentitiesOnly yes",
            f"  UserKnownHostsFile {HOME}/.ssh/known_hosts", "  StrictHostKeyChecking accept-new",
            "  LogLevel ERROR", ""]
    write(f"{HOME}/.ssh/config", "\n".join(cfg), 0o600)

    # History: what the palette offers and where Orbit finds hosts.
    hist = ["git switch -c feat/webhook-retries", "go test ./...", "ssh web-01", "kubectl get pods -n api",
            "ssh db-01", "terraform plan", "ssh web-03", "kubectl logs deploy/worker -n worker --tail 50",
            "ssh bastion", "ansible-playbook -i inventory/prod deploy.yml --check", "ssh web-02",
            "helm upgrade api charts/api -n api --set image.tag=2.8.1", "ssh web-07",
            "docker compose up -d postgres redis", "gh pr checks", "make test", "ssh web-01"]
    lines = [f": {int(NOW - (len(hist) - i) * 540)}:0;{cmd}" for i, cmd in enumerate(hist)]
    write(f"{HOME}/.zsh_history", "\n".join(lines) + "\n")

    write(f"{HOME}/.kube/config", """apiVersion: v1
kind: Config
current-context: staging
clusters:
- name: prod-eu-1
  cluster: {server: "https://10.0.0.10:6443"}
- name: staging
  cluster: {server: "https://10.0.8.10:6443"}
contexts:
- name: prod-eu-1
  context: {cluster: prod-eu-1, user: sam, namespace: api}
- name: staging
  context: {cluster: staging, user: sam, namespace: api}
users:
- name: sam
  user: {token: demo}
""")

# ── state home ───────────────────────────────────────────────────────
def leaf(rel): return {"kind": "leaf", "cwd": f"{HOME}/{rel}"}
def split(axis, frac, a, b): return {"kind": "split", "axis": axis, "fraction": frac, "first": a, "second": b}
def tab(title, tree, active=0):
    return {"title": title, "customTitle": True, "indexLabel": title, "tree": tree, "activePaneIndex": active}

def own_config():
    """The runner's Conterm config with its includes inlined, includes
    first (they apply before the file's own lines), minus STRIP_KEYS."""
    def lines(path, depth):
        if not os.path.isfile(path) or depth > 3: return []
        here, includes, own = os.path.dirname(path), [], []
        for raw in open(path, encoding="utf-8", errors="replace"):
            line = raw.rstrip("\n")
            key, _, value = line.partition("=")
            key = key.strip()
            if key == "config-file":
                inc = os.path.expanduser(value.strip().strip('"').lstrip("?"))
                includes += lines(inc if os.path.isabs(inc) else os.path.join(here, inc), depth + 1)
            elif key not in STRIP_KEYS:
                own.append(line)
        return includes + own
    return lines(f"{REAL_HOME}/.config/conterm/config", 0)

def own_look_prefs():
    out = subprocess.run(["defaults", "export", REAL_DOMAIN, "-"], capture_output=True)
    if out.returncode != 0: return {}
    real = plistlib.loads(out.stdout)
    return {f"conterm.{k}": real[f"conterm.{k}"] for k in LOOK_PREFS if f"conterm.{k}" in real}

def stage_state(width, height, own_look):
    write(f"{STATE}/.conterm-instance-seeded", "")
    cfg = f"{STATE}/.config/conterm"
    base = own_config() if own_look else []
    write(f"{cfg}/config", "\n".join(base or ["font-size = 13", "window-padding-x = 10",
                                               "window-padding-y = 8"]) + "\n")
    snap = {"stateHome": STATE, "windows": [{
        "frame": f"{{{{90, 140}}, {{{width}, {height}}}}}", "selectedIndex": 0,
        "tabs": [
            tab("api-gateway", split("horizontal", 0.52, leaf("code/api-gateway"),
                                     split("vertical", 0.5, leaf("k8s"), leaf("ops/web-01")))),
            tab("billing", leaf("code/billing")),
            tab("infra", split("horizontal", 0.5, leaf("infra/ansible"), leaf("infra/terraform"))),
            tab("docs", split("horizontal", 0.55, leaf("code/docs"), leaf("code/docs/site"))),
        ]}]}
    write(f"{cfg}/sessions.json", json.dumps(snap))

    plan = {"dir": f"{HOME}/infra/terraform", "command": "terraform plan", "terraformVersion": "1.9.7",
            "createdAt": NOW - APPLE_EPOCH - 240, "outputsChanged": ["queue_url"],
            "resources": [
                {"address": "module.webhook_queue.aws_lambda_function.replayer", "type": "aws_lambda_function",
                 "action": "replace", "changed": [{"name": "runtime", "before": "go1.x", "after": "provided.al2023"}]},
                {"address": "module.webhook_queue.aws_sqs_queue.legacy", "type": "aws_sqs_queue",
                 "action": "destroy", "changed": []},
                {"address": "module.webhook_queue.aws_cloudwatch_metric_alarm.dlq_depth", "type": "aws_cloudwatch_metric_alarm",
                 "action": "create", "changed": []},
                {"address": "module.webhook_queue.aws_sqs_queue.main", "type": "aws_sqs_queue", "action": "update",
                 "changed": [{"name": "visibility_timeout_seconds", "before": "30", "after": "120"},
                             {"name": "message_retention_seconds", "before": "345600", "after": "1209600"}]}]}
    write(f"{cfg}/terraform-last-plan.json", json.dumps(plan))

    events = [("agent", "Claude finished in billing", "Refund handler tests pass", 150),
              ("run", "deploy.yml failed on web-03", "app : restart api — 1 of 4 hosts failed", 118),
              ("alert", "worker is crash-looping", "prod-eu-1 · worker-5c4d8b7f9-p7r2c restarted 7 times", 95),
              ("plan", "terraform plan: 1 to destroy", "infra/terraform — replaces the replayer lambda", 61),
              ("command", "make release failed", "exit 2 after 4m 10s in code/worker", 40),
              ("agent", "Claude needs you in billing", "Approve kubectl apply on prod-eu-1", 12)]
    with open(f"{cfg}/briefing-events.jsonl", "w") as f:
        for kind, title, msg, mins in events:
            f.write(json.dumps({"id": str(uuid.uuid4()).upper(), "kind": kind, "title": title,
                                "message": msg, "at": NOW - APPLE_EPOCH - mins * 60}) + "\n")

def stage_defaults(own_look):
    suite = suite_name(STATE)
    subprocess.run(["defaults", "delete", suite], stderr=subprocess.DEVNULL)
    subprocess.run(["defaults", "delete", "app.conterm.Conterm.demo"], stderr=subprocess.DEVNULL)
    if own_look:
        with tempfile.NamedTemporaryFile(suffix=".plist") as f:
            f.write(plistlib.dumps(own_look_prefs())); f.flush()
            run("defaults", "import", suite, f.name)
    def d(key, *val): run("defaults", "write", suite, key, *val)
    d("conterm.hasCompletedSetup", "-bool", "true")
    d("conterm.agentToolBubbles", "-bool", "true")
    d("conterm.autoCheckUpdates", "-bool", "false")
    d("conterm.launchSound", "-bool", "false")
    d("conterm.soundEffects", "-bool", "false")
    d("conterm.enabledWidgets", "-array", "kubernetes", "containers", "gitStatus", "ansible", "systemStats", "clock")
    d("conterm.kubeWatchCluster", "-bool", "true")
    d("conterm.toolbarCollapsed", "-bool", "false")
    fmt = lambda t: time.strftime("%Y-%m-%d %H:%M:%S +0000", time.gmtime(t))
    d("conterm.briefingLastSeen", "-date", fmt(NOW - 3 * 3600))
    d("conterm.briefingLastResigned", "-date", fmt(NOW - 2.8 * 3600))
    # Per-shot overrides from screenshots.sh: "key=value" string settings.
    for pair in os.environ.get("DEMO_DEFAULTS", "").split():
        key, _, value = pair.partition("=")
        d(key, "-string", value)

def main():
    width, height = (int(sys.argv[1]), int(sys.argv[2])) if len(sys.argv) > 2 else (1440, 820)
    own_look = os.environ.get("DEMO_LOOK", "own") != "plain"
    if os.path.exists(ROOT): shutil.rmtree(ROOT)
    os.makedirs(ROOT)
    stage_home()
    stage_state(width, height, own_look)
    stage_defaults(own_look)
    print(ROOT)

if __name__ == "__main__":
    main()
