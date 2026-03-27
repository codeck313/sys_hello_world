#!/usr/bin/bash
# patch_thor_jp7_in_repo.sh
# Patch a cloned jetson_stats repo for Jetson Thor on JetPack 7.0
# - Writes drop-in GPU shim (NVML-first, devfreq fallback) compatible with legacy GUI/service
# - Updates jetson_variables.py for Thor/JP7 mappings
# - Tweaks jtop/github.py message
# Usage: sudo bash mod_jtop_python_scripts_jp7_THOR.sh /opt/jtop/jetson_stats
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
  echo "ERROR: pass path to your cloned jetson_stats repo (e.g., /opt/jtop/jetson_stats)" >&2
  exit 1
fi
REPO_ROOT="${REPO_ROOT%/}"
[[ -d "$REPO_ROOT/jtop" ]] || { echo "ERROR: $REPO_ROOT does not look like a jetson_stats repo"; exit 1; }

ts() { date +%Y%m%d-%H%M%S; }
bk() { local f="$1"; [[ -f "$f" ]] && cp -a "$f" "$f.bak.$(ts)" || true; }

echo "==> Patching repo at: $REPO_ROOT"

# 1) Write drop-in GPU shim
GPU_PY="$REPO_ROOT/jtop/core/gpu.py"
mkdir -p "$(dirname "$GPU_PY")"
bk "$GPU_PY"

cat >"$GPU_PY" <<'PY'
# SPDX-License-Identifier: AGPL-3.0
# GPU shim for Jetson Thor / JetPack 7:
# - Prefer NVML (pynvml) for detection/metrics
# - Thanks to eous' jetson_stats pr that pointed the way to nvidia-ml-py3 (pynvml)
# - Fallback to /sys/class/devfreq (gpu-gpc-0)
# - Exposes legacy hooks/shape used by jtop service & GUI
from __future__ import annotations
import os, re, glob

try:
    from .exceptions import JtopException  # type: ignore
except Exception:  # pragma: no cover
    class JtopException(Exception): pass

def _read_int(p: str, d=None):
    try:
        with open(p) as f: return int(f.read().strip())
    except Exception:
        return d
def _read_str(p: str, d=None):
    try:
        with open(p) as f: return f.read().strip()
    except Exception:
        return d
def _exists(p: str) -> bool:
    try: return os.path.exists(p)
    except Exception: return False

def _compat_find_3d_scaling(sysfs_path: str | None) -> bool:
    try:
        if not sysfs_path: return False
        p = os.path.join(sysfs_path, "device")
        for _ in range(6):
            cand = os.path.join(p, "enable_3d_scaling")
            try:
                with open(cand) as f:
                    v = f.read().strip()
                return v in ("1","Y","y","true","True")
            except Exception:
                p = os.path.dirname(p)
        return False
    except Exception:
        return False

def _compat_find_railgate(sysfs_path: str | None) -> bool:
    try:
        if not sysfs_path: return False
        p = os.path.join(sysfs_path, "device")
        candidates = ("railgate_enable", "railgate", os.path.join("power","railgate"), os.path.join("power","railgate_enable"))
        for _ in range(6):
            for rel in candidates:
                cand = os.path.join(p, rel)
                try:
                    with open(cand) as f:
                        v = f.read().strip()
                    return v in ("1","Y","y","true","True")
                except Exception:
                    pass
            p = os.path.dirname(p)
        return False
    except Exception:
        return False

def _i(x):
    try:
        return 0 if x is None else int(x)
    except Exception:
        return 0

def _build_entry(flat: dict) -> dict:
    """Return nested entry + top-level aliases expected by GUI."""
    t = flat.get("type") or "integrated"
    cur = _i(flat.get("cur_freq"))
    mx  = _i(flat.get("max_freq"))
    mn  = _i(flat.get("min_freq"))
    gov = flat.get("governor")
    online = bool(flat.get("online"))
    load = _i(flat.get("load"))

    scaling3d = _compat_find_3d_scaling(flat.get("sysfs_path"))
    railgate  = _compat_find_railgate(flat.get("sysfs_path"))

    nested = {
        "type": t,
        "status": {
            "online": online,
            "load": load,
            "3d_scaling": scaling3d,
            "railgate": railgate,
            "freq": {"cur": cur, "max": mx, "min": mn},
            "cur_freq": cur,
            "max_freq": mx,
            "min_freq": mn,
            "governor": gov,
        },
        "info": {
            "name":    flat.get("name"),
            "product": flat.get("product"),
            "memory_total": flat.get("memory_total"),
            "memory_used":  flat.get("memory_used"),
            "source":  flat.get("source"),
            "sysfs_path": flat.get("sysfs_path"),
        },
    }
    # Top-level aliases used by older GUI code
    nested["freq"]        = nested["status"]["freq"]
    nested["online"]      = online
    nested["load"]        = load
    nested["cur_freq"]    = cur
    nested["max_freq"]    = mx
    nested["min_freq"]    = mn
    nested["governor"]    = gov
    nested["3d_scaling"]  = scaling3d
    nested["railgate"]    = railgate
    scaling_str  = "Active" if scaling3d else "Disable"
    railgate_str = "Active" if railgate else "Disable"
    nested["power_control"] = f"3D-scaling: {scaling_str} | Railgate: {railgate_str}"
    nested["name"]        = nested["info"]["name"]
    nested["product"]     = nested["info"]["product"]
    return nested

