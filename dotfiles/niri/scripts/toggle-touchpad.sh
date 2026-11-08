#!/usr/bin/env bash
# Conmuta el touchpad reescribiendo el flag "off" dentro del bloque
# input { touchpad { ... } } de niri. niri recarga el config solo al
# detectar el cambio en disco, asi que no hace falta senalizarlo.
#
# Todo en bash, sin procesos aparte: antes lo hacia un python3 (~30 ms y
# ~10 MB por pulsacion). Se escribe con una redireccion sobre el mismo archivo,
# que atraviesa el enlace: ~/.config/niri/config.kdl apunta al repo, y un
# `sed -i` o un mv lo sustituirian por un archivo normal.
set -euo pipefail
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/niri/config.kdl"

# Archivo entero, y una entrada por linea. El salto que anade <<< hace que un
# archivo terminado en salto de linea acabe en una entrada vacia, asi el join
# de abajo lo deja byte a byte como estaba.
IFS= read -r -d '' text <"$CONFIG" || true
mapfile -t lines <<<"$text"

# Localizar el bloque touchpad y su cierre por conteo de llaves.
start=-1
for i in "${!lines[@]}"; do
    if [[ ${lines[i]} =~ ^[[:space:]]*touchpad[[:space:]]*\{ ]]; then
        start=$i
        break
    fi
done
if [ "$start" -lt 0 ]; then
    echo "no se encontro el bloque touchpad en $CONFIG" >&2
    exit 1
fi

depth=0 end=-1
for ((i = start; i < ${#lines[@]}; i++)); do
    open=${lines[i]//[^\{]/}
    close=${lines[i]//[^\}]/}
    depth=$((depth + ${#open} - ${#close}))
    if [ "$depth" -eq 0 ]; then
        end=$i
        break
    fi
done
if [ "$end" -lt 0 ]; then
    echo "el bloque touchpad de $CONFIG no se cierra" >&2
    exit 1
fi

for ((i = start + 1; i < end; i++)); do
    [[ ${lines[i]} =~ ^([[:space:]]*)(//[[:space:]]*)?off[[:space:]]*$ ]] || continue
    indent=${BASH_REMATCH[1]}
    if [ -n "${BASH_REMATCH[2]}" ]; then
        lines[i]="${indent}off"
        state=desactivado
    else
        lines[i]="${indent}// off"
        state=activado
    fi
    printf -v text '%s\n' "${lines[@]}"
    printf '%s' "${text%$'\n'}" >"$CONFIG"
    command -v dms >/dev/null && dms ipc call toast info "Touchpad $state" >/dev/null 2>&1 || true
    exit 0
done

echo "no se encontro la linea off en el bloque touchpad" >&2
exit 1
