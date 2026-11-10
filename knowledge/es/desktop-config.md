# Editar la configuración del escritorio

Hyprland se configura aquí en **Lua**, no en hyprlang. `hypr/hyprland.lua` es el
punto de entrada; el resto es `hypr/common/*.lua`. Es un formato joven y casi
sin corpus público, así que la mayor parte de lo que un agente o una persona
"sabe" sobre la configuración de Hyprland no aplica, y el modo de fallar es el
silencio, no un error.

Todo lo que sigue costó tiempo real descubrirlo.

## La API

**`hl.config({...})` es la única forma.** Una sola llamada, tablas anidadas:

    hl.config({
      general    = { border_size = 2, gaps_in = 4 },
      decoration = { rounding = 8 },
      input      = { kb_layout = "us" },
      misc       = { disable_hyprland_logo = true },
    })

`hl.general{}`, `hl.decoration{}`, `hl.input{}`, `hl.misc{}` y
`hl.animations{}` **no existen**. Llamar a una es un error de índice nil al
cargar, y según dónde esté queda una configuración aplicada a medias.

**Los dispatchers tienen espacio de nombres.** No son cadenas:

    hl.dsp.window.close()
    hl.dsp.window.move({ workspace = 3 })
    hl.dsp.window.drag()
    hl.dsp.focus({ direction = "l" })
    hl.dsp.focus({ workspace = 3 })
    hl.dsp.workspace.toggle_special()
    hl.dsp.cursor.move({ x = 100, y = 15 })
    hl.dsp.exec_cmd("wezterm")
    hl.dsp.exit()

`hl.dsp.exec_raw("<classic dispatcher string>")` es la vía de escape para todo
lo que no tiene forma tipada. Prefiere la forma tipada cuando exista:
`exec_raw("focuswindow address:0x...")` responde `ok` y no mueve el foco,
mientras que `hl.dsp.focus({ window = "address:0x..." })` sí lo mueve (medido
en la suite de la VM, 2026-10-19). `ergon-lint` rechaza la primera.

**Opciones de bind**: `locked`, `repeating`, `mouse`, `description`. Es
`repeating`, **no** `repeat`: `repeat` es una palabra reservada de Lua y usarla
es un error de sintaxis, no una advertencia.

Todo bind debería llevar `description`. `hyprctl binds -j` la informa, y
`ergon keys` construye la hoja de atajos a partir de eso, así que no hay una
segunda lista que se desactualice.

**Eventos**: `hl.on("hyprland.start", fn)`, `hl.on("monitor.added", fn)`,
`hl.on("monitor.removed", fn)`.

**Reglas**: `hl.window_rule({ match = {...}, float = true, ... })` y
`hl.layer_rule({ match = { namespace = "waybar" }, no_anim = true })`.

## La trampa que más importa

**Un Hyprland configurado con Lua evalúa el payload IPC de `dispatch` COMO LUA.**

    hyprctl dispatch workspace 3

llega como `return hl.dispatch(workspace 3)` y muere con un error de sintaxis.
Lo ve quien llama; nada más. Casi ningún script revisa el código de salida de un
dispatch, así que se presenta como *no pasa absolutamente nada*.

Formas correctas, todas verificadas contra un compositor en ejecución:

    hyprctl dispatch 'hl.dsp.exec_raw("workspace 3")'      # la vía de escape general
    hyprctl dispatch 'hl.dsp.focus({workspace = 3})'
    hyprctl dispatch 'hl.dsp.cursor.move({x = 100, y = 15})'

`ergon-lint` falla ante cualquier `hyprctl dispatch <word>` clásico en el
repositorio. Ejecútalo.

Por eso mismo **waybar debe ser `waybar-git`** (ver `packages/aur`): waybar
0.15.0 envía la cadena clásica cuando haces clic en un espacio de trabajo, así
que los botones se resaltan y no hacen nada. Corregido en upstream en
Alexays/Waybar#5013, que está en master y aún no en un release.

## La introspección es reducida bajo Lua

`hyprctl binds -j` informa `"dispatcher": "__lua"` con un `arg` entero para cada
bind, porque la acción es una closure y no una cadena de dispatch. **No puedes**
leer desde el compositor qué ejecuta un bind. `description` sobrevive y es lo
único que lo hace, por eso cada bind lleva una.

## Verificar un cambio

