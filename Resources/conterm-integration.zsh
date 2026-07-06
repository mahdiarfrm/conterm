
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
