# Escritorio propio sobre niri

Todo lo que cambia este fork respecto a niri upstream, y la configuración del
escritorio que corre encima: niri + DankMaterialShell (DMS) con dock, OSD y
centro de control estilo macOS.

```sh
dotfiles/install.sh --dry-run   # ver qué haría, sin tocar nada
dotfiles/install.sh             # config + shell DMS + compilar e instalar niri
dotfiles/install.sh config      # solo una parte: config | dms-shell | niri
```

## Qué hay y dónde vive

| En el repo | Se instala en | Cómo |
|---|---|---|
| `src/`, `niri-ipc/`, `niri-config/` | `/usr/local/bin/niri` | compilado |
| `dotfiles/niri/config.kdl`, `custom/*.kdl`, `scripts/*.sh` | `~/.config/niri/` | enlace simbólico |
| `dotfiles/matugen/templates/niri-futurista.kdl` | `~/.config/matugen/templates/` | enlace simbólico |
| `dotfiles/matugen/config.toml` | `~/.config/matugen/` | copia (rutas absolutas) |
| `dotfiles/dms/settings.json`, `plugin_settings.json` | `~/.config/dms/` | copia (DMS los reescribe) |
| `dotfiles/dms-shell/patches/*.patch` | `~/.local/share/dms-shell-custom/` | `dms-shell/build.sh` |
| `dotfiles/systemd/user/…` | `~/.config/systemd/user/` | copia |

Los enlaces hacen que editar `~/.config/niri/config.kdl` sea editar el repo:
`git diff` enseña el cambio y niri recarga al guardar igual que antes (resuelve
los `include` respecto a `~/.config/niri`, no respecto al destino del enlace).

No se versionan porque se generan solos: `~/.config/niri/dms/*.kdl` (DMS),
`~/.config/niri/dms-theme-sync.kdl` (plugin dmsThemeSync) y
`~/.config/niri/custom/futurista.kdl` (matugen, desde la plantilla). Por eso
`config.kdl` los incluye con `optional=true`: en una instalación limpia niri
arranca sin ellos y los carga en cuanto DMS los escribe.

## Cambios en el código de niri

- **Minimizar nativo** (`src/layout/workspace.rs`). Upstream no tiene
  minimizar. Aquí una ventana minimizada sale del layout (no se dibuja, no se
  enfoca, no ocupa sitio) pero sigue en su workspace, con lo necesario para
  volver exactamente donde estaba: misma columna (y misma posición dentro de
  ella si la compartía), o misma posición y tamaño si era flotante. Un
  workspace con ventanas minimizadas no se recoge aunque parezca vacío, y viaja
  con ellas si cambia de monitor. Entradas:
  - acciones `minimize-window` y `unminimize-window` (sin `--id`, la última
    minimizada), también por `niri msg action`;
  - el botón de minimizar de las decoraciones del cliente (`minimize_request`);
  - `wlr-foreign-toplevel` `set_minimized`/`unset_minimized` y el estado
    `minimized`, que es lo que usa el dock de DMS;
  - enfocar una minimizada (dock, Alt+Tab, `focus-window`, xdg-activation) la
    restaura.

  La IPC añade `is_minimized` a cada ventana (`niri msg windows` la marca con
  `(minimized)`). Al minimizar se reproduce la animación de cierre y al
  restaurar la de apertura. Las acciones dirigidas a una ventana minimizada por
  id (redimensionar, mover a otro workspace...) no hacen nada. Sustituye a la
  emulación anterior con un workspace `min`, una pila en `$XDG_RUNTIME_DIR` y un
  vigilante del event-stream, que lanzaba unos 11 procesos por pulsación.
- **Maximizar flotantes en su sitio** (`src/layout/floating.rs`). Upstream
  saca una ventana flotante al layout de mosaico para maximizarla y la devuelve
  al restaurar. Aquí se queda flotante, ocupando el área de trabajo, y al
  restaurar recupera su posición y tamaño. Vale para el botón y el doble clic de
  la barra de título, `maximize-window-to-edges` (`Mod+M`, que alterna) y
  `wlr-foreign-toplevel`. Si el área de trabajo cambia (aparece la barra), la
  ventana maximizada se ajusta. Arrastrarla la restaura.
- **Ventanas flotantes hasta el borde** (`src/layout/floating.rs`). Upstream
  obliga a dejar en pantalla un cuarto de la ventana (hasta 75 px, cifras de
  Mutter). Aquí basta una franja de 10 px dentro del área de trabajo, no de la
  salida entera: la barra es una capa encima de las ventanas y una franja debajo
  de ella no se podría agarrar.

Antes vivían como parches sueltos en `~/.config/niri/patches/` aplicados sobre
v26.04 en `~/.local/src/niri`; ese directorio queda obsoleto.

## Dock estilo macOS (DMS, no niri)

