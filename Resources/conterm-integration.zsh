
# Conterm pane hooks (appended to the bundled Ghostty zsh integration
# at build time). CONTERM_PANE_ID identifies this shell's pane.
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
