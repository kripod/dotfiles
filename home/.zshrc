autoload -Uz compinit
compinit

zstyle ':completion:*' menu select
# Case-insensitive completion
zstyle ':completion:*' matcher-list '' 'm:{a-zA-Z}={A-Za-z}'

setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE
setopt INTERACTIVE_COMMENTS
