
# Conterm pane hooks (appended to the bundled Ghostty zsh integration
# at build time). CONTERM_PANE_ID identifies this shell's pane.
#
# An instance run against a staged user home (CONTERM_USER_HOME) hands it
# to its shells. This runs from .zshenv, after login(1) has reset HOME and
# before .zprofile / .zshrc, so the staged home's rc files and history
# take over and every `$HOME/.conterm` path below meets the app's.
if [[ -n "$CONTERM_USER_HOME" && -d "$CONTERM_USER_HOME" ]]; then
    export HOME="$CONTERM_USER_HOME"
    export ZDOTDIR="$CONTERM_USER_HOME"
fi


# Session restore (RestoreHandoff in the app). A restored pane's saved
# scrollback is printed here, before the rc files draw anything. A Claude
# session that was running resumes at the first prompt, ahead of every other
# precmd hook. Each file is taken by renaming it, since the app types the
# line itself for a shell that leaves the file in place, and the variables
# are dropped so shells started from this one don't act on them again.
if [[ -n "$CONTERM_RESTORE_SCROLLBACK" ]]; then
    if command mv -f -- "$CONTERM_RESTORE_SCROLLBACK" "$CONTERM_RESTORE_SCROLLBACK.zsh" 2>/dev/null; then
        command cat -- "$CONTERM_RESTORE_SCROLLBACK.zsh"
        command rm -f -- "$CONTERM_RESTORE_SCROLLBACK.zsh"
    fi
fi
builtin unset CONTERM_RESTORE_SCROLLBACK
if [[ -n "$CONTERM_RESTORE_COMMAND" ]]; then
    builtin typeset -g _conterm_restore_file="$CONTERM_RESTORE_COMMAND"
    _conterm_restore_precmd() {
        precmd_functions=(${precmd_functions:#_conterm_restore_precmd})
        local f="$_conterm_restore_file" cmd
        builtin unset _conterm_restore_file
        if command mv -f -- "$f" "$f.zsh" 2>/dev/null; then
            cmd="$(<"$f.zsh")"
            command rm -f -- "$f.zsh"
            [[ -n "$cmd" ]] && builtin eval "$cmd"
        fi
        builtin unfunction _conterm_restore_precmd
    }
    builtin typeset -ag precmd_functions
    precmd_functions=(_conterm_restore_precmd $precmd_functions)
fi
builtin unset CONTERM_RESTORE_COMMAND

#
# Silent kubectl session switch: the Kubernetes widget writes a one-shot
# file holding a KUBECONFIG value for this pane; it's applied here right
# before the next command runs — nothing is typed into the terminal —
# then consumed. An empty file clears the override.
_conterm_kube_preexec() {
    [[ -n "$CONTERM_PANE_ID" ]] || return 0
    local f="$HOME/.conterm/k8s/pane-$CONTERM_PANE_ID"
    [[ -r "$f" ]] || return 0
    local v="$(<"$f")"
    command rm -f -- "$f"
    if [[ -n "$v" ]]; then
        export KUBECONFIG="$v"
    else
        unset KUBECONFIG
    fi
}
preexec_functions+=(_conterm_kube_preexec)

# Rollout watcher: when a command that redeploys a workload starts,
# leave a marker naming this shell's kubeconfig and the command line;
# the app resolves the target deployments and follows the rollout.
_conterm_rollout_preexec() {
    [[ -n "$CONTERM_PANE_ID" ]] || return 0
    case "$1" in
        kubectl\ *|*/kubectl\ *|sudo\ kubectl\ *) ;;
        *) return 0 ;;
    esac
    case " $1 " in
        *" rollout restart "*|*" set image "*|*" scale "*|*" apply "*) ;;
        *) return 0 ;;
    esac
    mkdir -p "$HOME/.conterm/k8s"
    { print -r -- "${KUBECONFIG:-}"; print -r -- "$1"; } \
        > "$HOME/.conterm/k8s/rollout-$CONTERM_PANE_ID"
}
preexec_functions+=(_conterm_rollout_preexec)