class GPU(dict):
    """NVML-first, devfreq-fallback GPU map with legacy GUI/service compatibility."""
    def __init__(self):
        super().__init__()
        self._nvml_ok = False
        self._nvml = None
        try:
            import pynvml as _nvml
            _nvml.nvmlInit()
            self._nvml = _nvml
            self._nvml_ok = True
        except Exception:
            self._nvml = None
            self._nvml_ok = False
        self.update()

    # discovery paths
    def _read_nvml(self) -> dict:
        nv = self._nvml
        if not nv: return {}
        out = {}
        try:
            count = nv.nvmlDeviceGetCount()
        except Exception:
            return {}
        for idx in range(count):
            try:
                h = nv.nvmlDeviceGetHandleByIndex(idx)
                pname = nv.nvmlDeviceGetName(h)
                if isinstance(pname, bytes): pname = pname.decode(errors="ignore")
                try:
                    util = nv.nvmlDeviceGetUtilizationRates(h).gpu
                except Exception:
                    util = None
                def _clk(t):
                    try: return int(nv.nvmlDeviceGetClockInfo(h, t)) * 1_000_000
                    except Exception: return None
                cur = _clk(nv.NVML_CLOCK_GRAPHICS)
                try:
                    mx = int(nv.nvmlDeviceGetMaxClockInfo(h, nv.NVML_CLOCK_GRAPHICS)) * 1_000_000
                except Exception:
                    mx = None
                try:
                    mem = nv.nvmlDeviceGetMemoryInfo(h)
                    mt, mu = int(mem.total), int(mem.used)
                except Exception:
                    mt = mu = None
                key = f"gpu{idx}"
                out[key] = {
                    "name": key,
                    "product": pname,
                    "source": "nvml",
                    "online": True,
                    "load": 0 if util is None else int(util),
                    "cur_freq": cur,
                    "max_freq": mx,
                    "min_freq": None,
                    "governor": None,
                    "sysfs_path": None,
                    "memory_total": mt,
                    "memory_used":  mu,
                    "type": "integrated",
                }
            except Exception:
                continue
        return out

    def _read_sysfs(self) -> dict:
        base = "/sys/class/devfreq"
        if not _exists(base): return {}
        nodes = []
        for d in glob.glob(os.path.join(base, "*")):
            name = None
            npath = os.path.join(d, "device", "of_node", "name")
            if _exists(npath): name = _read_str(npath, None)
            if not name: name = os.path.basename(d)
            if (re.match(r"^g[a-z0-9]+b$", name or "") is not None) or name == "gpu" or (name or "").startswith("gpu-"):
                nodes.append((name, d))
        out = {}
        for idx, (name, path) in enumerate(nodes):
            key = name if name else f"gpu{idx}"
            out[key] = {
                "name": key,
                "product": None,
                "source": "sysfs",
                "online": True,
                "load": _read_int(os.path.join(path, "load")) or 0,
                "cur_freq": _read_int(os.path.join(path, "cur_freq")),
                "max_freq": _read_int(os.path.join(path, "max_freq")),
                "min_freq": _read_int(os.path.join(path, "min_freq")),
                "governor": _read_str(os.path.join(path, "governor")),
                "sysfs_path": path,
                "memory_total": None,
                "memory_used":  None,
                "type": "integrated",
            }
        return out

    # public / legacy API
    def update(self):
        try:
            flat = self._read_nvml() if self._nvml_ok else {}
            if not flat:
                flat = self._read_sysfs()
        except Exception:
            flat = {}
        try:
            self.clear()
            for k, v in (flat or {}).items():
                self[k] = _build_entry(v if isinstance(v, dict) else {})
        except Exception:
            pass

    refresh = update

    def get_status(self) -> dict:
        """Return nested snapshot (GUI/service expected shape)."""
        try:
            self.update()
        except Exception:
            pass
        return {k: dict(v) if isinstance(v, dict) else v for k, v in self.items()}

    # Legacy hooks
    def _initialize(self, controller):  # jtop.py expects this
        try: self._controller = controller
        except Exception: pass
        try: self.update()
        except Exception: pass

    def _finalize(self):                # jtop.py expects this
        return None

    def _update(self, dest: dict):      # jtop.py expects this
        snap = {}
        try: snap = self.get_status()
        except Exception: pass
        if isinstance(dest, dict):
            dest.clear()
            dest.update(snap or {})
        return dest

