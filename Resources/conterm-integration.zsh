
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
