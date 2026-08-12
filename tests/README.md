# Test suite

Run all tests from the repository root:

```sh
make test
```

`./tests/run.sh` is the equivalent direct runner.

The I2C tests execute the production helper against an isolated fake sysfs.
The helper keeps normal production defaults, while tests inject these variables:

- `MAX98390_SYSFS_ROOT` (default: `/sys`)
- `MAX98390_STATE_DIR` (default: `/run/galaxybook-max98390`)
- `MAX98390_I2CGET` (default: `i2cget`)
- `MAX98390_MODPROBE` (default: `modprobe`)
- `MAX98390_SLEEP` (default: `sleep`)
- `MAX98390_SYSFS_WRITE` (default: a write to sysfs), invoked as `<path> <value>`
- `MAX98390_MAX_ATTEMPTS`
- `MAX98390_RETRY_DELAY_SECONDS`

The fixture writer materializes I2C clients and their `max98390-hda` driver
symlinks, so success requires observable bindings for all four amplifiers. Tests
also cover transient probe misses, explicit bind retries (including the ACPI
client ID), the `MX98390` alias, rejection of a stable partial topology, failed
`new_device` writes, and ownership-safe cleanup with retry after a failed
`delete_device` write. The unit guard for hosts without this ACPI hardware is
checked as well.

Packaging tests pass `KERNEL_VERSION` (or `uname -r`) through the Fedora akmods
`%{kernels}` macro. They skip tool-specific checks when `kmodtool`, `rpmspec`,
or `rpm` is unavailable. To validate a built binary package explicitly, set
`KMOD_RPM` to its path; the test rejects empty tracking metapackages and requires
both `.ko` payloads. Set `COMMON_RPM` to the matching freshly built common RPM
to validate its preset payload. Binary tests deliberately require exact paths
instead of selecting potentially stale artifacts from `dist/`.

The packaging suite also requires the vendor systemd preset in the common RPM,
so unit enablement remains declarative and follows Fedora's systemd macros.
