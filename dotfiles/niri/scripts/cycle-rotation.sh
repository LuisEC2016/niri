#!/usr/bin/env bash
# Rota la salida enfocada 90 grados por pulsacion. La tecla KEY_ROTATE_DISPLAY
# (evdev 153 -> XF86RotateWindows) del MSI MS-15H4 la dispara.
# El transform vive en outputs[<name>].logical.transform y niri lo devuelve
# capitalizado ("Normal", "_90"), asi que se normaliza antes de comparar.
set -euo pipefail

read -r out cur < <(niri msg --json outputs | python3 -c '
import json, sys, subprocess
name = json.loads(subprocess.run(
    ["niri", "msg", "--json", "focused-output"],
    capture_output=True, text=True).stdout)["name"]
o = json.load(sys.stdin)[name]
print(name, str(o["logical"].get("transform", "normal")).lower().lstrip("_"))
')

case "$cur" in
    normal) next=90 ;;
    90)     next=180 ;;
    180)    next=270 ;;
    *)      next=normal ;;
esac

niri msg output "$out" transform "$next"
command -v dms >/dev/null && dms ipc call toast info "Pantalla: $next" >/dev/null 2>&1 || true
