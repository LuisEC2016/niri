#!/usr/bin/env bash
# Sanea el estado de audio al iniciar niri.
#
# Problema que resuelve: WirePlumber puede restaurar un perfil de tarjeta cuyo
# puerto de salida no esta conectado (p.ej. perfil "Headphones" con el jack
# vacio), y puede dejar el sink/source por defecto apuntando a un dispositivo
# Bluetooth ausente. En ese estado Zoom, Slack o Chromium enumeran dispositivos
# que no suenan ni capturan.
#
# Que hace:
#   1. Espera a que PipeWire acepte conexiones.
#   2. Si el sink por defecto no puede sonar, cambia al perfil que expone el
#      altavoz interno.
#   3. Fija sink y source por defecto a altavoz + microfono digital interno.
#   4. Desmutea ambos y aplica un volumen de partida razonable.
#
# El jack de auriculares sigue gestionado por WirePlumber: al conectarlo cambia
# solo de perfil, y este script no interfiere porque solo actua si el puerto
# activo no esta disponible.

set -uo pipefail

CARD_NAME="alsa_card.pci-0000_00_1f.3-platform-skl_hda_dsp_generic"
SPEAKER_PROFILE="HiFi (HDMI1, HDMI2, HDMI3, Mic1, Mic2, Speaker)"
SINK_VOLUME="60%"
SOURCE_VOLUME="55%"

log() { printf '[audio-init] %s\n' "$*"; }

# Primera linea de $2 (salida de `pactl list short`) que contiene $3, campo 2
# (el nombre) en la variable $1. Con builtins: el script corre al entrar en la
# sesion y antes eran un pactl + grep/awk por cada consulta.
first_name() {
    local -n out=$1
    local _id name _rest
    out=
    while read -r _id name _rest; do
        if [[ "$_id $name $_rest" == *"$3"* ]]; then
            out=$name
            return
        fi
    done <<<"$2"
}

# 1. PipeWire puede tardar en levantar tras el login; sin esto pactl falla.
ready=0
for ((i = 0; i < 30; i++)); do
    pactl info >/dev/null 2>&1 && { ready=1; break; }
    sleep 0.5
done
if [ "$ready" -eq 0 ] && ! pactl info >/dev/null 2>&1; then
    log "pipewire no respondio tras 15s, se aborta"
    exit 1
fi

# Arreglo de un portatil concreto: en cualquier otra tarjeta no se toca nada
# (ni perfiles, ni volumenes, ni el mezclador de ALSA). La unidad ya se salta
# fuera de ese equipo; esto cubre lanzarlo a mano.
if [[ $(pactl list short cards) != *"$CARD_NAME"* ]]; then
    log "no esta la tarjeta $CARD_NAME: nada que sanear"
    exit 0
fi

# 2. Si no hay ningun sink analogico utilizable, forzar el perfil con altavoz.
#    "Headphones" y "Speaker" viven en perfiles distintos porque la tarjeta usa
#    UCM con split-enable, asi que la unica forma de recuperar el altavoz es
#    cambiar el perfil entero.
sinks=$(pactl list short sinks)
if [[ $sinks != *HiFi__Speaker__sink* ]]; then
    log "sin sink de altavoz; cambiando a perfil $SPEAKER_PROFILE"
    pactl set-card-profile "$CARD_NAME" "$SPEAKER_PROFILE" || log "fallo al fijar perfil"
    sleep 1
    sinks=$(pactl list short sinks)
fi

first_name sink "$sinks" HiFi__Speaker__sink
first_name source "$(pactl list short sources)" HiFi__Mic1__source

# 3. Fijar los dispositivos por defecto. Las apps que usan "Same as System"
#    (Zoom, Slack, Chromium) siguen este valor.
if [ -n "${sink:-}" ]; then
    pactl set-default-sink "$sink"
    pactl set-sink-mute   "$sink" 0
    pactl set-sink-volume "$sink" "$SINK_VOLUME"
    log "sink por defecto: $sink"
else
    log "no se encontro el sink del altavoz"
fi

if [ -n "${source:-}" ]; then
    pactl set-default-source "$source"
    pactl set-source-mute   "$source" 0
    pactl set-source-volume "$source" "$SOURCE_VOLUME"
    log "source por defecto: $source"
else
    log "no se encontro el microfono digital"
fi

# 4. Los HDMI arrancan muteados a 0 si se dejaron asi en otra sesion; al
#    conectar un monitor con altavoces el usuario no oiria nada y el mute no es
#    visible en el OSD hasta seleccionarlo.
#    La lista de sinks es la de arriba: fijar el defecto, el mute y el volumen
#    no la cambia.
while read -r _ hdmi rest; do
    [[ "$hdmi $rest" == *HDMI* ]] && pactl set-sink-mute "$hdmi" 0
done <<<"$sinks"

# 5. Auto-Mute Mode conmuta altavoz/auriculares en el codec al detectar el jack.
#    Viene deshabilitado en esta placa y sin el suenan los dos a la vez.
amixer -c0 sset "Auto-Mute Mode" Enabled >/dev/null 2>&1 || true