El dock lo dibuja DankMaterialShell, no niri. Lo que lo hace "estilo macOS" son
dos parches QML sobre DMS y unos ajustes:

- `dms-shell/patches/03-dock-macos-magnify.patch`: magnificación al pasar el
  puntero. Cada icono se escala por su distancia al cursor con caída coseno y
  empuja a los vecinos.
- `dms-shell/patches/01-dock-launch-bounce.patch`: rebote al lanzar una app.
- `dms/settings.json`: `appsDockEnlargeOnHover`, `appsDockEnlargePercentage`
  (145), `dockAutoHide`, `dockSmartAutoHide`, `dockIconSize` (52),
  `dockTransparency`, `dockBorder*`, `dockShowTrash`, iconos `WhiteSur-purple`.
- `niri/config.kdl`: `layer-rule` que quita la sombra de niri a `dms:dock` (DMS
  ya pinta la suya).
- `dms-shell/patches/11-niri-native-minimize.patch`: DMS da por hecho que
  niri no minimiza y le desactiva `supportsMinimize`. Con el minimizado nativo
  de este niri se activa: pulsar la app enfocada en el dock la minimiza, pulsar
  una minimizada la restaura, y el icono se atenúa mientras está minimizada.
  Solo tiene sentido con este niri: el de upstream ignora esas peticiones.

El resto de parches: `05` OSD de volumen y brillo estilo macOS, `06` centro de
control estilo macOS, `02` caché del mapa de categorías del lanzador, `04`
`07` `08` `09` `10` notificaciones, `11` minimizar en niri.

`dms-shell/build.sh` clona DMS **v1.6.0** (commit `0bbe8338`), aplica los
parches e instala el resultado en `~/.local/share/dms-shell-custom`, que
`systemd/user/dms.service.d/override.conf` pasa a DMS con `DMS_SHELL_DIR`.
`build.sh --check` reconstruye en un temporal y lo compara con lo instalado.

La base va fijada a propósito. El antiguo `.patches/resync.sh` la copiaba de
`/usr/share/quickshell/dms/quickshell`, que sigue al paquete del sistema; el
paquete ya está en 2.1.1, con otra estructura de archivos, y los parches no
aplican sobre ella. Pasar a una versión nueva de DMS es portar los parches a
mano y cambiar `DMS_TAG`/`DMS_COMMIT` en `build.sh`.

## Procesos: ninguno al arrancar, cada uno cuando hace falta

`config.kdl` no tiene `spawn-at-startup`. Lo que la sesión necesita arranca
bajo demanda o como unidad de systemd que se salta donde no aplica, así que el
mismo repo se instala en otro equipo sin arrastrar arreglos de este:

| Qué | Cuándo corre | Fuera de este equipo |
|---|---|---|
| `power-profile-auto.service` | toda la sesión, dormido hasta un evento de `upower --monitor` | se salta sin batería ni `powerprofilesctl` |
| `audio-init.service` | una vez al entrar, y sale | se salta si la placa no es MS-15H4 |
| `ssm-tray.service` | toda la sesión | se salta si no está `~/.local/bin/ssm-tray` |

Antes, con la sesión en reposo: el vigilante de minimizar vivía siempre (bash
+ `niri msg event-stream`, ~20 MB) y lanzaba dos `jq` y el helper en cada
cambio de foco; el perfil de energía leía sysfs cada 5 s con forks de `sleep`
y `cat` (coreutils en Rust: ~8 MB por proceso). Medido el 2026-11-07. Ahora
minimizar lo hace niri y no hay vigilante.

Los scripts que corren por pulsación también lanzan los procesos justos
(contados con `strace -f -e execve` contra un `niri` falso, 2026-11-07):

| Orden | Antes | Ahora |
|---|---|---|
| minimizar (`niri-minimize.sh minimize`) | 20 | 0: acción de niri |
| restaurar desde el dock (`niri-minimize.sh restore-id`) | 25 | 0: wlr-foreign-toplevel |
| restaurar la última (`niri-minimize.sh restore`) | 31 | 0: acción de niri |
| `toggle-touchpad.sh` | 5, uno `python3` | 4, sin `python3` |
| `video-hwdec.sh`, por muestra | ~300 (`grep` por descriptor) + `sleep` | 1 (`awk`) |

Medido en este equipo: cada `niri msg` cuesta ~5 ms de CPU y cada `jq` o
proceso de coreutils ~2 ms.

## Fuera del repo

- Se instalan aparte: `ssm-tray` y lo que usan los scripts: `jq`, `pactl`,
  `notify-send`, `fuzzel`, `upower` y `powerprofilesctl`.
- `sony-wf-c710n-autoswitch.service` no tiene que ver con niri y no está aquí.
  WirePlumber 0.5 ya hace ese cambio de perfil A2DP/HFP él solo
  (`bluetooth.autoswitch-to-headset-profile`, activo por defecto).
