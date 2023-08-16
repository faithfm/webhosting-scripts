# Enable shared pyenv environment for web hosting scripts
# See: https://github.com/faithfm/webhosting-scripts

export PYENV_ROOT="/home/shared/.pyenv"
command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
