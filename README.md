# sys_hello_world
For when you get that shiny new system, but you don't wanna be a sys-admin...

This is an interactive setup script for a fresh Ubuntu install.

## What it installs

| Tool | Notes |
|---|---|
| **Terminator** | Terminal emulator |
| **Ghostty** | GPU-accelerated terminal (via snap) |
| **btop** | Resource monitor |
| **tmux** | Terminal multiplexer |
| **NVIDIA drivers** | Auto-detects recommended version |
| **Docker Engine** | Official Docker CE with compose plugin |
| **NVIDIA Container Toolkit** | GPU passthrough in Docker (`--gpus all`) |
| **Zsh** | Set as default shell with plugins + Spaceship prompt |
| **ROS 2** | Jazzy (Ubuntu 24.04) or Humble (Ubuntu 22.04), with colcon, rosdep, CycloneDDS |
| **Base tooling** | git, fzf (via mise), ripgrep, fd, bat, zoxide, neovim, thefuck, and more |

## Usage

```bash
chmod +x setup_dev.sh
./setup_dev.sh
```

Every major step asks for confirmation before doing anything — you can skip anything you don't need.

## Structure

```
setup_dev/
├── setup_dev.sh        # the installer
└── dotfiles/
    ├── .zshrc          # zsh config, plugins, aliases, ROS2 helpers
    └── ghostty/
        └── config      # ghostty keybinds and settings
```

Dotfiles are copied from the `dotfiles/` directory into your home folder. Existing files are automatically backed up with a timestamp before being overwritten. To update your config on any machine, just edit the files in `dotfiles/` and re-run the deploy step.

## After running

1. **Log out and back in** — activates Zsh as default shell and Docker group membership
2. **Reboot** — required after NVIDIA driver installation
3. Open a new terminal — Zsh plugins will auto-clone from GitHub on first launch

## Docker without sudo

The script follows the official Docker post-install steps: creates the `docker` group, adds your user, and fixes `~/.docker` directory ownership. Run `newgrp docker` in your current terminal to activate immediately without a full logout.

## NVIDIA + Docker

Two modes are offered during setup:
- **Standard** — daemon runs as root, GPU access via group membership (recommended for most setups)
- **Rootless** — daemon runs entirely as your user, GPU access via `~/.config/docker/daemon.json`