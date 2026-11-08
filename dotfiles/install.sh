#!/usr/bin/env bash
# Instala el escritorio completo desde este repositorio: el compositor niri
# compilado con los cambios propios, su configuración, y el shell DMS con el
# dock estilo macOS. Ver README.md.
#
# Uso: dotfiles/install.sh [--dry-run] [config|dms-shell|niri|all]...
#
#   config      Enlaza la config de niri, los scripts y la plantilla de matugen
#               a este repo; copia los ajustes de DMS y las unidades de systemd.
#   dms-shell   Reconstruye ~/.local/share/dms-shell-custom (dms-shell/build.sh).
#   niri        cargo build --release e instala en /usr/local/bin/niri (sudo).
#   all         Las tres cosas (por defecto).
#
# Nada se pisa sin copia: un archivo distinto que ya exista se renombra a
# <archivo>.bak-repo-<epoch> antes de reemplazarlo.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
dry=0
stamp=$(date +%s)

run() {
    if [ "$dry" -eq 1 ]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# Aparta el destino si existe y no es ya lo que se va a poner.
backup() {
    local dst=$1
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        run mv "$dst" "$dst.bak-repo-$stamp"
        echo "  copia: $dst.bak-repo-$stamp"
    fi
}

# Enlace simbólico dst -> src. Los archivos enlazados se editan en el repo.
link() {
    local src=$1 dst=$2
    if [ "$(readlink -f "$dst" 2>/dev/null)" = "$src" ]; then
        return 0
    fi
    run mkdir -p "$(dirname "$dst")"
    backup "$dst"
    run ln -s "$src" "$dst"
    echo "enlace: $dst -> $src"
}

# Copia src a dst pasando el contenido por un filtro (stdin -> stdout).
# Para archivos que su programa reescribe (DMS) o que llevan rutas absolutas.
install_copy() {
    local src=$1 dst=$2 filter=${3:-cat}
    local tmp
    tmp=$(mktemp)
    $filter <"$src" >"$tmp"
    if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        return 0
    fi
    run mkdir -p "$(dirname "$dst")"
    backup "$dst"
    run install -m 644 "$tmp" "$dst"
    rm -f "$tmp"
    echo "copia:  $dst"
}

home_paths() { sed "s#/home/luis/#$HOME/#g"; }

do_config() {
    local cfg=${XDG_CONFIG_HOME:-$HOME/.config}

    # niri. custom/futurista.kdl y dms/*.kdl NO se enlazan: los generan matugen
    # y DMS, y escribirían dentro del repo. config.kdl los incluye con
    # optional=true para que una instalación limpia arranque sin ellos.
    link "$here/niri/config.kdl" "$cfg/niri/config.kdl"
    for f in "$here"/niri/custom/*.kdl; do
        link "$f" "$cfg/niri/custom/$(basename "$f")"
    done
    for f in "$here"/niri/scripts/*.sh; do
        link "$f" "$cfg/niri/scripts/$(basename "$f")"
    done

    # matugen: la plantilla se enlaza; config.toml lleva rutas absolutas.
    link "$here/matugen/templates/niri-futurista.kdl" "$cfg/matugen/templates/niri-futurista.kdl"
    install_copy "$here/matugen/config.toml" "$cfg/matugen/config.toml" home_paths

    # DMS reescribe sus JSON al cambiar un ajuste, y una escritura atómica
    # sustituiría el enlace por un archivo: se copian.
    install_copy "$here/dms/settings.json" "$cfg/dms/settings.json"
    install_copy "$here/dms/plugin_settings.json" "$cfg/dms/plugin_settings.json"

    install_copy "$here/systemd/user/power-profile-auto.service" \
        "$cfg/systemd/user/power-profile-auto.service"
    install_copy "$here/systemd/user/dms.service.d/override.conf" \
        "$cfg/systemd/user/dms.service.d/override.conf"
    run systemctl --user daemon-reload
    run systemctl --user enable power-profile-auto.service
}

do_dms_shell() {
    if [ "$dry" -eq 1 ]; then
        echo "[dry-run] $here/dms-shell/build.sh"
        "$here/dms-shell/build.sh" --check || true
    else
        "$here/dms-shell/build.sh"
    fi
}

do_niri() {
    run cargo build --release --manifest-path "$repo/Cargo.toml"
    # /usr/local/bin va antes que /usr/bin en el PATH, y niri.service arranca
    # `niri --session` por PATH. Borrar /usr/local/bin/niri vuelve al de la distro.
    if [ -e /usr/local/bin/niri ]; then
        run sudo install -Dm755 /usr/local/bin/niri /usr/local/libexec/niri.prev
    fi
    run sudo install -m755 "$repo/target/release/niri" /usr/local/bin/niri
    echo "Instalado. Validar: niri validate; aplicar: cerrar sesión y volver a entrar."
}

targets=()
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) dry=1 ;;
        config|dms-shell|niri) targets+=("$arg") ;;
        all) targets+=(config dms-shell niri) ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "Argumento desconocido: $arg" >&2; exit 2 ;;
    esac
done
[ ${#targets[@]} -gt 0 ] || targets=(config dms-shell niri)

for t in "${targets[@]}"; do
    echo "== $t"
    case "$t" in
        config) do_config ;;
        dms-shell) do_dms_shell ;;
        niri) do_niri ;;
    esac
done
