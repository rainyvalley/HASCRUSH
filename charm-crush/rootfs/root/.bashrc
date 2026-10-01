export TERM=xterm-256color
export LANG=C.UTF-8
PS1='\[\033[1;36m\]crush\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ '

# Aliases
alias ll='ls -la'
alias ha-config='cd /homeassistant'
alias ha-logs='cat /homeassistant/home-assistant.log 2>/dev/null || echo "Log not found"'
alias c='crush'
alias ct='tmux new-session -A -s crush'