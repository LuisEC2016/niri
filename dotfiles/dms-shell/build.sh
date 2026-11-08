#!/usr/bin/env bash
# Reconstruye el shell QML propio de DankMaterialShell: DMS v1.6.0 + los parches
# de patches/ (dock con magnificación y rebote estilo macOS, OSD y centro de
# control estilo macOS, notificaciones). systemd lo carga vía DMS_SHELL_DIR
# (ver ../systemd/user/dms.service.d/override.conf).
#
# Reemplaza al antiguo .patches/resync.sh, que copiaba la base desde
# /usr/share/quickshell/dms/quickshell. Esa base sigue al paquete del sistema
# (ya en 2.1.1, con otra estructura de archivos), así que los parches dejaban de
# aplicar en cuanto se actualizaba dms. Aquí la base va fijada a un commit.
#
# Comprobado el 2026-11-07: v1.6.0 (commit 0bbe8338) + submódulo
# dank-qml-common + los 10 parches reproduce byte a byte el
# ~/.local/share/dms-shell-custom que estaba en uso (diff -r vacío).
#
# Uso:
#   build.sh                 construye e instala en ~/.local/share/dms-shell-custom
#   build.sh --check         construye en un temporal y lo compara con lo instalado
#   build.sh --dest DIR      instala en DIR
set -euo pipefail

DMS_REPO=https://github.com/AvengeMedia/DankMaterialShell.git
DMS_TAG=v1.6.0
DMS_COMMIT=0bbe83380c9406d262d567581d64477d261c9ee5

here=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/.local/share/dms-shell-custom"
check=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check) check=1 ;;
        --dest) dest=$2; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Opción desconocida: $1" >&2; exit 2 ;;
    esac
    shift
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git clone -q --depth 1 --branch "$DMS_TAG" "$DMS_REPO" "$tmp/src" 2>/dev/null
got=$(git -C "$tmp/src" rev-parse HEAD)
if [ "$got" != "$DMS_COMMIT" ]; then
    echo "El tag $DMS_TAG apunta a $got, se esperaba $DMS_COMMIT. Abortando." >&2
    exit 1
fi
git -C "$tmp/src" submodule update -q --init --depth 1

# En el repo, quickshell/DankCommon es un enlace al submódulo; el paquete lo
# trae como directorio real, y así lo espera DMS_SHELL_DIR.
out="$tmp/shell"
cp -a "$tmp/src/quickshell" "$out"
rm "$out/DankCommon"
cp -a "$tmp/src/dank-qml-common/DankCommon" "$out/DankCommon"

fallidos=()
for p in "$here"/patches/*.patch; do
    nombre=$(basename "$p")
    if patch -p1 --forward --quiet -d "$out" -i "$p"; then
        echo "OK      $nombre"
    else
        echo "FALLO   $nombre"
        fallidos+=("$nombre")
    fi
done
if [ ${#fallidos[@]} -gt 0 ]; then
    echo "Parches sin aplicar: ${fallidos[*]}" >&2
    exit 1
fi
find "$out" -name '*.orig' -delete

if [ "$check" -eq 1 ]; then
    if diff -rq --exclude=.patches "$out" "$dest"; then
        echo "Idéntico a $dest"
    else
        echo "Difiere de $dest" >&2
        exit 1
    fi
    exit 0
fi

if [ -e "$dest" ]; then
    backup="$dest.bak-$(date +%s)"
    mv "$dest" "$backup"
    echo "Anterior guardado en $backup"
fi
mkdir -p "$(dirname "$dest")"
cp -a "$out" "$dest"
echo "Instalado en $dest. Reinicia: systemctl --user restart dms.service"
