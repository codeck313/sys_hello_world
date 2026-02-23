#!/usr/bin/env bash
# =============================================================================
#  Interactive Dev Environment Setup
#  Installs: Terminator · Ghostty · btop · tmux ·
#            NVIDIA drivers · Docker + NVIDIA GPU · Zsh customisation
#
#  Dotfiles are read from ./dotfiles/ next to this script.
#  Edit them there — this script just copies them into place.
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "\n${GREEN}${BOLD}==> $*${RESET}\n"; }
info()    { echo -e "  ${CYAN}·${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠  $*${RESET}"; }
success() { echo -e "  ${GREEN}✔  $*${RESET}"; }

# ── Resolve the dotfiles directory relative to this script ────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$SCRIPT_DIR/dotfiles"

if [[ ! -d "$DOTFILES_DIR" ]]; then
  echo -e "${RED}ERROR: dotfiles/ directory not found at $DOTFILES_DIR${RESET}"
  echo -e "  Make sure the dotfiles/ folder sits next to this script."
  exit 1
fi

# ── Helper: backup then copy a dotfile ───────────────────────────────────────
deploy_file() {
  local src="$1"      # path inside dotfiles/
  local dst="$2"      # destination path (absolute)
  local label="$3"

  if [[ ! -f "$src" ]]; then
    warn "Source file not found, skipping: $src"
    return
  fi

  mkdir -p "$(dirname "$dst")"

  if [[ -f "$dst" ]]; then
    cp "$dst" "${dst}.bak.$(date +%s)"
    warn "Existing $label backed up to ${dst}.bak.*"
  fi

  cp "$src" "$dst"
  success "$label deployed → $dst"
}

# ── Ask yes/no helper ─────────────────────────────────────────────────────────
ask() {
  local prompt="$1" default="${2:-y}" yn
  if [[ "$default" == "y" ]]; then
    read -rp "  ${BOLD}${prompt} [Y/n]: ${RESET}" yn; yn="${yn:-y}"
  else
    read -rp "  ${BOLD}${prompt} [y/N]: ${RESET}" yn; yn="${yn:-n}"
  fi
  [[ "$yn" =~ ^[Yy]$ ]]
}

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ╔══════════════════════════════════════════════════╗
  ║        Interactive Dev Environment Setup         ║
  ╠══════════════════════════════════════════════════╣
  ║  Last Updated: 23rd Feb 2026                     ║
  ║						     ║
  ║  These are not the droids you are looking for... ║
  ║  but this script will help you build them.       ║
  ╚══════════════════════════════════════════════════╝
EOF
echo -e "${RESET}"
echo -e "  Dotfiles directory: ${CYAN}${DOTFILES_DIR}${RESET}\n"
echo -e "${BOLD}You will be asked before each major step.${RESET}\n"

if ! ask "Ready to start?"; then echo "Aborted."; exit 0; fi

# ── Step 0 – Detect NVIDIA GPU ────────────────────────────────────────────────
HAS_NVIDIA=false
if lspci 2>/dev/null | grep -qi nvidia; then
  HAS_NVIDIA=true
  info "NVIDIA GPU detected."
else
  warn "No NVIDIA GPU detected – driver / Docker GPU steps will be skipped."
fi

# ── Step 1 – System update ────────────────────────────────────────────────────
log "Step 1 · System update & upgrade"
if ask "Run apt update & upgrade?"; then
  sudo apt update
  sudo apt -y upgrade
  success "System updated."
else
  warn "Skipped."
fi

# ── Step 2 – Base tooling ─────────────────────────────────────────────────────
log "Step 2 · Base developer tooling"
BASE_PKGS=(
  build-essential curl wget ca-certificates gnupg lsb-release
  software-properties-common git python3 python3-pip python3-venv
  vim nano unzip zip tar tree htop jq ripgrep fd-find bat thefuck
  zsh zoxide fzf neovim
)
info "Packages: ${BASE_PKGS[*]}"
if ask "Install base packages?"; then
  sudo apt -y install "${BASE_PKGS[@]}"
  # fd alias (Ubuntu ships it as 'fdfind')
  mkdir -p "$HOME/.local/bin"
  if ! command -v fd >/dev/null 2>&1; then
    ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    success "Linked fdfind → fd"
  fi
  sudo locale-gen en_US en_US.UTF-8
  sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
  success "Base tooling installed."
else
  warn "Skipped."
fi

# ── Step 3 – Terminator ───────────────────────────────────────────────────────
log "Step 3 · Terminator"
if ask "Install Terminator?"; then
  sudo apt -y install terminator
  success "Terminator installed."
