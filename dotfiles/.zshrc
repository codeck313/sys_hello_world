# Shell integration for ghostty
if [ -n "${GHOSTTY_RESOURCES_DIR}" ]; then
  builtin source "${GHOSTTY_RESOURCES_DIR}/shell-integration/zsh/ghostty-integration"
fi

# Set up git bare repository for dotfiles
alias dot="git --git-dir=$HOME/.dot.git/ --work-tree=$HOME"

# Load local secrets and configurations
if [[ -f $HOME/.zsh_secrets.zsh ]]; then source $HOME/.zsh_secrets.zsh; fi
if [[ -f $HOME/.zsh_local.zsh ]]; then source $HOME/.zsh_local.zsh; fi

# Add local bin directory to path
export PATH="$HOME/.local/bin:$PATH";

# Language
export LANGUAGE=en
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

export EDITOR=nvim

# Theme
SPACESHIP_PROMPT_ORDER=(
  user          # Username section
  dir           # Current directory section
  host          # Hostname section
  git           # Git section (git_branch + git_status)
  conda
  hg            # Mercurial section (hg_branch  + hg_status)
  node          # Node.js section
  exec_time     # Execution time
  async         # Async jobs indicator
  jobs          # Background jobs indicator
  exit_code     # Exit code section
  sudo          # Sudo indicator
  line_sep      # Line break
  char          # Prompt character
)

SPACESHIP_PROMPT_ADD_NEWLINE=false
SPACESHIP_CHAR_SYMBOL="❯"
SPACESHIP_CHAR_SUFFIX=" "

# Enable hooks
autoload -U add-zsh-hook

# Enable zsh recompilation
autoload -Uz zrecompile

# Install and load plugins
plugins=(
  Aloxaf/fzf-tab
  zdharma-continuum/fast-syntax-highlighting
  zsh-users/zsh-autosuggestions
  zsh-users/zsh-history-substring-search
  zsh-users/zsh-completions
  buonomo/yarn-completion
  spaceship-prompt/spaceship-prompt
)

PLUGIN_DIR=$HOME/.zsh_plugins

for plugin in $plugins; do
  if [[ ! -d $PLUGIN_DIR/${plugin:t} ]]; then
    git clone --depth 1 https://github.com/${plugin} $PLUGIN_DIR/${plugin:t}

    for f in $PLUGIN_DIR/${plugin:t}/**/*.zsh; do
      echo "Recompiling $f"
      zrecompile -pq "$f"
    done
  fi

  if [[ -f $PLUGIN_DIR/${plugin:t}/${plugin:t}.plugin.zsh ]]; then
    source $PLUGIN_DIR/${plugin:t}/${plugin:t}.plugin.zsh
  fi
done

# Load spaceship prompt
source $PLUGIN_DIR/spaceship-prompt/spaceship.zsh

# Enable autocompletions
autoload -Uz compinit

# Load completions from cache if it's updated today
if [[ $(date +'%j' -r $HOME/.zcompdump 2>/dev/null || stat -f '%Sm' -t '%j' $HOME/.zcompdump 2>/dev/null) -eq $(date +'%j') ]]; then
  compinit -C -i
else
  compinit -i
fi

zmodload -i zsh/complist

# Save history so we get auto suggestions
HISTFILE=$HOME/.zsh_history # path to the history file
HISTSIZE=100000 # number of history items to store in memory
HISTDUP=erase # remove older duplicate entries from history
SAVEHIST=$HISTSIZE # number of history items to save to the history file

# Stop zsh autocorrect from suggesting undesired completions
CORRECT_IGNORE_FILE=".*"
CORRECT_IGNORE="_*"

# Options
setopt auto_cd # cd by typing directory name if it's not a command
setopt auto_list # automatically list choices on ambiguous completion
setopt auto_menu # automatically use menu completion
setopt always_to_end # move cursor to end if word had one match
setopt hist_expire_dups_first # expire duplicate entries first when trimming history
setopt hist_find_no_dups # don't display duplicate entries in history
setopt hist_ignore_space # ignore commands starting with space
setopt hist_ignore_all_dups # remove older duplicate entries from history
setopt hist_reduce_blanks # remove superfluous blanks from history items
setopt hist_save_no_dups # don't save duplicate entries in history
setopt hist_verify # don't execute immediately upon history expansion
setopt inc_append_history # save history entries as soon as they are entered
setopt share_history # share history between different instances
setopt correct_all # autocorrect commands
setopt interactive_comments # allow comments in interactive shells

# Improve autocompletion style
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}' # case-insensitive completion
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}" # colorize filenames
zstyle ':completion:*' menu no # disable menu completion for fzf-tab
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath' # preview directory contents with cd
zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'ls --color $realpath' # preview directory contents with zoxide
zstyle ':fzf-tab:*' use-fzf-default-opts yes # use FZF_DEFAULT_OPTS for fzf-tab

# Keybindings
bindkey '^[[A' history-substring-search-up # up arrow
bindkey '^[[B' history-substring-search-down # down arrow
bindkey '^[[3~' delete-char # delete key
bindkey "^[[1;5D" backward-word
bindkey "^[[1;5C" forward-word

# Disable paste highlighting for syntax-highlighting plugin
zle_highlight+=(paste:none)

