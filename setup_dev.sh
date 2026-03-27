#!/usr/bin/env bash
set -euo pipefail

RED=$'\e[0;31m'; GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'
CYAN=$'\e[0;36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

log()     { echo -e "\n${GREEN}${BOLD}==> $*${RESET}\n"; }
info()    { echo -e "  ${CYAN}·${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠  $*${RESET}"; }
success() { echo -e "  ${GREEN}✔  $*${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$SCRIPT_DIR/dotfiles"
PACKAGES_YAML="$SCRIPT_DIR/packages.yaml"

[[ ! -d "$DOTFILES_DIR" ]]  && { echo -e "${RED}ERROR: dotfiles/ not found at $DOTFILES_DIR${RESET}"; exit 1; }
[[ ! -f "$PACKAGES_YAML" ]] && { echo -e "${RED}ERROR: packages.yaml not found at $PACKAGES_YAML${RESET}"; exit 1; }

deploy_file() {
  local src="$1" dst="$2" label="$3"
  [[ ! -f "$src" ]] && { warn "Not found, skipping: $src"; return; }
  mkdir -p "$(dirname "$dst")"
  [[ -f "$dst" ]] && cp "$dst" "${dst}.bak.$(date +%s)"
  cp "$src" "$dst"
  success "$label → $dst"
}

ask() {
  local prompt="$1" default="${2:-y}" yn
  if [[ "$default" == "y" ]]; then
    read -rp "  ${BOLD}${prompt} [Y/n]: ${RESET}" yn; yn="${yn:-y}"
  else
    read -rp "  ${BOLD}${prompt} [y/N]: ${RESET}" yn; yn="${yn:-n}"
  fi
  [[ "$yn" =~ ^[Yy]$ ]]
}

python3 -c "import yaml" 2>/dev/null || sudo apt-get -y install python3-yaml -qq

pkg_list() {
  local section="$1" key="${2:-apt}"
  python3 - <<PYEOF
import yaml
with open("$PACKAGES_YAML") as f:
    cfg = yaml.safe_load(f)
pkgs = (cfg.get("$section") or {}).get("$key") or []
print(" ".join(str(p) for p in pkgs))
PYEOF
}

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ╔══════════════════════════════════════════════════╗
  ║        Interactive Dev Environment Setup         ║
  ╠══════════════════════════════════════════════════╣
  ║  Last Updated: 27th Mar 2026                     ║
  ╚══════════════════════════════════════════════════╝
EOF
echo -e "${RESET}"
if ! ask "Ready to start?"; then exit 0; fi

# ── Platform detection ────────────────────────────────────────────────────────
HAS_NVIDIA=false
IS_JETPACK=false

if [[ -f /etc/nv_tegra_release ]]; then
  IS_JETPACK=true
  HAS_NVIDIA=true
  info "Jetpack detected: $(head -1 /etc/nv_tegra_release)"
elif lspci 2>/dev/null | grep -qi nvidia; then
  HAS_NVIDIA=true
  info "NVIDIA GPU detected."
fi

# ── Step 1 – System update ────────────────────────────────────────────────────
log "Step 1 · System update"
if ask "Run apt update & upgrade?"; then
  sudo apt update && sudo apt -y upgrade
  success "System updated."
fi

# ── Step 2 – Base packages ────────────────────────────────────────────────────
log "Step 2 · Base packages"
mapfile -t BASE_PKGS < <(pkg_list base apt | tr ' ' '\n' | grep -v '^$')
if ask "Install base packages?"; then
  sudo apt -y install "${BASE_PKGS[@]}"
  mkdir -p "$HOME/.local/bin"
  if ! command -v fd >/dev/null 2>&1; then
    ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
  fi
  sudo locale-gen en_US en_US.UTF-8
  sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
  success "Base packages installed."
fi

if ! $IS_JETPACK; then
  mapfile -t X86_PKGS < <(pkg_list x86 apt | tr ' ' '\n' | grep -v '^$')
  if [[ ${#X86_PKGS[@]} -gt 0 ]] && ask "Install x86-specific packages?"; then
    sudo apt -y install "${X86_PKGS[@]}"
    success "x86 packages installed."
  fi
fi

#  Step 2b – mise + fzf 
log "Step 2b · mise + fzf"
if ask "Install mise and fzf?"; then
  if ! command -v mise >/dev/null 2>&1; then
    curl https://mise.run | sh
    export PATH="$HOME/.local/bin:$PATH"
    eval "$("$HOME/.local/bin/mise" activate bash)"
  else
    eval "$(mise activate bash)"
  fi
  mise use -g fzf@latest
  success "mise + fzf installed."
fi

#  Step 3 – Terminator 
log "Step 3 · Terminator"
if ask "Install Terminator?"; then
  sudo apt -y install terminator
  if ask "Deploy white theme config?"; then
    deploy_file "$DOTFILES_DIR/terminator/config" "$HOME/.config/terminator/config" "Terminator config"
  fi
  success "Terminator installed."
fi

#  Step 4 – btop 
log "Step 4 · btop"
if ask "Install btop?"; then
  sudo apt -y install btop 2>/dev/null || sudo snap install btop
  success "btop installed."
fi

#  Step 5 – tmux 
log "Step 5 · tmux"
if ask "Install tmux?"; then
  sudo apt -y install tmux
  success "tmux installed."
fi

#  Step 6 – NVIDIA drivers 
log "Step 6 · NVIDIA drivers"
if $IS_JETPACK; then
  info "Jetpack — drivers pre-installed, skipping."
elif $HAS_NVIDIA; then
  RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/{print $3}' | head -1)
  [[ -z "$RECOMMENDED" ]] && RECOMMENDED="nvidia-driver-535"
  read -rp "  ${BOLD}Driver package [${RECOMMENDED}]: ${RESET}" NVIDIA_PKG
  NVIDIA_PKG="${NVIDIA_PKG:-$RECOMMENDED}"
  if ask "Install ${NVIDIA_PKG}?"; then
    sudo apt -y install "$NVIDIA_PKG"
    warn "Reboot required to activate driver."
    success "NVIDIA driver installed."
  fi
else
  info "No NVIDIA GPU detected — skipping."
fi

#  Step 7 – Docker 
log "Step 7 · Docker"
if ask "Install Docker?"; then

  if $IS_JETPACK; then
    echo -e "  ${BOLD}Flash method:${RESET}"
    echo -e "  ${CYAN}[1]${RESET} Linux_for_Tegra / SDK Manager  (installs Docker + CTK)"
    echo -e "  ${CYAN}[2]${RESET} Jetson USB stick               (already installed, configure only)"
    echo ""
    read -rp "  ${BOLD}Choose [1/2] (default 1): ${RESET}" JETSON_FLASH_METHOD
    JETSON_FLASH_METHOD="${JETSON_FLASH_METHOD:-1}"

    if [[ "$JETSON_FLASH_METHOD" == "1" ]]; then
      sudo apt-get update
      sudo apt-get install -y nvidia-container curl
      curl https://get.docker.com | sh
      sudo systemctl --now enable docker
      sudo nvidia-ctk runtime configure --runtime=docker
      sudo systemctl daemon-reload && sudo systemctl restart docker
      success "Docker + NVIDIA runtime installed."
    fi

    sudo apt-get install -y jq
    sudo jq '. + {"default-runtime": "nvidia"}' /etc/docker/daemon.json \
      | sudo tee /etc/docker/daemon.json.tmp \
      && sudo mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
    sudo systemctl daemon-reload && sudo systemctl restart docker
    success "Default runtime set to nvidia."

  else
    sudo apt -y remove docker docker-engine docker.io containerd runc 2>/dev/null || true
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    OS_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")
    [[ -z "$OS_CODENAME" ]] && OS_CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${OS_CODENAME} stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt -y install docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
    sudo systemctl enable docker.service containerd.service
    success "Docker installed."

    if $HAS_NVIDIA && ask "Install NVIDIA Container Toolkit?"; then
      echo -e "  ${CYAN}[1]${RESET} Standard  ${CYAN}[2]${RESET} Rootless"
      read -rp "  ${BOLD}Mode [1/2] (default 1): ${RESET}" DOCKER_MODE
      DOCKER_MODE="${DOCKER_MODE:-1}"

      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
      sudo apt update && sudo apt -y install nvidia-container-toolkit

      if [[ "$DOCKER_MODE" == "2" ]]; then
        sudo systemctl disable --now docker.service docker.socket
        dockerd-rootless-setuptool.sh install
        mkdir -p "$HOME/.config/docker"
        nvidia-ctk runtime configure --runtime=docker --config="$HOME/.config/docker/daemon.json"
        systemctl --user restart docker
        sudo nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place
        success "NVIDIA CTK configured (rootless)."
      else
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker
        success "NVIDIA CTK configured."
      fi

      if ask "Verify GPU access inside Docker?"; then
        docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi \
          && success "GPU verified." \
          || warn "Smoke test failed — expected if driver was just installed (reboot first)."
      fi
    fi
  fi

  sudo groupadd docker 2>/dev/null || true
  sudo usermod -aG docker "$USER"
  [[ -d "$HOME/.docker" ]] && sudo chown -R "$USER":"$USER" "$HOME/.docker"
  success "User added to docker group."
  warn "Run 'newgrp docker' or log out/in to apply."
fi

#  Step 8 – uv 
log "Step 8 · uv"
if ask "Install uv?"; then
  if command -v uv >/dev/null 2>&1; then
    uv self update
  else
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
  success "uv installed."
fi

#  Step 9 – Jetson tools 
if $IS_JETPACK; then
  log "Step 9 · Jetson tools"
  mapfile -t JETPACK_APT < <(pkg_list jetpack apt | tr ' ' '\n' | grep -v '^$')
  mapfile -t JETPACK_PIP < <(pkg_list jetpack pip | tr ' ' '\n' | grep -v '^$')

  if ask "Install Jetson-specific tools?"; then
    [[ ${#JETPACK_APT[@]} -gt 0 ]] && sudo apt -y install "${JETPACK_APT[@]}"
    [[ ${#JETPACK_PIP[@]} -gt 0 ]] && sudo pip3 install -U "${JETPACK_PIP[@]}"
    sudo systemctl enable jetson_stats
    sudo systemctl start jetson_stats
    success "Jetson tools installed."
  fi
fi

#  Step 10 – Network profiles 
log "Step 10 · Network profiles"
command -v nmcli >/dev/null 2>&1 || sudo apt -y install network-manager

mapfile -t NET_PROFILES < <(python3 - "$PACKAGES_YAML" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
for name in (cfg.get("network_profiles") or {}):
    print(name)
PYEOF
)

if [[ ${#NET_PROFILES[@]} -eq 0 ]]; then
  info "No network_profiles in packages.yaml — skipping."
elif ask "Register network profiles with NetworkManager?"; then

  python3 - "$PACKAGES_YAML" <<'PYEOF'
import yaml, sys, subprocess

with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)

for name, p in (cfg.get("network_profiles") or {}).items():
    subprocess.run(["nmcli", "connection", "delete", name], capture_output=True)
    args = ["nmcli", "connection", "add", "type", "ethernet", "con-name", name, "ifname", p["interface"]]
    if p.get("dhcp", True):
        args += ["ipv4.method", "auto"]
    else:
        args += ["ipv4.method", "manual", "ipv4.addresses", p["ip"], "ipv4.gateway", p["gateway"]]
    if p.get("dns"):
        args += ["ipv4.dns", ",".join(p["dns"])]
    if p.get("search_domains"):
        args += ["ipv4.dns-search", ",".join(p["search_domains"])]
    if p.get("mtu"):
        args += ["802-3-ethernet.mtu", str(int(p["mtu"]))]
    r = subprocess.run(args, capture_output=True, text=True)
    print(f"  {'✔' if r.returncode == 0 else '✘'}  {name}")
PYEOF

  success "Profiles registered. Switch via Settings → Network or: nmcli connection up <name>"

  echo ""
  for i in "${!NET_PROFILES[@]}"; do
    PREVIEW=$(python3 - "$PACKAGES_YAML" "${NET_PROFILES[$i]}" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
p = (cfg.get("network_profiles") or {}).get(sys.argv[2], {})
mode = "DHCP" if p.get("dhcp", True) else "static " + p.get("ip", "?")
print(f"{p.get('interface','?')}  {mode}")
PYEOF
)
    echo -e "  ${CYAN}[$((i+1))]${RESET} ${BOLD}${NET_PROFILES[$i]}${RESET}  —  ${PREVIEW}"
  done
  echo -e "  ${CYAN}[0]${RESET} Skip"
  echo ""
  read -rp "  ${BOLD}Activate a profile now [0-${#NET_PROFILES[@]}]: ${RESET}" NET_CHOICE
  NET_CHOICE="${NET_CHOICE:-0}"

  if [[ "$NET_CHOICE" =~ ^[1-9][0-9]*$ ]] && [[ "$NET_CHOICE" -le ${#NET_PROFILES[@]} ]]; then
    CHOSEN="${NET_PROFILES[$((NET_CHOICE-1))]}"
    nmcli connection up "$CHOSEN"
    success "Profile '${CHOSEN}' active."
    warn "If this changed the IP of your SSH session, you may be disconnected."

    CHOSEN_HOST=$(python3 - "$PACKAGES_YAML" "$CHOSEN" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
print((cfg.get("network_profiles") or {}).get(sys.argv[2], {}).get("hostname") or "")
PYEOF
)
    [[ -n "$CHOSEN_HOST" ]] && sudo hostnamectl set-hostname "$CHOSEN_HOST" && success "Hostname → ${CHOSEN_HOST}"
  fi
fi

#  Done 
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════╗"
echo -e "║          Setup Complete            ║"
echo -e "╚════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Next steps${RESET}"
echo -e "  · Run ${CYAN}newgrp docker${RESET} or log out/in to activate Docker group"
$HAS_NVIDIA && ! $IS_JETPACK && echo -e "  · ${YELLOW}Reboot${RESET} to activate NVIDIA drivers"
$IS_JETPACK  && echo -e "  · Run ${CYAN}jtop${RESET} to monitor your Jetson"
echo -e "  · Switch networks via ${CYAN}Settings → Network${RESET} or ${CYAN}nmcli connection up <name>${RESET}"
echo ""