else
  warn "Skipped."
fi

# ── Step 4 – Ghostty ─────────────────────────────────────────────────────────
log "Step 4 · Ghostty terminal"
if ask "Install Ghostty? (via snap)"; then
  if snap list 2>/dev/null | grep -q "^ghostty "; then
    warn "Ghostty already installed via snap."
  else
    sudo snap install ghostty --classic 2>/dev/null || {
      warn "Snap install failed – trying GitHub release .deb..."
      GHOSTTY_VER=$(curl -s https://api.github.com/repos/ghostty-org/ghostty/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)
      wget -q "https://github.com/ghostty-org/ghostty/releases/download/${GHOSTTY_VER}/ghostty_${GHOSTTY_VER}_amd64.deb" \
        -O /tmp/ghostty.deb
      sudo dpkg -i /tmp/ghostty.deb || sudo apt -f install -y
    }
  fi
  success "Ghostty installed."

  log "Step 4b · Deploy Ghostty config"
  if ask "Deploy dotfiles/ghostty/config → ~/.config/ghostty/config?"; then
    deploy_file \
      "$DOTFILES_DIR/ghostty/config" \
      "$HOME/.config/ghostty/config" \
      "Ghostty config"
  fi
else
  warn "Skipped."
fi

# ── Step 5 – btop ─────────────────────────────────────────────────────────────
log "Step 5 · btop"
if ask "Install btop?"; then
  sudo apt -y install btop 2>/dev/null || sudo snap install btop
  success "btop installed."
else
  warn "Skipped."
fi

# ── Step 6 – tmux ─────────────────────────────────────────────────────────────
log "Step 6 · tmux"
if ask "Install tmux?"; then
  sudo apt -y install tmux
  success "tmux installed."
else
  warn "Skipped."
fi

# ── Step 7 – NVIDIA drivers ───────────────────────────────────────────────────
log "Step 7 · NVIDIA drivers"
NVIDIA_INSTALLED=false
if $HAS_NVIDIA; then
  info "Detecting recommended driver..."
  RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | grep recommended | awk '{print $3}' | head -1 || true)
  [[ -z "$RECOMMENDED" ]] && RECOMMENDED="nvidia-driver-535" && warn "Could not auto-detect; defaulting to $RECOMMENDED"
  info "Recommended: ${BOLD}$RECOMMENDED${RESET}"
  read -rp "  ${BOLD}Driver package [${RECOMMENDED}]: ${RESET}" NVIDIA_PKG
  NVIDIA_PKG="${NVIDIA_PKG:-$RECOMMENDED}"
  if ask "Install ${NVIDIA_PKG}? (reboot required)"; then
    sudo apt -y install "$NVIDIA_PKG"
    NVIDIA_INSTALLED=true
    success "NVIDIA driver installed. ${YELLOW}Reboot required.${RESET}"
  else
    warn "Skipped NVIDIA driver."
  fi
else
  warn "No NVIDIA GPU – skipping."
fi