# Setup zoxide as a replacement for cd
if [[ -x $(command -v zoxide) ]]; then eval "$(zoxide init --cmd cd zsh)"; fi

# mise version manager — must come before fzf so mise-managed tools are on PATH
if [[ -f "$HOME/.local/bin/mise" ]]; then
  eval "$($HOME/.local/bin/mise activate zsh)"
fi

# Setup fuzzy finder
export FZF_DEFAULT_OPTS=" \
--color=bg+:#424762,spinner:#b0bec5,hl:#f78c6c \
--color=fg:#bfc7d5,header:#ff9e80,info:#82aaff,pointer:#a5adce \
--color=marker:#89ddff,fg+:#eeffff,prompt:#c792ea,hl+:#ff9e80 \
--color=selected-bg:#424762"

if [[ -x $(command -v fzf) ]]; then eval "$(fzf --zsh)"; fi

# Use fd instead of find for fzf if available
if [[ -x $(command -v fd) ]]; then
  export FZF_DEFAULT_COMMAND='fd --hidden --strip-cwd-prefix --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND="fd --type d --hidden --strip-cwd-prefix --exclude .git"

  _fzf_compgen_path() {
    fd --hidden --exclude .git . "$1"
  }

  _fzf_compgen_dir() {
    fd --type d --hidden --exclude .git . "$1"
  }
fi

# Setup bat if available
if [[ -x $(command -v batcat) ]]; then
  export BAT_THEME="base16"

  alias cat="batcat --style=plain --paging=never"
fi

# Setup lazydocker to use podman if available
if [[ -z $DOCKER_HOST && -x $(command -v podman) ]]; then
  lazydocker() {
    local podman_socket="$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)"

    DOCKER_HOST="unix://${podman_socket}" command lazydocker $@
  }
fi

alias ls='ls --color=auto'
alias ll='ls -alF'


# ROS2 stuff
# source /opt/ros/humble/setup.zsh
# eval "$(register-python-argcomplete3 ros2)"
# eval "$(register-python-argcomplete3 colcon)"

# function colcon_b() {
#     local ws_dir=""
#     local current_dir=$(pwd)

#     if [[ "$(basename "$current_dir")" == *_ws ]]; then
#         ws_dir="$current_dir"
#     else
#         local dir="$current_dir"
#         # Traverse up the directory tree
#         while [[ "$dir" != "/" ]]; do
#             if [[ "$(basename "$dir")" == *_ws ]]; then
#                 ws_dir="$dir"
#                 break
#             fi
#             dir=$(dirname "$dir")
#         done
#     fi

#     if [ -z "$ws_dir" ]; then
#         echo "Error: Workspace directory ending in '_ws' not found by traversing up from the current directory."
#         return 1
#     fi

#     echo "Found workspace: $ws_dir"
#     echo "Building workspace..."

#     cd "$ws_dir" || return
#     colcon build --symlink-install

#     cd "$current_dir"
# }

# function sdsd() {
#     local ws_dir=""
#     local current_dir=$(pwd)

#     if [[ "$(basename "$current_dir")" == *_ws ]]; then
#         ws_dir="$current_dir"
#     else
#         local dir="$current_dir"
#         # Traverse up the directory tree
#         while [[ "$dir" != "/" ]]; do
#             if [[ "$(basename "$dir")" == *_ws ]]; then
#                 ws_dir="$dir"
#                 break
#             fi
#             dir=$(dirname "$dir")
#         done
#     fi

#     if [ -z "$ws_dir" ]; then
#         echo "Error: Workspace directory ending in '_ws' not found by traversing up from the current directory."
#         return 1
#     fi

#     echo "Found workspace: $ws_dir"
#     echo "Sourcing workspace..."

#     cd "$ws_dir" || return
#     source install/setup.zsh

#     cd "$current_dir"
# }

# function debug_node()
# {
#     # Launch a GDB session on {node}
#     # Usage: debug_node {node_name}                        "
#     local full_name="$(ros2 pkg executables | grep -i $*)"
#     local node_name=$(echo "$full_name" | cut -d' ' -f2)
#     local pkg_name=$(echo "$full_name" | cut -d' ' -f1)
#     if [ -z "$node_name" ]
#     then
#         echo "ERROR! Could not find node: $*, available candidates:"
#         ros2 pkg executables
#     else
#         local pkg_dir=$(ros2 pkg prefix $pkg_name)
#         gdb --args $pkg_dir/lib/$pkg_name/$node_name
#     fi
# }

# export ROS_DOMAIN_ID=69
# function go2()
# {
# 	export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
# 	export CYCLONEDDS_URI=file:///home/parrot/cyclonedds_config.xml
# }
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

export RCUTILS_COLORIZED_OUTPUT=1
export CONDA_CHANGEPS1=false

# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
function conda_on(){
	__conda_setup="$('/home/parrot/anaconda3/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
	if [ $? -eq 0 ]; then
	    eval "$__conda_setup"
	else
	    if [ -f "/home/parrot/anaconda3/etc/profile.d/conda.sh" ]; then
	        . "/home/parrot/anaconda3/etc/profile.d/conda.sh"
	    else
	        export PATH="/home/parrot/anaconda3/bin:$PATH"
	    fi
	fi
	unset __conda_setup
	# <<< conda initialize <<<
}

# export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
# export PATH=/usr/local/cuda-12.6/bin${PATH:+:${PATH}}
#export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