# Ansible cockpit: when a playbook command starts, point Ansible's
# additional-callback path at Conterm's bundled plugin and give it this
# pane's feed file. Console output is untouched — the plugin mirrors
# events to the feed and the app renders the live cockpit from it.
_conterm_ansible_preexec() {
    [[ -n "$CONTERM_PANE_ID" ]] || return 0
    case "$1" in
        ansible-playbook*|*/ansible-playbook*) ;;
        *) return 0 ;;
    esac
    local plugdir="${GHOSTTY_RESOURCES_DIR:h}/ansible"
    [[ -d "$plugdir" ]] || return 0
    mkdir -p "$HOME/.conterm/ansible"
    export CONTERM_ANSIBLE_LOG="$HOME/.conterm/ansible/run-$CONTERM_PANE_ID.jsonl"
    : > "$CONTERM_ANSIBLE_LOG"
    case ":$ANSIBLE_CALLBACK_PLUGINS:" in
        *:"$plugdir":*) ;;
        *) export ANSIBLE_CALLBACK_PLUGINS="${ANSIBLE_CALLBACK_PLUGINS:+$ANSIBLE_CALLBACK_PLUGINS:}$plugdir" ;;
    esac
}
preexec_functions+=(_conterm_ansible_preexec)

# Terraform cockpit: a plan is a structured diff that reads badly as a
# wall of text. Point this pane's plan at a saved plan file the app can
# read back with `terraform show -json` and render as a card. Console
# output is otherwise untouched — terraform does print the plan file it
# saved, which is why this is opt-in via the marker file the app writes
# from Settings.
#
# TF_CLI_ARGS_plan is inserted BEFORE the typed arguments, so a `-out` of
# your own still wins; the command is skipped outright in that case
# rather than saving a plan nobody reads.
_conterm_terraform_preexec() {
    [[ -n "$CONTERM_PANE_ID" ]] || return 0
    # Withdraw a previous injection before deciding anything. The export
    # outlives the command that caused it, so a setting turned off — or a
    # plan carrying its own -out — would otherwise keep writing plan files
    # nobody reads, for the life of the shell.
    if [[ -n "$_conterm_tf_injected" \
          && "$TF_CLI_ARGS_plan" == "$_conterm_tf_injected" ]]; then
        if [[ -n "$_conterm_tf_saved" ]]; then
            export TF_CLI_ARGS_plan="$_conterm_tf_saved"
        else
            unset TF_CLI_ARGS_plan
        fi
        unset _conterm_tf_injected
    fi
    [[ -f "$HOME/.conterm/terraform/enabled" ]] || return 0
    case "$1" in
        terraform\ *|*/terraform\ *|tofu\ *|*/tofu\ *) ;;
        *) return 0 ;;
    esac
    case " $1 " in
        *" plan "*|*" plan") ;;
        *) return 0 ;;
    esac
    case " $1 " in
        *" -out"*) return 0 ;;
    esac
    mkdir -p "$HOME/.conterm/terraform"
    local out="$HOME/.conterm/terraform/plan-$CONTERM_PANE_ID.tfplan"
    command rm -f -- "$out"
    # Compose rather than replace: a TF_CLI_ARGS_plan of your own (say
    # -lock=false) has to survive this.
    _conterm_tf_saved="$TF_CLI_ARGS_plan"
    _conterm_tf_injected="${_conterm_tf_saved:+$_conterm_tf_saved }-out=$out"
    export TF_CLI_ARGS_plan="$_conterm_tf_injected"
    { print -r -- "$PWD"; print -r -- "$1"; } \
        > "$HOME/.conterm/terraform/run-$CONTERM_PANE_ID"
}
preexec_functions+=(_conterm_terraform_preexec)