# Legacy alias for service.py
class GPUService(GPU):
    """Compatibility alias with same behavior as GPU."""
    pass

# Legacy helper for github.py diagnostics
def get_raw_igpu_devices():
    devices = []
    base = "/sys/class/devfreq"
    if os.path.isdir(base):
        for d in sorted(glob.glob(os.path.join(base, "*"))):
            name_path = os.path.join(d, "device", "of_node", "name")
            name = _read_str(name_path, None) or os.path.basename(d)
            if (re.match(r"^g[a-z0-9]+b$", name or "") is not None) or name == "gpu" or (name or "").startswith("gpu-"):
                devices.append(d)
    try:
        import pynvml as nv
        nv.nvmlInit()
        try:
            count = nv.nvmlDeviceGetCount()
            for i in range(count):
                devices.append(f"nvml:gpu{i}")
        finally:
            try: nv.nvmlShutdown()
            except Exception: pass
    except Exception:
        pass
    return devices
PY

echo "   wrote $GPU_PY"

# 2) Patch jetson_variables.py for (Thor & JP7)
VARS_PY="$REPO_ROOT/jtop/core/jetson_variables.py"
if [[ -f "$VARS_PY" ]]; then
  bk "$VARS_PY"
  # JP/L4T->JetPack mappings
  grep -qE '^\s*"38\.2\.1":\s*"7\.0",' "$VARS_PY" || \
    sed -i '/# -------- JP6 --------/a\    "38.2.0": "7.0",' "$VARS_PY"
  grep -qE '^\s*"38\.2\.0":\s*"7\.0",' "$VARS_PY" || \
    sed -i '/# -------- JP6 --------/a\    "38.2.0": "7.0",' "$VARS_PY"
  grep -qE '^\s*"36\.4\.4":\s*"6\.2\.1",' "$VARS_PY" || \
    sed -i '/# -------- JP6 --------/a\    "36.4.4": "6.2.1",' "$VARS_PY"
  # CUDA table for Thor
  grep -qE "^\s*'tegra264':\s*'13\.0'," "$VARS_PY" || \
    sed -i "/'tegra234':/i\    'tegra264': '13.0', # JETSON THOR - tegra264" "$VARS_PY"
  # Module name table
  grep -qE "^\s*'p3834-0008':\s*'NVIDIA Jetson AGX Thor  \(Developer kit\)'," "$VARS_PY" || \
    sed -i "/'p3767-0005':/i\    'p3834-0008': 'NVIDIA Jetson AGX Thor  (Developer kit)'," "$VARS_PY"
  echo "   patched $VARS_PY"
else
  echo "   skip: $VARS_PY not found"
fi

# 3) Patch jtop/github.py (insert warning line once)
GH_PY="$REPO_ROOT/jtop/github.py"
if [[ -f "$GH_PY" ]]; then
  bk "$GH_PY"
  if ! grep -q 'rollback jtop to not functioning on Thor' "$GH_PY"; then
    python3 - "$GH_PY" <<'PY'
import re, sys
p=sys.argv[1]
with open(p, 'r', encoding='utf-8') as f:
    s=f.read()

# Try the common anchor first (exact format call), then a looser fallback
anchor1 = r'(print\(\s*"\[\{status\}\]\s\{message\}"\.format\(status=bcolors\.warning\(\),\s*message=message\)\s*\)\s*\n)'
anchor2 = r'(print\(\s*"\[\{status\}\]\s\{message\}"\.format\([^)]*\)\s*\)\s*\n)'
insert  = '    print("  For now, ignore the next 2 lines or it will rollback jtop to not functioning on Thor".format(bold=bcolors.BOLD, reset=bcolors.ENDC))\n'

s2, n = re.subn(anchor1, r'\1' + insert, s, count=1)
if n == 0:
    s2, n = re.subn(anchor2, r'\1' + insert, s, count=1)

if n:
    with open(p, 'w', encoding='utf-8') as f:
        f.write(s2)
    print(f"   patched {p} (inserted 1)")
else:
    sys.stderr.write(f"WARNING: Could not find anchor in {p}; skipping insert.\n")
PY
  else
    echo "   note already present in $GH_PY"
  fi
else
  echo "   skip: $GH_PY not found"
fi

echo "==> Thor/JP7 patching complete."
echo "pip will now install this jetson_stats repo, and 'nvidia-ml-py3*.whl' into the jtop venv."
