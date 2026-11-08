#!/usr/bin/env bash
# Conmuta el touchpad reescribiendo el flag "off" dentro del bloque
# input { touchpad { ... } } de niri. niri recarga el config solo al
# detectar el cambio en disco, asi que no hace falta senalizarlo.
set -euo pipefail
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/niri/config.kdl"

state=$(python3 - "$CONFIG" <<'PY'
import re, sys

path = sys.argv[1]
lines = open(path).read().split('\n')

# Localizar el bloque touchpad y su cierre por conteo de llaves.
start = next(i for i, l in enumerate(lines) if re.match(r'^\s*touchpad\s*\{', l))
depth, end = 0, None
for i in range(start, len(lines)):
    depth += lines[i].count('{') - lines[i].count('}')
    if depth == 0:
        end = i
        break

for i in range(start + 1, end):
    m = re.match(r'^(\s*)(//\s*)?off\s*$', lines[i])
    if not m:
        continue
    indent, commented = m.group(1), m.group(2)
    lines[i] = f'{indent}off' if commented else f'{indent}// off'
    open(path, 'w').write('\n'.join(lines))
    print('desactivado' if commented else 'activado')
    break
else:
    sys.exit('no se encontro la linea off en el bloque touchpad')
PY
)

command -v dms >/dev/null && dms ipc call toast info "Touchpad $state" >/dev/null 2>&1 || true