`Hyprland --verify-config` prueba que la configuración SE PARSEA. No prueba que
el compositor arranque, que los binds se registren ni que waybar haya mapeado
una superficie: dos errores de API en este repositorio produjeron un compositor
con cero atajos de teclado y una configuración que verificaba perfectamente.

    ergon-lint                     # trampas estáticas
    Hyprland --verify-config       # parseo
    ./bin/test-hypr-session.sh     # lo real, en una VM, ~12 min

La prueba de sesión inicia el compositor, comprueba que los binds se registren,
que waybar mapee, que cada `on-click` y cada `ergon-*` se resuelvan en el PATH
de la sesión, y que un **clic sintético** a través de `/dev/uinput` cambie
realmente de espacio de trabajo.

## PATH de la sesión

`environment.d/10-ergon-path.conf` es lo que pone el `bin/` del repositorio en
el PATH del gestor de usuario de systemd, que es quien lanza la sesión bajo
uwsm. Sin él, cada `ergon-*` en waybar y en los atajos se resuelve a nada: el
módulo se dispara, el comando no se encuentra y no hay ningún error visible en
ninguna parte.

Los cambios necesitan `systemctl --user daemon-reload` **y una sesión nueva**.
El gestor en ejecución no lo vuelve a leer.

## Configuraciones generadas, y dónde van tus propias ediciones

**No edites una configuración con tema. Es generada, y tu edición tiene vida
corta.**

Veintiún archivos se renderizan desde una plantilla `.in` a su lado mediante
`ergon theme`, que expande la paleta activa en marcadores `@COOL_*@`:

    waybar/style.css      mako/config        hypr/hyprlock.conf
    gtk/gtk.css           fuzzel/fuzzel.ini  hypr/common/looknfeel.lua
    foot/foot.ini         newsboat/config    gtk/settings.ini
    yazi/theme.toml       lnav/config.json   lazygit/config.yml
    lazydocker/config.yml wezterm/wezterm.lua btop/themes/ergon.theme
    bat/themes/ergon.tmTheme  swayosd/style.css  gtk/gtk4.css
    gtk/settings4.ini     qt6ct/qt6ct.conf   qt6ct/colors/ergon.conf

`gtk/gtk4.css` es la única excepción a "la paleta activa": es
`gtk/gtk.css.in` renderizado dos veces, una paleta clara y una oscura en
bloques `@media (prefers-color-scheme)`, de modo que una app GTK4 que ya está
corriendo sigue un cambio de paleta. El porqué, y qué paleta llena el otro
bloque, está en `gtk/gtk4.css.in`. `gtk/settings4.ini` es el `settings.ini` de
gtk-4.0: el de gtk-3.0 más `gtk-interface-color-scheme`, que elige el bloque
cuando la sesión no tiene esquema de color, y del que GTK3 advertiría en cada
inicio.

Están en **gitignore**, e `install.sh` las renderiza antes de enlazar nada. Por
eso cambiar de paleta ya no deja sucio el repositorio, y por eso también un
clon nuevo no tiene ninguna hasta que algo las renderice.

Para cambiar un color, edita `theme/<palette>.env`. Para cambiar la estructura,
edita el `.in`. Editar la salida cambia tu escritorio hasta la próxima
instalación.

El tamaño del texto es la única entrada que no es la paleta. `ergon display text
N` (8 a 32; el valor por defecto está en `theme/type.env`) convierte cada
`@TYPE:<n>@` (un tamaño tal como la plantilla fue diseñada a 11) en `n * N /
11`, y fija el `text-scaling-factor` de GTK en `N / 11`. `ergon text-size
small|normal|large|larger|FACTOR` (o un selector de fuzzel) es la misma entrada
como factor de 11.

### Monitores: modos, proyectores y qué sobrevive

`ergon display` (y la entrada Pantalla de `ergon menu`) cambia una salida con
`hyprctl eval`, así que dura hasta el próximo inicio de sesión. Cada regla que
escribe es completa (modo, posición, escala, transformación) porque nunca se
midió si un `hl.monitor` parcial conserva los campos que omite. `--save` (o
`ergon display save`) también la escribe en `~/.local/state/ergon/display.lua`,
que se carga después de `hosts/<host>/hyprland.lua` y antes de los cambios de
esta sesión. Un espejo nunca se guarda. `SUPER+CTRL+M` recorre la escala de la
salida enfocada por los pasos que su modo divide exactamente; Hyprland
redondearía cualquier otro.

