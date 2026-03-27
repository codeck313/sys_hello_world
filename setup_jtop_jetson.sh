#!/usr/bin/bash
# Setup jtop in a root-owned venv at /opt/jtop with Thor edits applied
# Tested on Ubuntu 24.04 (JetPack 7.x base)

set -euo pipefail

JTOP_ROOT="/opt/jtop"
VENV_DIR="$JTOP_ROOT/venv"
REPO_DIR="$JTOP_ROOT/jetson_stats"
SERVICE_PATH="/etc/systemd/system/jtop.service"
REPO_URL="https://github.com/rbonghi/jetson_stats.git"

need_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "Please run as root (e.g., sudo bash $0)"
    exit 1
  fi
}

log() { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m[warn]\e[0m $*"; }
info() { echo -e "\e[1;34m[info]\e[0m $*"; }

install_prereqs() {
  log "Installing prerequisites (python3.12-venv, git)…"
  apt-get update -y
  # Prefer python3.12-venv (Noble default); fallback to python3-venv if needed
  if ! apt-get install -y python3.12-venv git; then
    warn "python3.12-venv not found; trying python3-venv"
    apt-get install -y python3-venv git
  fi
}

create_venv() {
  log "Creating root-owned venv at $VENV_DIR"
  mkdir -p "$JTOP_ROOT"
  if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
  else
    info "Venv already exists: $VENV_DIR"
  fi
  "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
}

clone_repo() {
  log "Cloning jetson_stats into $REPO_DIR"
  if [[ -d "$REPO_DIR/.git" ]]; then
    info "Repo exists, pulling latest…"
    git -C "$REPO_DIR" fetch --all --tags
    git -C "$REPO_DIR" reset --hard origin/master
  else
    git clone --depth=1 "$REPO_URL" "$REPO_DIR"
  fi
}

apply_thor_edits() {
  log "Applying Thor edits to repository files"
  local f_vars="$REPO_DIR/jtop/core/jetson_variables.py"
  local f_gh="$REPO_DIR/jtop/github.py"
  local f_svc="$REPO_DIR/services/jtop.service"

  for f in "$f_vars" "$f_gh" "$f_svc"; do
    [[ -f "$f" ]] || { echo "ERROR: Missing $f"; exit 1; }
    cp -a "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
  done

  # jetson_variables.py edits
  # Add JP/L4T mappings
  grep -qE '^\s*"38\.2\.0":\s*"7\.0",' "$f_vars" || \
    sed -i '/# -------- JP6 --------/a\    "38.2.1": "7.0",' "$f_vars"
  grep -qE '^\s*"38\.2\.0":\s*"7\.0",' "$f_vars" || \
    sed -i '/# -------- JP6 --------/a\    "38.2.0": "7.0",' "$f_vars"
  grep -qE '^\s*"36\.4\.4":\s*"6\.2\.1",' "$f_vars" || \
    sed -i '/# -------- JP6 --------/a\    "36.4.4": "6.2.1",' "$f_vars"

  # Add CUDA_TABLE tegra264
  grep -qE "^\s*'tegra264':\s*'13\.0'," "$f_vars" || \
    sed -i "/'tegra234':/i\    'tegra264': '13.0', # JETSON THOR - tegra264" "$f_vars"

  # Add MODULE_NAME_TABLE p3834-0008
  grep -qE "^\s*'p3834-0008':\s*'NVIDIA Jetson AGX Thor  \(Developer kit\)'," "$f_vars" || \
    sed -i "/'p3767-0005':/i\    'p3834-0008': 'NVIDIA Jetson AGX Thor  (Developer kit)'," "$f_vars"

  # services/jtop.service in repo: ensure only venv ExecStart
  # Replace /usr/local/bin path with venv path if present
  if grep -q '^ExecStart=/usr/local/bin/jtop --force$' "$f_svc"; then
    sed -i 's#^ExecStart=/usr/local/bin/jtop --force#ExecStart=/opt/jtop/venv/bin/jtop --force#' "$f_svc"
  fi
  # Remove any duplicate /usr/local/bin ExecStart lines
  sed -i '/^ExecStart=\/usr\/local\/bin\/jtop --force$/d' "$f_svc"
  # Ensure one venv ExecStart exists after Environment= line
  grep -q '^ExecStart=/opt/jtop/venv/bin/jtop --force$' "$f_svc" || \
    sed -i '/^Environment="JTOP_SERVICE=True"$/a\ExecStart=/opt/jtop/venv/bin/jtop --force' "$f_svc"

  log "Thor edits applied."
}

install_python_fixes() {
  set -euo pipefail
  local repo="/opt/jtop/jetson_stats"
  local patch="$(dirname "$0")/patch_thor_jp7_in_repo.sh"  # patch in same dir as instant one.

  log "Installing python script changes for Jetson Thor (JP7.0) in: $repo"

  [[ -d "$repo/.git" && -d "$repo/jtop" ]] || {
    echo "ERROR: $repo does not look like a jetson_stats clone"; return 1; }

  chmod +x "$patch"
  # Run as its own process; it will sudo itself if needed.
  "$patch" "$repo"
}

install_package() {
  log "Installing jetson_stats into the venv"
  "$VENV_DIR/bin/python" -m pip install --no-cache-dir -U "$REPO_DIR"
}

install_nvml() {
  set -euo pipefail
  log "Installing NVML bindings (pynvml) into the venv"

  : "${VENV_DIR:?VENV_DIR must be set (e.g. /opt/jtop/venv)}"
  local py="$VENV_DIR/bin/python"
  if [[ ! -x "$py" ]]; then
    echo "ERROR: $py not found/executable" >&2
    return 1
  fi

  "$py" -m pip install -U nvidia-ml-py
}

install_service() {
  log "Installing systemd service at $SERVICE_PATH"
  cat >"$SERVICE_PATH" <<'EOF'
# Jetson Stats (jtop) systemd unit using root-owned venv at /opt/jtop/venv
[Unit]
Description=Jetson Stats (jtop)
After=network.target multi-user.target

[Service]
Environment="JTOP_SERVICE=True"
Type=simple
ExecStart=/opt/jtop/venv/bin/jtop --force
Restart=on-failure
RestartSec=10s
TimeoutStartSec=30s
TimeoutStopSec=30s

[Install]
WantedBy=multi-user.target
EOF

  # Wrapper so `sudo jtop` works nicely from PATH
  log "Installing /usr/local/bin/jtop wrapper"
  install -m 0755 -o root -g root /dev/stdin /usr/local/bin/jtop <<'EOF'
#!/bin/sh
exec /opt/jtop/venv/bin/jtop "$@"
EOF

  # Create system group (ok if it already exists)
  groupadd --system jtop 2>/dev/null || true

  log "Reloading/Enabling/Restarting service"
  systemctl daemon-reload
  systemctl enable jtop.service
  systemctl restart jtop.service || true
  systemctl is-active --quiet jtop.service && log "jtop.service is active" || warn "jtop.service not active yet"
}

show_summary() {
  echo
  log "Done."
  echo "Quick checks:"
  echo "  systemctl status jtop.service --no-pager"
  echo "  journalctl -u jtop --no-pager -e"
  echo
  echo "Run interactively with:"
  echo "  sudo jtop"
}

main() {
  need_root
  install_prereqs
  create_venv
  clone_repo
  apply_thor_edits
  install_python_fixes
  install_package
  install_nvml
  install_service
  show_summary
}

main "$@"