# Agent forwarding over SSH: a plain interactive `ssh <host>` from a
# Conterm pane reverse-forwards this pane's agent socket and exports
# the pane identity on the far end, so harnesses there (usually
# inside tmux) report status and tool calls back to THIS pane
# (RemoteAgentChannel in the app; `agent-hook.sh` prefers the socket
# and falls back to the tty escape, DCS-wrapped inside tmux).
# Anything else — a remote command, -N/-L/-R/-f/-G forms, any extra
# argument — passes through untouched, so git/scp/rsync over ssh are
# unaffected. Opt out per shell with CONTERM_NO_SSH_WRAP=1.
#
# Ghostty's own ssh wrapper is defined in _ghostty_deferred_init,
# which runs at the FIRST PROMPT and would replace a ssh() defined
# at source time. So this file only registers a precmd hook (added
# after Ghostty's, so it runs after it) that installs the wrapper
# on top of `ghostty +ssh` — ssh-env/terminfo handling stays
# Ghostty's, we add only the -R forward and the pane identity.
_conterm_ghostty_ssh() {
    if [[ -n "$GHOSTTY_BIN_DIR" && -x "$GHOSTTY_BIN_DIR/ghostty" ]]; then
        "$GHOSTTY_BIN_DIR/ghostty" +ssh --terminfo=false -- "$@"
    else
        command ssh "$@"
    fi
}
_conterm_install_ssh_wrap() {
    builtin emulate -L zsh
    precmd_functions=(${precmd_functions:#_conterm_install_ssh_wrap})
    builtin unfunction _conterm_install_ssh_wrap
    [[ -n "$CONTERM_PANE_ID" ]] || return 0
    ssh() {
        builtin emulate -L zsh
        local _listen="${CONTERM_AGENT_LISTEN:-$HOME/.conterm/run/agent.sock}"
        if [[ $# -eq 1 && -z "$CONTERM_NO_SSH_WRAP" && -S "$_listen" ]]; then
            # A host with RemoteCommand in its config cannot also take
            # a command-line command (OpenSSH refuses the pair). Skip
            # the wrapper for it; Ghostty's env handling still applies.
            local _rc=""
            _rc=$(command ssh -G "$1" 2>/dev/null \
                | command awk '$1=="remotecommand" { $1=""; sub(/^ /, ""); print; exit }')
            if [[ -n "$_rc" ]]; then
                _conterm_ghostty_ssh "$@"
                return
            fi
            # Absolute remote path: sshd binds a relative -R path from
            # /, where it never binds. StreamLocalBindUnlink makes
            # sshd clear a stale socket left by a previous connection.
            local _rsock="$HOME/.conterm/run/agent-$CONTERM_PANE_ID.sock"
            # The injected command runs under a POSIX shell whatever
            # the login shell is (fish/csh/nushell cannot parse it),
            # and tmux env is per-session, never server-global (-g
            # would make two panes on one host report to the last one).
            local _inner="mkdir -p ~/.conterm/run && export CONTERM_PANE_ID=$CONTERM_PANE_ID CONTERM_AGENT_SOCK=\"\$HOME/.conterm/run/agent-$CONTERM_PANE_ID.sock\" && { tmux set-environment CONTERM_PANE_ID $CONTERM_PANE_ID 2>/dev/null; tmux set-environment CONTERM_AGENT_SOCK \"\$HOME/.conterm/run/agent-$CONTERM_PANE_ID.sock\" 2>/dev/null; }; exec \"\${SHELL:-/bin/sh}\" -l"
            _conterm_ghostty_ssh -o StreamLocalBindUnlink=yes \
                -R "$_rsock:$_listen" -t "$1" "exec /bin/sh -c '$_inner'"
        else
            _conterm_ghostty_ssh "$@"
        fi
    }
}
builtin typeset -ag precmd_functions
precmd_functions+=(_conterm_install_ssh_wrap)