Los clientes XWayland se dibujan al tamaño en píxeles del monitor (`xwayland = {
force_zero_scaling = true }`), lo que es nítido y pequeño. `ergon display
xscale` fija `GDK_SCALE` a partir de la menor escala de monitor al iniciar
sesión y tras un cambio de escala, para los clientes que se inicien después; Tk,
Java y Qt tienen sus propios controles.

### Qué las revisa, y qué no

Las configuraciones renderizadas están en gitignore, así que nadie las lee en un
diff. Lo único que se interpone entre una plantilla y una superficie que deja de
tener tema en silencio es un parser, y `foot` demostró que no es teórico:
`[colors]` dejó de ser un nombre de sección que foot conociera, una sección
desconocida se lleva todas las claves que contiene, y dieciséis ranuras ANSI se
estaban descartando sin ningún error en ninguna parte.

    ./bin/test-hypr-config.sh      # lo que dice la lista de abajo, ejecutado de verdad

`./bin/test-hypr-config.sh` carga catorce archivos a través del parser que
realmente leerá cada uno: `hypr/hyprland.lua` (que es lo que arrastra el
`looknfeel.lua` renderizado), `fuzzel.ini`, `foot.ini`, `wezterm/wezterm.lua`,
`newsboat/config`, `lazygit/config.yml`, `lazydocker/config.yml`,
`mako/config`, `hypridle.conf`, `hyprlock.conf`, y cuatro hojas de estilo a
través del motor GTK que realmente lee cada una: `waybar/style.css` y
`gtk/gtk.css` mediante GTK3, `swayosd/style.css` y `gtk/gtk4.css` mediante GTK4.
Los dos motores no aceptan el mismo archivo: GTK3 no tiene `@media` en absoluto.
`waybar/config.jsonc` se ejercita funcionalmente: la suite de sesión en la VM
inicia una barra real y comprueba que mapea una superficie de capa, lo que es
más fuerte que parsearla.

Los archivos de fcitx5 (`fcitx5/`, sin tema) reciben el mismo tratamiento por
otra vía, porque fcitx5 no tiene error de parseo que dar: una clave que no
conoce, o una que cayó bajo la `[section]` equivocada, se descarta y se
mantiene el valor por defecto. Así que el mismo script los carga en un fcitx5
real y le pregunta por D-Bus qué terminó teniendo. El archivo del selector de
acentos se renderiza en vez de enlazarse (`ergon accents`), y el mismo script
construye el addon desde `packages/pkgbuild` para leer ese render de vuelta a
través de él: apagado, una espera más larga, clases omitidas, y de nuevo.

`wezterm` es una compilación git de AUR presente en ninguna máquina que este
repositorio pruebe, así que el contenedor instala en su lugar el wezterm
publicado de `[extra]` de Arch: uno MÁS ANTIGUO (ver `packages/aur` para saber
por qué `wezterm-git` está fijado sobre él), suficientemente cercano para
validar el esquema pero no una prueba contra un campo renombrado o eliminado
desde entonces. Su propio `ls-fonts` no es un `--check-config`: medido contra un
error de sintaxis Lua, un campo desconocido y un valor de tipo equivocado,
wezterm sale con 0 en los tres e imprime sus propios valores por defecto,
exactamente la forma de respaldo silencioso que ocultó el error de foot. Cada
uno sí registra una línea ERROR en stderr, que es lo que la comprobación lee en
vez de `$?`.

`newsboat` tampoco tiene una bandera `--check-config`, pero no la necesita: una
directiva no reconocida (medida contra un objetivo de `color` renombrado) es un
error de parseo fatal en stderr con salida 1, antes de que arranque curses o se
descargue un feed, así que `-x print-unread` contra un archivo de URL de
relleno es una comprobación real. Medido por separado: un archivo renderizado
ausente o vacío no es un error para newsboat (salida 0, nada impreso),
indistinguible de una configuración leída y hallada limpia, así que el script
comprueba que el archivo exista antes de confiar en el silencio de la ejecución
que viene después.

