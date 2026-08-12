<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book MAX98390

Empaquetado en RPM/akmod del camino del driver `MAX98390` para los altavoces
internos de notebooks Samsung Galaxy Book en Fedora, con foco inicial en el
Galaxy Book4 Ultra.

## Instalación rápida

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-max98390
```

El paquete `akmod` contiene las fuentes y la receta de compilación. `akmods`
compila e instala un RPM `kmod-galaxybook-max98390-<versión-del-kernel>` para
cada kernel, con los dos módulos destinados específicamente a esa versión. Un
módulo compilado para otro kernel nunca se reutiliza.

## Objetivo

Algunos Galaxy Book exponen la tarjeta de sonido con normalidad e incluso
muestran el sink de salida en el sistema, pero los altavoces internos siguen
sin emitir audio. En esos modelos, la parte que falta es el lado de los
amplificadores `MAX98390`.

Este repositorio organiza ese soporte siguiendo el patrón de Fedora:

- módulos externos reconstruidos y entregados por kernel con `akmods`;
- un servicio de arranque que espera a `akmods`, carga explícitamente los dos
  módulos y crea los dispositivos I2C ausentes;
- reintentos limitados mientras ACPI, I2C, los módulos y los amplificadores
  quedan disponibles;
- validación de que los dispositivos estén enlazados con `max98390-hda` antes
  de que el servicio informe éxito;
- un helper de diagnóstico que indica cuándo el kernel parece incluir todas las
  partes de la implementación nativa.

No se instala ningún archivo en `modules-load.d`. En el primer arranque de un
kernel nuevo, intentar cargar los módulos antes de que `akmods` termine
provocaría una carrera. Por eso, el propio servicio los carga únicamente
después de la compilación para ese kernel. La unit se omite automáticamente en
equipos sin un dispositivo ACPI MAX98390.

La topología objetivo es la del Galaxy Book4 Ultra: un cliente creado por ACPI
y tres amplificadores adicionales en `0x39`, `0x3c` y `0x3d`. El servicio solo
finaliza cuando existen los cuatro bindings; otra topología requiere un perfil
específico antes de usarla.

## Fedora 44 y Linux 7.1

En la combinación verificada actualmente, Fedora 44 con Linux 7.1, el
workaround todavía es necesario en los equipos afectados. El kernel aún no
reúne, al mismo tiempo, la creación de todos los amplificadores, el quirk
correspondiente en `snd-hda-codec-alc269` y el side-codec HDA `MAX98390`.

`max98390-hda-check-upstream.service` realiza una comprobación conservadora y
solo informa el resultado en el journal. No elimina ni desactiva el paquete.
Incluso un mensaje que detecte soporte nativo no garantiza que un kernel futuro
funcione en este notebook: compruebe los bindings y haga una prueba auditiva
real antes de retirar el workaround.

## Limitación actual de gestión de energía

En el Linux 7.1 auditado, `alc269` todavía no crea el component master necesario
para enlazar el side-codec con el codec HDA. Por eso, el fallback habilita el
DSP y los amplificadores durante el probe. Los amplificadores pueden permanecer
encendidos cuando no se reproduce audio, aumentando el consumo en idle.

Este comportamiento es una limitación conocida del workaround y no equivale a
una integración nativa completa con gestión de energía. No existe ninguna
promesa sobre cuándo esa integración llegará al kernel distribuido por Fedora.

## Diagnóstico y validación

Los siguientes comandos son de solo lectura:

```bash
kernel_release="$(uname -r)"

modinfo -k "$kernel_release" snd-hda-scodec-max98390
modinfo -k "$kernel_release" snd-hda-scodec-max98390-i2c

systemctl is-enabled max98390-hda-i2c-setup.service
systemctl is-active max98390-hda-i2c-setup.service
journalctl -b -u akmods.service -u max98390-hda-i2c-setup.service \
  -u max98390-hda-check-upstream.service --no-pager

find /sys/bus/i2c/devices -maxdepth 2 -type l -name driver \
  -lname '*max98390-hda*' -print

for module_name in snd-hda-scodec-max98390 snd-hda-scodec-max98390-i2c; do
  module_path="$(modinfo -k "$kernel_release" -n "$module_name")" || continue
  printf '%s -> ' "$module_path"
  rpm -qf "$module_path"
done
```

Los dos comandos `modinfo` deben localizar módulos para el kernel en ejecución.
Los archivos deben pertenecer al RPM `kmod` de esa versión y los clientes I2C
encontrados deben mostrar un binding con `max98390-hda`. Si `modinfo` responde
`Module not found`, consulte primero el log de `akmods`: copiar manualmente un
`.ko` a `/lib/modules` oculta el problema y deja el archivo fuera de la gestión
de RPM.

Repita esta validación después de cada actualización del kernel. La prueba
definitiva sigue siendo reproducir audio por los altavoces internos después de
arrancar con el nuevo kernel.

## Alcance

Este paquete solo se ocupa del camino de los altavoces `MAX98390`.

No sustituye:

- el driver de cámara `OV02C10`;
- la app `Galaxy Book Camera`;
- `Galaxy Book Setup`.

## Origen técnico

La base técnica de este driver deriva del trabajo publicado en:

- <https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes>

La diferencia aquí es el empaquetado orientado a Fedora, con foco en `RPM`,
`akmods`, `systemd` y mantenimiento predecible alineado con los demás
repositorios de esta línea.

## Estructura

- `module/`: fuentes de `snd-hda-scodec-max98390` y
  `snd-hda-scodec-max98390-i2c`
- `scripts/`: helper de arranque y comprobación de soporte nativo
- `data/`: units de `systemd`
- `packaging/fedora/`: spec RPM/akmod y generación del payload por kernel

## Build local

```bash
make build
make rpm
```

`make build` compila contra el kernel en ejecución. `make rpm` genera el paquete
fuente y los paquetes de entrada del flujo akmod; el payload cargable y
específico del kernel se produce cuando `akmods` compila para esa versión. Los
artefactos locales quedan en `dist/`.
