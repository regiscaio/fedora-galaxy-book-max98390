<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book MAX98390

## Instalación rápida

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-max98390
```

Empaquetado en RPM/akmod del camino del driver `MAX98390` para los altavoces
internos de notebooks Samsung Galaxy Book en Fedora, con foco inicial en el
Galaxy Book4 Ultra.

## Objetivo

Algunos Galaxy Book exponen la tarjeta de sonido con normalidad e incluso
muestran el sink de salida en el sistema, pero los altavoces internos siguen
sin emitir audio. En esos modelos, la parte que falta es el lado de los
amplificadores `MAX98390`.

Este repositorio organiza ese soporte siguiendo el patrón de Fedora:

- módulos externos reconstruidos con `akmods`;
- carga automática de módulos en el arranque;
- servicio de arranque para crear los dispositivos I2C de los amplificadores
  ausentes;
- helper para detectar cuándo el kernel ya tiene soporte nativo suficiente.

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

- `module/`: fuentes de `snd-hda-scodec-max98390` y `snd-hda-scodec-max98390-i2c`
- `scripts/`: helpers de arranque y verificación de soporte nativo
- `data/`: archivos `modules-load.d` y units de `systemd`
- `packaging/fedora/`: spec RPM

## Build local

```bash
make build
make rpm
```

Los RPM generados quedan en `dist/`.

## Estado actual

El objetivo de esta primera línea es entregar un paquete Fedora comprobable y
reproducible para la ruta `MAX98390`. La validación de build forma parte de
este repositorio; la validación auditiva en hardware real debe tratarse como la
etapa de integración en el notebook objetivo.
