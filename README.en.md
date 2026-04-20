<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book MAX98390

## Quick install

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-max98390
```

RPM/akmod packaging for the `MAX98390` driver path used by the internal
speakers on Samsung Galaxy Book laptops under Fedora, initially focused on the
Galaxy Book4 Ultra.

## Goal

Some Galaxy Book models expose the sound card normally and even show the
speaker sink in the system, but the internal speakers remain silent. The
missing part on those models is the `MAX98390` amplifier side.

This repository organizes that support in the Fedora way:

- external modules rebuilt with `akmods`;
- module autoload at boot;
- a boot service that creates the missing I2C amplifier devices;
- a helper to detect when the kernel already has sufficient native support.

## Scope

This package only handles the `MAX98390` speaker path.

It does not replace:

- the `OV02C10` camera driver;
- the `Galaxy Book Camera` app;
- `Galaxy Book Setup`.

## Technical origin

The code base for this driver derives from work published at:

- <https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes>

The difference here is Fedora-oriented packaging, focused on `RPM`, `akmods`,
`systemd`, and predictable maintenance aligned with the rest of this project
line.

## Structure

- `module/`: sources for `snd-hda-scodec-max98390` and `snd-hda-scodec-max98390-i2c`
- `scripts/`: boot helpers and native-support checks
- `data/`: `modules-load.d` files and `systemd` units
- `packaging/fedora/`: RPM spec

## Local build

```bash
make build
make rpm
```

Generated RPMs are placed in `dist/`.

## Current status

The goal of this first line is to deliver a testable and reproducible Fedora
package for the `MAX98390` path. Build validation is part of this repository;
audible validation on real hardware must be treated as the integration step on
the target notebook.
