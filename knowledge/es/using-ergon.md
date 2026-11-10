# Usar Ergon

Lo que esta máquina hace por ti sin que se lo pidas, dónde caen las cosas que
generas y qué archivos son tuyos para editar. Solo conceptos: toda lista de
este tipo queda desactualizada apenas se escribe, así que no se escribe.
`ergon keys`, `ergon --list`, `ergon bundle list` y `ergon <command> --help`
son las listas reales, generadas a partir de lo que está instalado y asignado
ahora mismo.

## Los snapshots deshacen una mala actualización; el respaldo sobrevive a un disco muerto

`snap-pac` se engancha directamente a `pacman`, de modo que cada transacción
(no solo las que pasan por `ergon update`) recibe antes un snapshot de btrfs, y
si dos arranques seguidos no llegan al target por defecto, el gestor de
arranque inicia por su cuenta el último snapshot que sí llegó. Ese respaldo no
es permanente: el siguiente arranque que llegue al escritorio lo limpia de
nuevo, así que te da un arranque para arreglar las cosas, no una reversión
fija. `sudo ergon rollback N` deja una permanente, reemplazando `@` por
completo (`sudo ergon rollback --list` muestra los candidatos), pero se niega
a ejecutarse DESDE `@`; antes arranca el snapshot desde el menú de arranque
(systemd-boot lo muestra durante dos segundos; instalaciones antiguas: el
submenú de GRUB) o desde la ISO de Arch.

Eso te protege de una actualización, no del disco. Un snapshot vive en el mismo
dispositivo que los datos de los que es snapshot, así que un SSD muerto se
lleva todos. `ergon backup` envía `/home` a otro lugar por completo (cifrado,
deduplicado y restaurable archivo por archivo), pero no hace absolutamente nada
hasta que `ergon backup init REPO` nombre un destino; los timers que instala el
aprovisionamiento quedan inertes hasta entonces. Lo único que no puede proteger
es su propia clave: `ergon backup key` la imprime cuando quieras, y guardar la
única copia en este notebook anula todo el sentido.

## Una contraseña al arrancar, y luego el escritorio

La contraseña del disco es lo único que se escribe al arrancar: Plymouth la
pide con la paleta que usas, y luego greetd inicia Hyprland por ti
(`AUTOLOGIN=1` en `hosts/<host>/host.env`, el valor por defecto del
instalador). Al cerrar sesión llegas al greeter con contraseña; la pantalla de
bloqueo y `sudo` siguen pidiendo tu contraseña. El llavero donde las apps
Electron guardan sus secretos no tiene contraseña propia, porque nadie la
escribiría: lo que lo protege es el cifrado del disco. El menú de arranque
(systemd-boot, dos segundos) lista los snapshots recientes y linux-lts.
Un disco instalado con `ENCRYPT=0` no pide nada: el splash y luego el
escritorio. `ergon explain security` dice qué contiene la ESP sin cifrar y qué
revela un disco sin cifrar; `ergon explain
troubleshooting` cómo cambiar cualquiera de eso.

## Los bundles son lo que pediste, y nada más

La instalación base es deliberadamente pequeña. Todo lo que va más allá
(inferencia, astronomía, una pila de GPU, un segundo editor) es un bundle, que
se añade y se quita sin reaprovisionar y queda registrado en
`hosts/<host>/host.env` para que un reaprovisionamiento reproduzca exactamente
la máquina que tienes. Qué existe, qué está instalado en esta y cuánto cuesta
cada uno lo dice `ergon bundle list`, no una tabla aquí; `ergon bundle info
<name>` antes de añadir uno que no reconozcas.

## Suspensión, hibernación, actualizaciones

`ergon sleep check` dice qué ofrece realmente el hardware (no todo el firmware
de notebook soporta suspensión real (S3), solo la más superficial, s2idle) y si
la última suspensión la alcanzó. La hibernación necesita el swapfile y el
resume offset que `arch-bootstrap.sh` configura al instalar, activados por
defecto; una máquina instalada con eso desactivado no reanudará desde una ahora.

`ergon update` es `pacman -Syu` con las cuatro precondiciones que hacen que Arch
sea aburrido en vez de emocionante, comprobadas antes de escribir nada: espacio
en disco, un llavero de claves al día, noticias de intervención manual sin leer
y un punto de reversión. `ergon update --check` responde "¿esto pasaría?" sin
cambiar nada.

## Dónde caen las cosas

- **Las capturas de pantalla** van a `~/Pictures/Screenshots` y al
  portapapeles, en un solo pipeline (`hypr/common/screenshot.lua`). Para
  ponerlas en otro lugar, define `SCREENSHOT_DIR` en `hosts/<host>/host.env`
  (una ruta absoluta simple), ejecuta `ergon sync` y vuelve a iniciar sesión.
- **Las grabaciones** van a `~/recordings` (`ergon record`; `$ERGON_RECORD_DIR`
  para moverlas).
- **Las figuras** reciben su procedencia sellada automáticamente por el Python
  compartido (`lib/ergon_figprov.py`): qué script, qué commit, `-dirty` si el
  árbol no estaba limpio. `ergon fig whence plot.png` la lee de vuelta.
- **Un proyecto creado con `ergon new`** tiene `figures/` bajo control de
  versiones, `data/` y `scratch/` en gitignore, y un entorno bloqueado: `uv`
  para Python, `renv` para R. **Los notebooks son marimo** por defecto (`.py`
  simple, así que se pueden comparar con diff, y reactivos, así que no hay
  celdas obsoletas); Jupyter es un bundle para quien quiera `.ipynb`, no algo
  que haya que quitar. Un proyecto trae marimo consigo, como dependencia de
  desarrollo bloqueada, porque el marimo base no puede importar tu proyecto:
  abre sus notebooks desde el proyecto con
  `uv run marimo edit notebooks/starter.py` (ERGON-67).

