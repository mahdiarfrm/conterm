# Shell for the staged demo home. Every pane opens here (the app hands
# its shells CONTERM_USER_HOME, which conterm-integration.zsh adopts).

# login(1) has already printed the real account's last login; clear it
# and the scrollback with it.
printf '\033[H\033[2J\033[3J'

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HISTFILE="$HOME/.zsh_history" HISTSIZE=5000 SAVEHIST=5000
export KUBECONFIG="$HOME/.kube/config"
export LANG=en_US.UTF-8 EDITOR=vim
setopt prompt_subst no_beep

# OpenSSH finds its config through the passwd home, never $HOME.
alias ssh="ssh -F $HOME/.ssh/config"
alias scp="scp -F $HOME/.ssh/config"

autoload -Uz vcs_info
zstyle ':vcs_info:git:*' formats ' %F{magenta}%b%f'
precmd_functions+=(vcs_info)
PROMPT='%F{blue}%~%f${vcs_info_msg_0_} %(?.%F{green}.%F{red})❯%f '

# A directory holding `.demo-run` runs that line once, at the first
# prompt, as if typed: the title, the command marks and the app's
# preexec hooks see an ordinary command.
if [[ -r .demo-run ]]; then
    _demo_line="$(<.demo-run)"
    _demo_autorun() {
        [[ -n "$_demo_line" ]] || return 0
        BUFFER="$_demo_line"
        _demo_line=""
        zle accept-line
    }
    autoload -Uz add-zle-hook-widget
    zle -N _demo_autorun
    add-zle-hook-widget line-init _demo_autorun
fi
