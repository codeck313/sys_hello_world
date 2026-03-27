#!/usr/bin/env bash
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED=$'\e[0;31m'; GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'
CYAN=$'\e[0;36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

log()     { echo -e "\n${GREEN}${BOLD}==> $*${RESET}\n"; }
info()    { echo -e "  ${CYAN}·${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠  $*${RESET}"; }
success() { echo -e "  ${GREEN}✔  $*${RESET}"; }
error()   { echo -e "  ${RED}✘  $*${RESET}"; }

# Run a command; on failure show the error and ask whether to continue or abort
try_cmd() {
  if ! "$@" 2>&1; then
    error "Command failed: $*"
    echo ""
    read -rp "  ${BOLD}Continue anyway? [y/N]: ${RESET}" yn
    if [[ ! "${yn:-n}" =~ ^[Yy]$ ]]; then
      echo -e "\n${RED}Aborted.${RESET}\n"
      exit 1
    fi
    warn "Continuing despite error..."
  fi
}

# ── Resolve directories relative to this script ───────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$SCRIPT_DIR/dotfiles"
PACKAGES_YAML="$SCRIPT_DIR/packages.yaml"

if [[ ! -d "$DOTFILES_DIR" ]]; then
  echo -e "${RED}ERROR: dotfiles/ directory not found at $DOTFILES_DIR${RESET}"
  echo -e "  Make sure the dotfiles/ folder sits next to this script."
  exit 1
fi

if [[ ! -f "$PACKAGES_YAML" ]]; then
  echo -e "${RED}ERROR: packages.yaml not found at $PACKAGES_YAML${RESET}"
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

# ── Bootstrap python3-yaml (needed to parse packages.yaml) ────────────────────
if ! python3 -c "import yaml" 2>/dev/null; then
  echo -e "  ${CYAN}·${RESET} Installing python3-yaml (required to parse packages.yaml)..."
  sudo apt-get -y install python3-yaml -qq
fi