`lazygit` y `lazydocker` tampoco tienen una bandera de comprobación de
configuración, pero ambos parsean todo su archivo YAML antes de llegar a nada
más de lo que este contenedor carece (un repositorio git para lazygit, un socket
de docker para lazydocker), así que una clave mala o un valor de tipo
equivocado (medido contra ambos) aparece en stderr como una línea `yaml:` antes
de que lo haga cualquiera de esos otros errores, siempre fatales aquí y ajenos
al tema. `lazygit -ucf` apunta directo al archivo renderizado; `lazydocker` no
tiene tal bandera, así que se enlaza simbólicamente en `~/.config/lazydocker`.

**Seis de los diecinueve archivos renderizados siguen sin ser revisados por
nada**, cada uno por una razón medida y no supuesta:

- `gtk/settings.ini` y `gtk/settings4.ini`: se leen con `GLib.KeyFile`, el mismo
  cargador sobre el que está construido el lector de ajustes propio de GTK, pero
  ese cargador no tiene esquema: medido, una clave falsa y un valor de tipo
  equivocado son sintaxis de keyfile perfectamente válida. Solo lo rompe una
  sintaxis grosera, de la que nada de lo que produce esta plantilla se acerca.
- `yazi/theme.toml`: yazi abre una TTY real antes de hacer cualquier otra cosa
  y falla de forma idéntica (`Inappropriate ioctl for device`) tanto si el tema
  es válido, como si tiene una clave desconocida, como si no es TOML parseable;
  medido contra los tres. Sin cabeza no los distingue.
- `lnav/config.json`: `lnav -C` sale con 0 ante una configuración que no puede
  usar, así que no es una comprobación.
- El tema de `btop`: sin bandera de comprobación, y en el propio contenedor Arch
  de este repositorio `btop` ni siquiera puede ejecutarse (`Operation not
  permitted`): su paquete fija capacidades de archivo (`cap_dac_read_search`,
  `cap_perfmon`) en el binario, que un docker en sandbox rechaza en `execve`
  sin nuevos privilegios. No se comprobó desde aquí si el docker del runner de CI
  choca con la misma pared.
- El tmTheme de `bat`: se compila en la caché de bat (`bat cache --build`, que
  `install.sh` ya ejecuta), de modo que uno roto al menos es ruidoso en una
  instalación real en vez de silencioso.

La comprobación de GTK tiene un límite que conviene conocer: valida sintaxis,
nombres de propiedad y gramática de valores, y detecta un `@COOL_*@` sin
expandir. **No** valida selectores: `#worksaces` se parsea perfectamente.

### Tus propios ajustes: `~/.config/ergon/`

Cada superficie que *puede* incluir otro archivo incluye uno desde ahí, y nada
en este repositorio escribe jamás esos archivos: `ergon-lint` lo hace cumplir, y
`lib/user-config.sh` es el único código autorizado a crear uno. El directorio
también contiene `accents`, que no es una inclusión sino el archivo de ajustes de
`ergon accents`: `lib/accents.sh` lo modifica cuando ese comando se ejecuta, y
renderiza a partir de él y del `fcitx5/omacento.conf` del repositorio el archivo
`~/.config/fcitx5/conf/omacento.conf`.

| tu archivo | incluido por | si falta |
|---|---|---|
| `waybar.css` | `waybar/style.css` | **sin tema en la barra** — GTK descarta la hoja de estilo completa |
| `mako` | `mako/config` | **sin demonio de notificaciones** — mako sale con 1 |
| `fuzzel.ini` | `fuzzel/fuzzel.ini` | falla `--check-config` |
| `foot.ini` | `foot/foot.ini` | falla `--check-config` |
| `newsboat.conf` | `newsboat/config` | **newsboat no arrancará** |
| `gtk.css` | `gtk/gtk.css`, `gtk/gtk4.css` | una advertencia en stderr |
| `hyprlock.conf` | `hypr/hyprlock.conf` | nada; es opcional por diseño |
| `user.lua` | `hypr/hyprland.lua` | nada; `pcall` lo cubre |

Los primeros cinco son la razón de que la creación viva junto al renderizador y
no en un paso de instalación aparte: la ejecución que escribe la línea de
inclusión es la que garantiza el archivo al que apunta.