## Fondos de pantalla

Los fondos son calculados, no fotografías: cada uno es un campo de una
simulación en `wallpaper/`, coloreado con la paleta activa, así que cambiar de
paleta también los recolorea. Los 69 fondos aprobados llegan con la
instalación: `install.sh` descarga sus campos (cerca de 0,6 GB, verificados con
sha256) y los colorea para la paleta activa al tamaño de tu panel, de modo que
las imágenes existen antes del primer inicio de sesión. El primer fondo que ves
es el aprobado **flame-0**; el degradado solo aparece cuando flame-0 aún no
está (instalación sin conexión), y el siguiente inicio de sesión descarga lo
que falta en segundo plano. Una descarga fallida se imprime como un bloque de
advertencia, nunca se traga.

Cambiar de paleta redibuja el MISMO fondo con la nueva paleta. La pantalla de
bloqueo muestra el fondo actual, difuminado (nunca una captura de pantalla, que
filtraría lo que hay en pantalla); sigue los cambios de fondo y de paleta a
través de `~/.local/share/ergon/lock-background.png`, que `ergon-wallpaper`
mantiene apuntando a la imagen en pantalla.

`SUPER + SHIFT + B` y `SUPER + CTRL + B` los recorren.
`ergon-wallpaper-gen --fetch` descarga los que falten y recolorea;
`--ensure` es la versión barata para el inicio de sesión;
`ergon-wallpaper-gen GENERATOR SEED` calcula uno nuevo desde cero. Tus propias
imágenes van en `~/.config/ergon/backgrounds/`. `ERGON_BACKGROUNDS=0` omite la
descarga durante la instalación.

## Acentos: mantén la tecla

Mantén presionada una letra en vez de tocarla y aparece un popup numerado con
sus acentos, como lo hace macOS: mantén e, presiona 1, obtienes é. Esc deja la
letra simple, y un toque sigue siendo solo la letra. El español va primero, así
que los acentos que usa quedan en 1 y 2 (á é í ó ú ñ ü); ¿ y ¡ están en un ?
mantenido, 1 y 2: suelta Shift antes del dígito. La espera es un temporizador
propio, de un cuarto de segundo, y no tiene nada que ver con la repetición de
teclas, por eso una vocal mantenida ya no se repite.

Lo hace un método de entrada (fcitx5 con el addon omacento), así que funciona
en cualquier aplicación que reciba texto de uno: apps GTK y Qt, Firefox,
terminales, y apps Chromium o Electron iniciadas con `--enable-wayland-ime`
(Discord mediante su entrada del lanzador, VS Code y otras apps sobre el
electron de Arch mediante `~/.config/electron-flags.conf`). Nunca cambia la
distribución de tu teclado.

Está activo en todas partes, terminales incluidas, hasta que digas lo contrario:

    ergon accents                 qué está vigente, y si fcitx5 lo tiene
    ergon accents skip            no en la ventana enfocada: una tecla mantenida se repite
    ergon accents unskip          ...y de vuelta
    ergon accents off | on        todo el mecanismo
    ergon accents hold 400        una espera más larga antes del popup (100 a 1000 ms)

`skip` sin nada después significa la ventana en la que estás escribiendo, así
que ejecutarlo en una terminal le devuelve a esa terminal su repetición de
teclas: la `u`, `n` y `e` mantenidas de vim. También acepta clases de ventana
(`ergon accents skip foot`). Tus elecciones se guardan en
`~/.config/ergon/accents` y sobreviven a cada sync; la tabla en sí es del
repositorio, en `fcitx5/omacento.conf`, así que un cambio en ella igual te
llega. Cuando no ocurre en absoluto, `ergon explain troubleshooting`.

## Tus ajustes frente a los generados

Toda superficie del escritorio con tema (la barra, el lanzador, la terminal, la
propia configuración Lua) se renderiza desde una plantilla en cada ejecución de
`ergon theme` y en cada `install.sh`, así que cualquier cosa escrita
directamente en uno de esos archivos desaparece en el siguiente renderizado. Lo
que sobrevive es `~/.config/ergon/`: un archivo de inclusión para cada
superficie que tenga dónde ponerlo, creado una vez si no existe y que nada de
lo que se distribuye aquí vuelve a tocar: `lib/user-config.sh` y
`lib/ergon_arxiv.py` son los únicos dos escritores, ambos crean solo si no
existe, y `ergon-lint` sujeta todo lo demás del repositorio a esa regla. (Un
archivo ahí es de un comando: `~/.config/ergon/accents`, que `ergon accents`
modifica al ejecutarlo, una tecla a la vez, conservando el resto.) Ahí va una
regla de waybar escrita a mano, tus propios atajos de Hyprland o un bloque de
huella dactilar registrada. No toda superficie tiene esta vía de escape: el
conjunto exacto, y qué se rompe en cada una si su archivo falta, está en
`ergon explain desktop-config`.

## El modelo de seguridad

LUKS, el compromiso del grupo docker, el firewall, faillock y lo que `sudo`
puede hacer son su propio tema, no se repiten aquí: `ergon explain security`.

## Obtener ayuda

`ergon --help` para todos los comandos; `ergon <command> --help` para uno de
ellos. `ergon explain --list` para qué más sabe esta máquina de sí misma, y
`ergon doctor` para cuando algo está mal en silencio en vez de roto con
estruendo.