# ── Read package lists from packages.yaml ─────────────────────────────────────
# Usage: pkg_list <section> [apt|pip]
# Returns a space-separated list of packages for the given section and key.
pkg_list() {
  local section="$1" key="${2:-apt}"
  python3 - <<PYEOF
import yaml, sys
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
  ║						     ║
  ║  These are not the droids you are looking for... ║
  ║  but this script will help you build them.       ║
  ╚══════════════════════════════════════════════════╝
EOF
echo -e "${RESET}"
echo -e "  Dotfiles directory: ${CYAN}${DOTFILES_DIR}${RESET}\n"
echo -e "${BOLD}You will be asked before each major step.${RESET}\n"

if ! ask "Ready to start?"; then echo "Aborted."; exit 0; fi

# ── Step 0 – Detect platform ──────────────────────────────────────────────────
HAS_NVIDIA=false
IS_JETPACK=false
ARCH="$(uname -m)"

# Jetpack detection: /etc/nv_tegra_release exists on all L4T/Jetpack systems
if [[ -f /etc/nv_tegra_release ]]; then
  IS_JETPACK=true
  HAS_NVIDIA=true
  JETPACK_VER=$(head -1 /etc/nv_tegra_release 2>/dev/null || echo "unknown")
  info "NVIDIA Jetpack (L4T) detected: ${JETPACK_VER}"
  info "Architecture: ${ARCH}"
  warn "NVIDIA drivers are pre-installed on Jetpack — driver install step will be skipped."
elif lspci 2>/dev/null | grep -qi nvidia; then
  HAS_NVIDIA=true
  info "NVIDIA GPU detected (x86_64)."
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
log "Step 2 · Base developer tooling (from packages.yaml → base.apt)"
mapfile -t BASE_PKGS < <(pkg_list base apt | tr ' ' '\n' | grep -v '^$')
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

# ── Step 2c – x86-only packages ───────────────────────────────────────────────
if ! $IS_JETPACK; then
  mapfile -t X86_PKGS < <(pkg_list x86 apt | tr ' ' '\n' | grep -v '^$')
  if [[ ${#X86_PKGS[@]} -gt 0 ]]; then
    log "Step 2c · x86-specific packages (from packages.yaml → x86.apt)"
    info "Packages: ${X86_PKGS[*]}"
    if ask "Install x86-specific packages?"; then
      sudo apt -y install "${X86_PKGS[@]}"
      success "x86 packages installed."
    else
      warn "Skipped."
    fi
  fi
fi

# ── Step 2b – mise + fzf ─────────────────────────────────────────────────────
log "Step 2b · mise (version manager) + fzf"
if ask "Install mise and use it to install fzf?"; then
  # Install mise via official installer script
  if ! command -v mise >/dev/null 2>&1; then
    info "Installing mise..."
    curl https://mise.run | sh
    # Activate mise for the rest of this script
    export PATH="$HOME/.local/bin:$PATH"
    eval "$("$HOME/.local/bin/mise" activate bash)"
    success "mise installed."
  else
    info "mise already installed, activating..."
    eval "$(mise activate bash)"
  fi

  # Install latest fzf via mise
  info "Installing fzf via mise..."
  try_cmd mise use -g fzf@latest
  success "fzf installed via mise."
else
  warn "Skipped mise + fzf."
fi

# ── Step 3 – Terminator ───────────────────────────────────────────────────────
log "Step 3 · Terminator"
if ask "Install Terminator?"; then
  sudo apt -y install terminator
  success "Terminator installed."

  log "Step 3b · Deploy Terminator config (white theme)"
  if ask "Deploy dotfiles/terminator/config → ~/.config/terminator/config?"; then
    deploy_file \
      "$DOTFILES_DIR/terminator/config" \
      "$HOME/.config/terminator/config" \
      "Terminator config"
  fi
else
  warn "Skipped."
fi

# ── Step 4 – btop ─────────────────────────────────────────────────────────────
log "Step 4 · btop"
if ask "Install btop?"; then
  sudo apt -y install btop 2>/dev/null || sudo snap install btop
  success "btop installed."
else
  warn "Skipped."
fi

# ── Step 5 – tmux ─────────────────────────────────────────────────────────────
log "Step 5 · tmux"
if ask "Install tmux?"; then
  sudo apt -y install tmux
  success "tmux installed."
else
  warn "Skipped."
fi

# ── Step 6 – NVIDIA drivers ───────────────────────────────────────────────────
log "Step 6 · NVIDIA drivers"
NVIDIA_INSTALLED=false
if $IS_JETPACK; then
  info "Jetpack detected — NVIDIA drivers are pre-installed. Skipping."
elif $HAS_NVIDIA; then
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

# ── Step 7 – Docker ───────────────────────────────────────────────────────────
log "Step 7 · Docker Engine"
if ask "Install Docker Engine?"; then

  # 7a – Remove legacy packages
  info "Removing any legacy Docker packages..."
  sudo apt -y remove docker docker-engine docker.io containerd runc 2>/dev/null || true

  # 7b – Add official Docker GPG key + apt repo
  # On Jetpack (aarch64), Docker's official repo supports arm64 natively.
  info "Adding Docker's official apt repository..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  # Jetpack reports ID=ubuntu but VERSION_CODENAME may differ; handle both
  OS_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")
  if [[ -z "$OS_CODENAME" ]]; then
    OS_CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
    warn "Could not detect codename from os-release, using: $OS_CODENAME"
  fi

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
${OS_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update
  sudo apt -y install docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras

  # 7c – Enable Docker on boot
  try_cmd sudo systemctl enable docker.service
  try_cmd sudo systemctl enable containerd.service
  success "Docker installed and enabled on boot."

  # 7d – Run Docker WITHOUT sudo
  log "Step 7d · Configure Docker to run without sudo"
  info "Creating 'docker' group..."
  sudo groupadd docker 2>/dev/null || true

  info "Adding ${USER} to the 'docker' group..."
  sudo usermod -aG docker "$USER"

  if [[ -d "$HOME/.docker" ]]; then
    info "Correcting ~/.docker ownership..."
    sudo chown "$USER":"$USER" "$HOME/.docker" -R
    sudo chmod g+rwx "$HOME/.docker" -R
    success "~/.docker permissions fixed."
  fi

  success "Docker group configured."
  warn "Run 'newgrp docker' in your terminal OR log out/in to activate group without reboot."

  # 7e – NVIDIA Container Toolkit
  log "Step 7e · NVIDIA Container Toolkit (Docker GPU support)"
  echo ""
  echo -e "  ${BOLD}Two modes available:${RESET}"
  echo -e "  ${CYAN}[1] Standard${RESET}  – daemon as root, nvidia-ctk writes /etc/docker/daemon.json (most compatible)"
  echo -e "  ${CYAN}[2] Rootless${RESET}  – daemon as your user, nvidia-ctk writes ~/.config/docker/daemon.json"
  echo ""
  read -rp "  ${BOLD}Choose mode [1/2] (default: 1): ${RESET}" DOCKER_MODE
  DOCKER_MODE="${DOCKER_MODE:-1}"

  if $HAS_NVIDIA && ask "Install NVIDIA Container Toolkit?"; then
    if $IS_JETPACK; then
      # On Jetpack the toolkit ships with L4T; configure it directly.
      info "Jetpack detected — nvidia-container-toolkit may already be present."
      info "Attempting install/upgrade via apt..."
      # Add NVIDIA container toolkit repo (L4T / Jetpack variant)
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      # Use the arm64-compatible stable list
      curl -s -L "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
      sudo apt update
      sudo apt -y install nvidia-container-toolkit
    else
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
      sudo apt update
      sudo apt -y install nvidia-container-toolkit
    fi

    if [[ "$DOCKER_MODE" == "2" ]]; then
      # ── Rootless Docker ───────────────────────────────────────────────────────
      info "Disabling system-wide Docker daemon (rootless runs its own)..."
      try_cmd sudo systemctl disable --now docker.service docker.socket

      info "Running dockerd-rootless-setuptool.sh install..."
      try_cmd dockerd-rootless-setuptool.sh install

      info "Configuring NVIDIA runtime for rootless Docker (no sudo)..."
      mkdir -p "$HOME/.config/docker"
      try_cmd nvidia-ctk runtime configure --runtime=docker \
        --config="$HOME/.config/docker/daemon.json"

      info "Restarting rootless Docker daemon..."
      try_cmd systemctl --user restart docker

      info "Disabling cgroups in NVIDIA runtime config (required for rootless)..."
      try_cmd sudo nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place

      success "NVIDIA Container Toolkit configured for ROOTLESS Docker."

    else
      # Standard mode
      info "Configuring NVIDIA runtime for standard Docker..."
      sudo nvidia-ctk runtime configure --runtime=docker
      try_cmd sudo systemctl restart docker
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

# ── Step 8 – uv ───────────────────────────────────────────────────────────────
log "Step 8 · uv (Python package & project manager)"
if ask "Install uv?"; then
  if command -v uv >/dev/null 2>&1; then
    info "uv already installed. Updating..."
    uv self update && success "uv updated."
  else
    info "Installing uv via official installer..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    success "uv installed."
    info "uv is available at ~/.local/bin/uv — ensure ~/.local/bin is in your PATH."
  fi
else
  warn "Skipped uv."
fi

# ── Step 9 – Jetson debug & monitoring tools ──────────────────────────────────
if $IS_JETPACK; then
  log "Step 9 · Jetson debug & monitoring tools (from packages.yaml → jetpack)"

  mapfile -t JETPACK_APT < <(pkg_list jetpack apt | tr ' ' '\n' | grep -v '^$')
  mapfile -t JETPACK_PIP < <(pkg_list jetpack pip | tr ' ' '\n' | grep -v '^$')

  if [[ ${#JETPACK_APT[@]} -gt 0 ]]; then
    info "apt packages: ${JETPACK_APT[*]}"
  fi
  if [[ ${#JETPACK_PIP[@]} -gt 0 ]]; then
    info "pip packages: ${JETPACK_PIP[*]}"
  fi

  if ask "Install Jetson-specific tools?"; then

    # apt packages
    if [[ ${#JETPACK_APT[@]} -gt 0 ]]; then
      info "Installing apt packages..."
      sudo apt -y install "${JETPACK_APT[@]}"
      success "Jetson apt packages installed."
    fi

    # pip packages (system-wide so services like jtop can access them)
    if [[ ${#JETPACK_PIP[@]} -gt 0 ]]; then
      info "Installing pip packages (system-wide)..."
      sudo pip3 install -U "${JETPACK_PIP[@]}"
      success "Jetson pip packages installed."
    fi

    # Enable jetson_stats service so jtop works without sudo
    if python3 -c "import jetson_stats" 2>/dev/null || \
       sudo pip3 show jetson-stats &>/dev/null; then
      info "Enabling jetson_stats service (allows jtop without sudo)..."
      try_cmd sudo systemctl enable jetson_stats
      try_cmd sudo systemctl start jetson_stats
      success "jetson_stats service enabled."
      info "Run ${BOLD}jtop${RESET} to monitor your Jetson."
    fi

  else
    warn "Skipped Jetson tools."
  fi
fi

# ── Step 10 – Network profile ─────────────────────────────────────────────────
log "Step 10 · Network profile"

# Collect profile names from the YAML
mapfile -t NET_PROFILES < <(python3 - "$PACKAGES_YAML" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
profiles = cfg.get("network_profiles") or {}
for name in profiles:
    print(name)
PYEOF
)

if [[ ${#NET_PROFILES[@]} -eq 0 ]]; then
  info "No network_profiles defined in packages.yaml — skipping."
else
  echo -e "  ${BOLD}Available profiles (defined in packages.yaml):${RESET}"
  for i in "${!NET_PROFILES[@]}"; do
    PREVIEW=$(python3 - "$PACKAGES_YAML" "${NET_PROFILES[$i]}" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
p = (cfg.get("network_profiles") or {}).get(sys.argv[2], {})
iface = p.get("interface", "?")
mode  = "DHCP" if p.get("dhcp", True) else "static " + p.get("ip", "?")
host  = p.get("hostname") or ""
note  = "  hostname→" + host if host else ""
print(f"{iface}  {mode}{note}")
PYEOF
)
    echo -e "  ${CYAN}[$((i+1))]${RESET} ${BOLD}${NET_PROFILES[$i]}${RESET}  —  ${PREVIEW}"
  done
  echo -e "  ${CYAN}[0]${RESET} Skip"
  echo ""
  read -rp "  ${BOLD}Choose a profile [0-${#NET_PROFILES[@]}]: ${RESET}" NET_CHOICE
  NET_CHOICE="${NET_CHOICE:-0}"

  if [[ "$NET_CHOICE" != "0" ]] && \
     [[ "$NET_CHOICE" =~ ^[0-9]+$ ]] && \
     [[ "$NET_CHOICE" -ge 1 ]] && \
     [[ "$NET_CHOICE" -le ${#NET_PROFILES[@]} ]]; then

    CHOSEN="${NET_PROFILES[$((NET_CHOICE-1))]}"
    info "Generating netplan config for profile: ${BOLD}${CHOSEN}${RESET}"

    # Generate netplan YAML via Python and write it with sudo tee
    NETPLAN_CONTENT=$(python3 - "$PACKAGES_YAML" "$CHOSEN" <<'PYEOF'
import yaml, sys

with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)

p       = (cfg.get("network_profiles") or {})[sys.argv[2]]
iface   = p["interface"]
is_dhcp = p.get("dhcp", True)
dns     = p.get("dns", [])
search  = p.get("search_domains", [])
mtu     = p.get("mtu")

eth_cfg = {"dhcp4": is_dhcp}

if not is_dhcp:
    eth_cfg["addresses"] = [p["ip"]]
    eth_cfg["routes"]    = [{"to": "default", "via": p["gateway"]}]

if dns:
    ns = {"addresses": dns}
    if search:
        ns["search"] = search
    eth_cfg["nameservers"] = ns

if mtu:
    eth_cfg["mtu"] = int(mtu)

netplan = {"network": {"version": 2, "ethernets": {iface: eth_cfg}}}

print("# Generated by setup_dev.sh — edit packages.yaml to change profiles")
print(yaml.dump(netplan, default_flow_style=False).rstrip())
PYEOF
)

    echo "$NETPLAN_CONTENT" | sudo tee /etc/netplan/60-dev-setup.yaml > /dev/null
    success "Netplan config written → /etc/netplan/60-dev-setup.yaml"

    # Set hostname if the profile specifies one
    CHOSEN_HOST=$(python3 - "$PACKAGES_YAML" "$CHOSEN" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
print((cfg.get("network_profiles") or {}).get(sys.argv[2], {}).get("hostname") or "")
PYEOF
)
    if [[ -n "$CHOSEN_HOST" ]]; then
      info "Setting hostname to: ${BOLD}${CHOSEN_HOST}${RESET}"
      sudo hostnamectl set-hostname "$CHOSEN_HOST"
      success "Hostname set to ${CHOSEN_HOST}."
    fi

    if ask "Apply network config now? (sudo netplan apply)"; then
      try_cmd sudo netplan apply
      success "Network profile '${CHOSEN}' applied."
      warn "If you changed the IP of this SSH session, you may be disconnected."
    else
      warn "Config written but not applied. Run: sudo netplan apply"
    fi

  else
    warn "Skipped network profile."
  fi
fi

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════╗"
echo -e "║        Setup Complete!           ║"
echo -e "╚════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Next steps:${RESET}"
echo -e "  1. ${CYAN}Log out and back in${RESET} so the Docker group takes effect"
echo -e "     Or run ${CYAN}newgrp docker${RESET} in your current terminal for Docker immediately"
if $HAS_NVIDIA && ! $IS_JETPACK; then
  echo -e "  2. ${YELLOW}Reboot${RESET} to activate NVIDIA drivers, then run: ${CYAN}nvidia-smi${RESET}"
fi
echo -e "  3. Restart Terminator to pick up the white theme config"
if $IS_JETPACK; then
  echo -e "  4. Run ${CYAN}jtop${RESET} to monitor CPU/GPU/memory/thermals on your Jetson"
  echo -e "     Run ${CYAN}jetson_release${RESET} to view your L4T / Jetpack version details"
fi
echo -e "  5. To add/remove packages or network profiles, edit ${CYAN}${SCRIPT_DIR}/packages.yaml${RESET} and re-run"
echo ""