# ── Step 8 – Docker ───────────────────────────────────────────────────────────
log "Step 8 · Docker Engine"
if ask "Install Docker Engine?"; then

  # 8a – Remove legacy packages
  info "Removing any legacy Docker packages..."
  sudo apt -y remove docker docker-engine docker.io containerd runc 2>/dev/null || true

  # 8b – Add official Docker GPG key + apt repo
  info "Adding Docker's official apt repository..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update
  sudo apt -y install docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras

  # 8c – Enable Docker on boot
  sudo systemctl enable docker.service
  sudo systemctl enable containerd.service
  success "Docker installed and enabled on boot."

  # 8d – Run Docker WITHOUT sudo
  # Source: https://docs.docker.com/engine/install/linux-postinstall/
  # Create 'docker' group, add user, fix ~/.docker ownership, activate via newgrp.
  log "Step 8d · Configure Docker to run without sudo"
  info "Creating 'docker' group..."
  sudo groupadd docker 2>/dev/null || true

  info "Adding ${USER} to the 'docker' group..."
  sudo usermod -aG docker "$USER"

  # Fix ~/.docker ownership if it was ever touched by a sudo docker call
  if [[ -d "$HOME/.docker" ]]; then
    info "Correcting ~/.docker ownership..."
    sudo chown "$USER":"$USER" "$HOME/.docker" -R
    sudo chmod g+rwx "$HOME/.docker" -R
    success "~/.docker permissions fixed."
  fi

  success "Docker group configured."
  warn "Run 'newgrp docker' in your terminal OR log out/in to activate group without reboot."

  # 8e – NVIDIA Container Toolkit
  log "Step 8e · NVIDIA Container Toolkit (Docker GPU support)"
  echo ""
  echo -e "  ${BOLD}Two modes available:${RESET}"
  echo -e "  ${CYAN}[1] Standard${RESET}  – daemon as root, nvidia-ctk writes /etc/docker/daemon.json (most compatible)"
  echo -e "  ${CYAN}[2] Rootless${RESET}  – daemon as your user, nvidia-ctk writes ~/.config/docker/daemon.json"
  echo ""
  read -rp "  ${BOLD}Choose mode [1/2] (default: 1): ${RESET}" DOCKER_MODE
  DOCKER_MODE="${DOCKER_MODE:-1}"

  if $HAS_NVIDIA && ask "Install NVIDIA Container Toolkit?"; then
    # Add NVIDIA repo
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt update
    sudo apt -y install nvidia-container-toolkit

    if [[ "$DOCKER_MODE" == "2" ]]; then
      # Rootless mode
      # Source: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
      info "Configuring NVIDIA runtime for rootless Docker..."
      mkdir -p "$HOME/.config/docker"
      nvidia-ctk runtime configure --runtime=docker \
        --config="$HOME/.config/docker/daemon.json"

      info "Disabling cgroups (required for rootless)..."
      sudo nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place

      info "Restarting rootless Docker daemon..."
      systemctl --user restart docker

      info "Enabling systemd linger for ${USER}..."
      sudo loginctl enable-linger "$USER"

      # Export DOCKER_HOST so the CLI finds the rootless socket
      DOCKER_HOST_LINE="export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock"
      if ! grep -qF "$DOCKER_HOST_LINE" "$HOME/.zshrc" 2>/dev/null; then
        echo "$DOCKER_HOST_LINE" >> "$HOME/.zshrc"
        info "Added DOCKER_HOST to ~/.zshrc"
      fi
      success "NVIDIA Container Toolkit configured for ROOTLESS Docker."

    else
      # Standard mode
      info "Configuring NVIDIA runtime for standard Docker..."
      sudo nvidia-ctk runtime configure --runtime=docker
      sudo systemctl restart docker
      success "NVIDIA Container Toolkit configured for standard Docker."
    fi

    if ask "Run nvidia-smi inside Docker to verify GPU access?"; then
      docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi \
        && success "GPU verified inside Docker!" \
        || warn "Smoke test failed – expected before reboot if driver was just installed."
    fi
  else
    warn "Skipped NVIDIA Container Toolkit."
  fi

else
  warn "Skipped Docker."
fi

# ── Step 9 – Zsh & dotfiles ───────────────────────────────────────────────────
log "Step 9 · Zsh setup"
if ask "Set Zsh as default shell?"; then
  sudo apt -y install zsh
  if [ "$SHELL" != "$(which zsh)" ]; then
    chsh -s "$(which zsh)"
    success "Default shell changed to zsh. Log out/in for it to take effect."
  else
    info "Zsh is already the default shell."
  fi

  log "Step 9b · Deploy dotfiles"
  echo -e "  Files that will be deployed from ${CYAN}${DOTFILES_DIR}${RESET}:"
  echo -e "    dotfiles/.zshrc          → ${HOME}/.zshrc"
  echo -e "    dotfiles/ghostty/config  → ${HOME}/.config/ghostty/config  (if not already done)"
  echo ""
  if ask "Deploy all dotfiles now?"; then
    deploy_file "$DOTFILES_DIR/.zshrc"          "$HOME/.zshrc"                       ".zshrc"
    deploy_file "$DOTFILES_DIR/ghostty/config"  "$HOME/.config/ghostty/config"       "Ghostty config"
  else
    warn "Skipped dotfile deployment."
  fi
else
  warn "Skipped Zsh setup."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════╗"
echo -e "║        Setup Complete! 🎉          ║"
echo -e "╚════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Next steps:${RESET}"
echo -e "  1. ${CYAN}Log out and back in${RESET} so Zsh + Docker group take effect"
echo -e "     Or run ${CYAN}newgrp docker${RESET} in your current terminal for Docker immediately"
if $HAS_NVIDIA; then
  echo -e "  2. ${YELLOW}Reboot${RESET} to activate NVIDIA drivers, then run: ${CYAN}nvidia-smi${RESET}"
fi
echo -e "  3. Open a new terminal – zsh plugins will auto-clone on first launch"
echo -e "  4. To edit your config later, just update files in:"
echo -e "     ${CYAN}${DOTFILES_DIR}/${RESET} and re-run the deploy step"
echo ""
