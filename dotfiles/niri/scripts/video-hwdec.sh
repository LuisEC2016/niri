#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ¿Está el vídeo decodificándose en la GPU o en la CPU?
#
# Lee drm-engine-video de fdinfo del proceso: son los nanosegundos acumulados
# que el motor de vídeo dedicado de la iGPU ha estado ocupado. Es la respuesta
# directa, sin interpretar: si crece, hay decodificación por hardware; si se
# queda clavado en el mismo número mientras se reproduce, la está haciendo la
# CPU. No necesita root, a diferencia de intel_gpu_top.
#
# Uso:  video-hwdec.sh [patrón]     (por defecto vigila Chrome)
#       video-hwdec.sh mpv
#       video-hwdec.sh vlc
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PATRON="${1:-chrome}"
INTERVALO="${2:-3}"

engine_ns() {
    local pid=$1 total=0 v
    for fd in /proc/"$pid"/fdinfo/*; do
        v=$(grep -m1 '^drm-engine-video:' "$fd" 2>/dev/null | grep -oE '[0-9]+' || true)
        [ -n "$v" ] && total=$((total + v))
    done
    echo "$total"
}

# Chrome reparte el trabajo entre procesos: el decodificador vive en el proceso
# GPU, no en el de la pestaña. Se busca ese; para mpv o vlc vale el proceso a
# secas, que es de un solo proceso.
localizar() {
    if [[ "$PATRON" == *chrome* ]]; then
        pgrep -f "$PATRON" | while read -r p; do
            tr '\0' ' ' < /proc/"$p"/cmdline 2>/dev/null | grep -q 'type=gpu-process' && echo "$p"
        done | head -1
    else
        pgrep -x "$PATRON" 2>/dev/null | head -1 || pgrep -f "$PATRON" | head -1
    fi
}

PID=$(localizar || true)
if [ -z "${PID:-}" ]; then
    echo "No hay ningún proceso que case con '$PATRON'." >&2
    exit 1
fi

echo "Vigilando pid $PID ($PATRON), muestras cada ${INTERVALO}s. Ctrl-C para salir."
echo
ANT=$(engine_ns "$PID")
while sleep "$INTERVALO"; do
    [ -d /proc/"$PID" ] || { echo "El proceso $PID ha terminado."; exit 0; }
    ACT=$(engine_ns "$PID")
    DELTA=$(( ACT - ANT ))
    # Porcentaje de ocupación del motor de vídeo durante el intervalo.
    PCT=$(awk -v d="$DELTA" -v i="$INTERVALO" 'BEGIN{printf "%.1f", d/(i*1e9)*100}')
    if [ "$DELTA" -gt 0 ]; then
        printf '  hardware   %+12d ns  (%5s%% del motor de vídeo)\n' "$DELTA" "$PCT"
    else
        printf '  CPU        %+12d ns  (motor de vídeo parado)\n' "$DELTA"
    fi
    ANT=$ACT
done
