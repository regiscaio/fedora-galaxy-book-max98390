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

En el Galaxy Book4 Ultra 960XGL con ALC298 `144d:c1d8`, la versión 1.00.15
requiere el perfil Samsung de los cuatro amplificadores. El paquete no incluye
datos propietarios ni usa los ajustes Redrix como alternativa. Use
`/usr/libexec/galaxybook-max98390/prepare-samsung-dsm.py` con una copia local
autorizada de ADIAmpDriver.sys 1.0.0.44 o su CAB. Consulte las
[instrucciones](README.md#instalação-rápida).

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-max98390
```

El paquete `akmod` contiene las fuentes y la receta de compilación. `akmods`
compila e instala un RPM `kmod-galaxybook-max98390-<versión-del-kernel>` para
cada kernel, con los dos módulos destinados específicamente a esa versión. Un
módulo compilado para otro kernel nunca se reutiliza.

Desde la versión 1.00.16, una reconstrucción local solo genera el RPM del kernel
solicitado. Los servicios y el disparador de finalización siguen en el paquete
común del repositorio; recompilar el módulo no lo reinstala ni ejecuta su `%pretrans`.

## Objetivo

Algunos Galaxy Book exponen la tarjeta de sonido con normalidad e incluso
muestran el sink de salida en el sistema, pero los altavoces internos siguen
sin emitir audio. En esos modelos, la parte que falta es el lado de los
amplificadores `MAX98390`.

Este repositorio organiza ese soporte siguiendo el patrón de Fedora:

- módulos externos reconstruidos y entregados por kernel con `akmods`;
- una cola duradera que finaliza cada kmod después de que termine la transacción
  RPM, validando propietario, `vermagic`, `depmod` y resolución sin borrar ni
  adoptar ningún override legado no gestionado;
- un mutex global autenticado que serializa el mantenimiento de los índices de
  módulos con otros drivers Galaxy Book, incluso durante un `dracut` paralelo;
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
después de la compilación para ese kernel. La unit I2C se omite automáticamente
en equipos sin un dispositivo ACPI MAX98390. El finalizador se ejecuta antes y
bloquea apagado/suspensión solo durante su corta sección crítica; las solicitudes
interrumpidas permanecen en cola para un intento posterior.

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
  -u max98390-kmod-finalize.service \
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

Desde la versión `1.00.12`, las integraciones que hayan terminado el build de
un kernel pueden esperar la finalización completa fuera de la transacción RPM:

```bash
sudo /usr/libexec/galaxybook-max98390/max98390-kmod-finalize.sh \
  --kernel "$kernel_release"
```

El comando solo devuelve éxito después de validar los propietarios y EVRs RPM
exactos de ambos payloads, sus valores `vermagic`, ejecutar `depmod` y confirmar
la resolución exacta de ambos módulos. Un override legado sin propietario se conserva. La regla
`depmod.d` del paquete da prioridad solamente a los dos módulos validados en
`extra/galaxybook-max98390`; si ese payload no existe, la copia en `updates`
sigue disponible como fallback. La cola automática usa el mismo contrato y
conserva solicitudes interrumpidas.

Antes del lock privado de MAX98390 y del lock compartido de RPM, el finalizador
adquiere el mutex BSD exclusivo
`/run/lock/galaxybook-kmod-lifecycle.lock`. Una integración coordinadora puede
heredar el descriptor autenticado, que permanece válido hasta confirmar el
marcador. Se revalidan los ancestros, propietario, modo `0600`, cantidad de
hardlinks e identidad `device:inode` entre path y FD. La espera está limitada a
diez minutos; un fallo de adquisición conserva la cola e impide que comiencen
`depmod` o la inspección de los overrides legados.

Los scriptlets `%post` y `%postun` de los RPM específicos por kernel son no-op
intencionalmente: adquirir el mutex dentro de la transacción invertiría el
orden RPM → global y podría causar un deadlock. La instalación queda en cola
mediante el trigger del paquete común y se finaliza después de la transacción.
La eliminación automática y segura de los módulos no está soportada en esta
versión: `%postun` también es no-op y una futura API del paquete deberá
coordinar la eliminación fuera de la transacción. Conserve el paquete común
durante cualquier eliminación planificada y no ejecute un `depmod` aislado en
paralelo con actualizaciones de drivers.

Durante las actualizaciones del paquete común, `%pretrans` incorpora un
coordinador que registra un snapshot autenticado, arma una recuperación
persistente y enmascara/drena el watcher, el servicio I2C dependiente y el
worker antes del reemplazo. Cuando sale el writer RPM, la recuperación solo
abre un grafo `all-new` coherente. Un legado público sin worker puede recuperar
esa ausencia original; un worker antiguo inseguro o un estado mixto permanece
enmascarado para que lo adopte una actualización compatible. Todos los starts
son asíncronos para evitar una inversión RPM → mutex global. Si ya están
instalados, los peers deben ser `galaxybook-ov02c10-kmod-common >= 1.00.25` y
`galaxybook-setup >= 1.00.48`; estas dependencias condicionales no instalan
peers ausentes.

Este bootstrap de migración requiere un manager `systemd` activo. En un chroot
o una raíz offline, los scriptlets no contactan el manager, por lo que no arman
la recuperación ni comprueban el preset y la activación de las unidades
introducidas por la actualización. No considere completa la migración inicial
en ese modo: repita la transacción del paquete común en una sesión live y
valide el watcher. Tras una recuperación live correcta, el watcher persistente
cubre los reinicios posteriores; no se crea ningún servicio permanente
adicional.

Un downgrade explícito queda fuera de este contrato de recuperación. El solver
normal rechaza un MAX98390 anterior a `1.00.12` cuando los peers coordinados
están presentes. No fuerce un downgrade coordinado, elimine esos peers ni
instale un build anterior con `--nodeps`: esos builds carecen del coordinador
actual y el WIP local `1.00.11` incluía un worker que eliminaba overrides
legados. La ruta `all-old` solo restaura un snapshot preexistente; no autoriza
un downgrade de paquete.

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
- `scripts/`: helpers de finalización por kernel, filtro fail-closed de
  `kmodtool`, arranque y soporte nativo
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

El objetivo `install` de `module/Makefile` existe solo para desarrollo y no
participa en el mutex de lifecycle. En producción se deben usar exclusivamente
los RPM/akmods y el finalizador empaquetado.
