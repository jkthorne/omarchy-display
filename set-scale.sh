#!/usr/bin/env bash
# Persist Display-panel scale. When hyprmoncfg owns monitor config, Omarchy's
# stock writer only updates monitors.lua, then hyprmoncfg reloads last and the
# daemon reapplies the old profile. Save the scale into hyprmoncfg instead.

set -euo pipefail

usage() {
  echo "Usage: set-scale.sh [up|down|SCALE]" >&2
}

hyprmoncfg_managing() {
  command -v hyprmoncfg >/dev/null 2>&1 || return 1
  [[ -f ${XDG_CONFIG_HOME:-$HOME/.config}/hyprmoncfg/unmanaged ]] && return 1
  grep -q 'hyprmoncfg-monitors.lua' "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua" 2>/dev/null
}

if ! hyprmoncfg_managing; then
  exec omarchy-hyprland-monitor-scaling "$@"
fi

if (($# < 1)); then
  usage
  exit 1
fi

requested="$1"
export REQUESTED_SCALE="$requested"

python3 - "$requested" <<'PY'
import json, math, os, socket, subprocess, sys
from pathlib import Path

requested = sys.argv[1]
home = Path(os.environ["HOME"])
config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
state = Path(os.environ.get("XDG_STATE_HOME", home / ".local" / "state"))
runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
profiles_dir = config / "hyprmoncfg" / "profiles"
monitor_lua = config / "hypr" / "monitors.lua"
generated_lua = config / "hypr" / "hyprmoncfg-monitors.lua"
internal_scale_path = state / "omarchy" / "toggles" / "hypr" / "internal-monitor-scale"
sock_path = runtime / "hyprmoncfgd.sock"


def run_json(args):
    return json.loads(subprocess.check_output(args, text=True))


def gcd(a, b):
    while b:
        a, b = b, a % b
    return a


def clean_scale(scale, width, height):
    g = gcd(int(width) * 120, int(height) * 120)
    k = int(round(float(scale) * 120))
    if k > g:
        k = g
    if k <= 0:
        k = 1
    while g % k != 0:
        k += 1
    value = k / 120
    return int(value) if value == int(value) else float(f"{value:g}")


def normalize_scale(value):
    n = float(value)
    return int(n) if n == int(n) else float(f"{n:g}")


monitors = run_json(["hyprctl", "monitors", "-j"])
focused = next((m for m in monitors if m.get("focused")), None)
if not focused:
    sys.exit("no focused monitor")

width = int(focused["width"])
height = int(focused["height"])
current = float(focused["scale"])
presets = [1, 1.25, 1.6, 2, 3, 4]


def effective(preset):
    return clean_scale(preset, width, height)


if requested in ("up", "down"):
    uniq = []
    seen = set()
    for preset in presets:
        key = f"{effective(preset):.8f}"
        if key in seen:
            continue
        seen.add(key)
        uniq.append(preset)
    best = min(range(len(uniq)), key=lambda i: abs(effective(uniq[i]) - current))
    if requested == "up":
        best = min(best + 1, len(uniq) - 1)
    else:
        best = max(best - 1, 0)
    new_scale = effective(uniq[best])
else:
    try:
        raw = float(requested)
    except ValueError:
        sys.exit(f"invalid scale: {requested}")
    if not 1 <= raw <= 4:
        sys.exit(f"scale out of range: {requested}")
    new_scale = clean_scale(raw, width, height)

new_gdk = int(round(float(new_scale)))
name = focused["name"]
x = int(focused.get("x") or 0)
y = int(focused.get("y") or 0)
refresh = focused.get("refreshRate") or 0
mode = f"{width}x{height}@{refresh}"
desc = str(focused.get("description") or "")
make = str(focused.get("make") or "")
model = str(focused.get("model") or "")
serial = str(focused.get("serial") or "")
internal = bool(focused.get("internal")) or name.startswith("eDP")


def output_matches(output):
    if not isinstance(output, dict):
        return False
    if desc and str(output.get("description") or "") == desc:
        return True
    if name and str(output.get("name") or "") == name:
        return True
    key = f"{make}|{model}|{serial}".lower().strip("|")
    for field in ("key", "match_key"):
        value = str(output.get(field) or "").lower()
        if value and (value == key or value in key or key in value):
            return True
    if make and model:
        if str(output.get("make") or "") == make and str(output.get("model") or "") == model:
            return True
    return False


def ipc(method, params=None):
    payload = {
        "type": "request",
        "protocol_version": 1,
        "id": method,
        "method": method,
    }
    if params is not None:
        payload["params"] = params
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(8)
        sock.connect(str(sock_path))
        sock.sendall((json.dumps(payload) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    reply = json.loads(data.decode())
    if reply.get("error"):
        raise RuntimeError(reply["error"].get("message") or "hyprmoncfg ipc error")
    result = reply.get("result")
    if isinstance(result, str):
        try:
            return json.loads(result)
        except json.JSONDecodeError:
            return result
    return result


def save_profile(profile):
    if sock_path.exists():
        ipc("save", {"profile": profile})
        return
    subprocess.check_call(["hyprmoncfg", "save", profile["name"]], stdout=subprocess.DEVNULL)


def load_profiles():
    profiles = []
    if not profiles_dir.is_dir():
        return profiles
    for path in sorted(profiles_dir.glob("*.json")):
        try:
            profiles.append(json.loads(path.read_text()))
        except (OSError, json.JSONDecodeError):
            continue
    return profiles


# Keep the current arrangement; position=auto would shuffle a docked layout.
subprocess.check_call(
    [
        "hyprctl",
        "keyword",
        "monitor",
        f"{name},{mode},{x}x{y},{new_scale}",
    ],
    stdout=subprocess.DEVNULL,
)

updated_names = []
for profile in load_profiles():
    outputs = profile.get("outputs") or []
    changed = False
    for output in outputs:
        if not output_matches(output):
            continue
        if abs(float(output.get("scale") or 0) - float(new_scale)) < 0.001:
            updated_names.append(profile.get("name") or "")
            continue
        output["scale"] = float(new_scale)
        changed = True
    if changed:
        save_profile(profile)
        updated_names.append(profile.get("name") or "")

status = None
if sock_path.exists():
    try:
        status = ipc("status")
    except Exception:
        status = None

apply_name = None
if status:
    recommended = status.get("recommended_profile") or {}
    apply_name = recommended.get("name") or None
    if not apply_name:
        active = status.get("active_profile") or {}
        apply_name = active.get("name") or None
if not apply_name and updated_names:
    apply_name = next((n for n in updated_names if n), None)
if not apply_name:
    apply_name = "laptop"
    subprocess.check_call(["hyprmoncfg", "save", apply_name])

subprocess.check_call(
    ["hyprmoncfg", "apply", apply_name, "--confirm-timeout", "0"],
    stdout=subprocess.DEVNULL,
)

if internal:
    internal_scale_path.parent.mkdir(parents=True, exist_ok=True)
    internal_scale_path.write_text(f"{normalize_scale(new_scale)}\n")

if monitor_lua.is_file():
    text = monitor_lua.read_text()
    updated = []
    for line in text.splitlines(True):
        if line.startswith("local omarchy_gdk_scale = "):
            updated.append(f"local omarchy_gdk_scale = {new_gdk}\n")
        elif 'hl.env("GDK_SCALE"' in line:
            updated.append(f'hl.env("GDK_SCALE", "{new_gdk}")\n')
        else:
            updated.append(line)
    if "".join(updated) != text:
        monitor_lua.write_text("".join(updated))

print(normalize_scale(new_scale))
PY