**Tu archivo se incluye al final, en todas partes, a propósito.** Todos estos
formatos resuelven conflictos por orden de aparición, así que al final es la
única posición donde lo que escribes gana sobre lo que escribió la plantilla.
Una excepción, y es de mako, no una elección: `include` es legal solo antes del
primer bloque `[criteria]`, así que el `[urgency=critical]` generado y los demás
se parsean *después* del tuyo y ganan en cualquier clave que ambos definan.
Puedes añadir criterios que el repositorio no define; no puedes restilizar los
que sí define.

Diez superficies **no** tienen mecanismo de inclusión y no se pueden sobrescribir
así: `gtk/settings.ini`, `gtk/settings4.ini`, `yazi/theme.toml`,
`lnav/config.json`, `lazygit/config.yml`, `lazydocker/config.yml`, el tema de
`btop`, el tmTheme de `bat`, `wezterm/wezterm.lua` y `swayosd/style.css`; esta
última porque `~/.config/swayosd/style.css` **es** la ranura de sobrescritura
del usuario de swayosd, y este repositorio la ocupó; swayosd carga primero la
hoja del propio paquete y esta encima. Para esas, cambia la plantilla.
(`lazygit` y `lnav` pueden recibir una segunda configuración por línea de
comandos (`--use-config-file`, `-I`), lo que es un cambio de lanzador, no una
inclusión de archivo.)

### La unión con Lua es una ruta explícita, y tiene que serlo

    pcall(require, "~/.config/ergon/user")

No `require("user")`. Hyprland siembra `package.path` desde el directorio del
propio `hyprland.lua`, y ese directorio es `~/.config/hypr`, **un enlace
simbólico hacia el checkout**, así que un nombre de módulo simple se resuelve de
vuelta dentro del repositorio, que es el único lugar donde una sobrescritura sin
seguimiento no debe vivir. La forma con `~/` evita `package.path` y necesita
Hyprland 0.56; en algo más antiguo simplemente no se resuelve y `pcall` lo
traga.

Que `pcall` devuelva true **no** significa que tu archivo se haya cargado
limpio. Si existe pero tiene un error, Hyprland registra el error internamente
y le entrega a `require` una tabla vacía, así que la falla aparece en la
superposición de errores de configuración del compositor y en `Hyprland
--verify-config`, no en el sitio de la llamada.

### Por qué un archivo renderizado ausente no es un problema cosmético

Una configuración Lua es **un solo chunk**, así que un error en cualquier punto
detiene todas las líneas posteriores. `hypr/hyprland.lua` solía hacer `require`
de sus ocho módulos sin protección, y `common.looknfeel`, el generado, venía
segundo. Una sesión que cargó mientras ese archivo estaba ausente nunca llegó a
`windows`, `binds`, `media`, `lid`, `screenshot` ni `autostart`, y Hyprland
respondió con su propia protección:

    Emergency mode tripped: A lua config error resulted in no binds being
    registered. Emergency binds active: SUPER + Q

Sin terminal, sin lanzador, sin menú de sesión, sin lista de atajos, todo por un
esquema de colores. Se pagó el 2026-09-24, en la VM.

Ahora cada módulo se carga mediante `need()`, que usa `pcall`: un módulo que
falla se cae solo y nada más, y **`common.binds` se carga segundo**, de modo que
la vía de escape exista antes de que algo cosmético pueda fallar.
`bin/test-hypr-config.sh` lo mantiene así: borra `looknfeel.lua` y comprueba que
la ejecución igual llegue a la última línea de `binds.lua`.

Lo que `pcall` cuesta es el reporte, y sus dos mitades no son iguales. Medido
contra 0.56.2, en ambos casos:

| el módulo | ¿lo registra Hyprland? |
|---|---|
| existe, tiene un error | **sí** — superposición y `--verify-config`, con o sin pcall |
| falta por completo | **no** — un "module not found" ordinario de Lua, que pcall se traga entero |

Así que el caso ausente lo reporta este repositorio, desde el final de
`hypr/hyprland.lua`: primero bordes rojos, porque no necesitan demonio ni bus y
están en pantalla en cuanto se dibuja una ventana; luego una línea en
`~/.local/state/ergon/config-failures.log`; luego una notificación crítica una
vez que mako existe. Un escritorio sin tema, de otro modo, parece una paleta que
alguien eligió.

`install.sh` sigue renderizando antes de enlazar y sigue saliendo con código
distinto de cero si el renderizado falla, y eso no debe cambiar: la protección
de arriba mantiene un escritorio roto **utilizable**, no lo hace correcto.
