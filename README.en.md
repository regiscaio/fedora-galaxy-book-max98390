<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book MAX98390

RPM/akmod packaging for the `MAX98390` driver path used by the internal
speakers on Samsung Galaxy Book laptops under Fedora, initially focused on the
Galaxy Book4 Ultra.

## Quick install

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-max98390
```

The `akmod` package contains the sources and build recipe. `akmods` builds and
installs a `kmod-galaxybook-max98390-<kernel-release>` RPM for each kernel,
containing the two modules built specifically for that release. A module built
for another kernel is never reused.

## Goal

Some Galaxy Book models expose the sound card normally and even show the
speaker sink in the system, but the internal speakers remain silent. The
missing part on those models is the `MAX98390` amplifier side.

This repository organizes that support in the Fedora way:

- external modules rebuilt and delivered per kernel with `akmods`;
- a durable queue that finalizes each new kmod only after the RPM transaction
  ends, validating owner, `vermagic`, `depmod`, and resolution without removing
  or adopting any unmanaged legacy override;
- an authenticated global mutex that serializes module-index maintenance with
  other Galaxy Book drivers, including while a sibling runs `dracut`;
- a boot service that waits for `akmods`, explicitly loads both modules, and
  creates the missing I2C devices;
- bounded retries while ACPI, I2C, the modules, and the amplifiers become
  available;
- validation that the devices are bound to `max98390-hda` before the service
  reports success;
- a diagnostic helper that indicates when the kernel appears to contain every
  part of the native implementation.

No `modules-load.d` file is installed. On the first boot into a new kernel,
trying to load the modules before `akmods` finishes would create a race. The
service therefore loads them only after their per-kernel build. The I2C unit is
automatically skipped on machines without a MAX98390 ACPI device. The finalizer
runs first and inhibits shutdown/sleep only during its short critical section;
interrupted requests stay queued for a later try.

The target topology is the Galaxy Book4 Ultra's: one ACPI-created client and
three additional amplifiers at `0x39`, `0x3c`, and `0x3d`. The service only
completes when all four bindings exist; another topology requires an explicit
profile before use.

## Fedora 44 and Linux 7.1

On the currently verified combination, Fedora 44 with Linux 7.1, this
workaround is still required on affected systems. The kernel does not yet
combine the instantiation of every amplifier, the corresponding
`snd-hda-codec-alc269` quirk, and the `MAX98390` HDA side-codec.

`max98390-hda-check-upstream.service` performs a conservative check and only
reports its result to the journal. It does not remove or disable the package.
Even a native-support-detected message does not guarantee that a future kernel
will work on this laptop: verify the bindings and perform a real listening test
before removing the workaround.

## Current power-management limitation

On the audited Linux 7.1 kernel, `alc269` still does not create the component
master needed to bind the side-codec to the HDA codec. The fallback therefore
enables the DSP and amplifiers during probe. The amplifiers may remain powered
when nothing is playing, increasing idle power consumption.

This is a known limitation of the workaround and is not equivalent to complete
native integration with power management. There is no promise about when that
integration will reach the kernel shipped by Fedora.

## Diagnostics and validation

The commands below are read-only:

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

Both `modinfo` commands must locate modules for the running kernel. Those files
must belong to that release's `kmod` RPM, and the discovered I2C clients must
be bound to `max98390-hda`. If `modinfo` reports `Module not found`, inspect the
`akmods` log first: manually copying a `.ko` into `/lib/modules` hides the
problem and leaves the file outside RPM management.

Repeat this validation after every kernel update. The definitive test remains
playing audio through the internal speakers after booting the new kernel.

Since version `1.00.12`, integrations that have completed a kernel build can
wait for full finalization outside the RPM transaction with:

```bash
sudo /usr/libexec/galaxybook-max98390/max98390-kmod-finalize.sh \
  --kernel "$kernel_release"
```

The command succeeds only after validating both exact RPM owners and EVRs,
their `vermagic` values, running `depmod`, and confirming exact resolution of
both modules. An ownerless legacy override is preserved. The package's `depmod.d`
rule gives priority only to the two validated modules under
`extra/galaxybook-max98390`; if that payload is absent, the copy under
`updates` remains available as a fallback. The automatic queue uses the same
contract and retains interrupted requests for retry.

Before the MAX98390-private lock and RPM's shared lock, the finalizer acquires
the exclusive BSD mutex `/run/lock/galaxybook-kmod-lifecycle.lock`. An
authenticated descriptor can be inherited from a coordinating integration and
remains valid through marker acknowledgement. Ancestry, owner, mode `0600`,
hard-link count, and the path/FD `device:inode` identity are revalidated. The
wait is bounded to ten minutes; acquisition failures retain the queue and
prevent `depmod` or legacy-override inspection from starting.

The kernel-specific RPM `%post` and `%postun` scriptlets are intentionally
no-ops: acquiring the mutex inside the transaction would invert the RPM →
global order and could deadlock. Installation is queued by the common-package
trigger and finalized after the transaction. Automatic safe module removal is
not supported in this release: `%postun` is also a no-op, and a future
package-owned API must coordinate removal outside the transaction. Retain the
common package during any planned removal, and never run an ad-hoc `depmod` in
parallel with driver updates.

During common-package upgrades, `%pretrans` embeds a coordinator that records
an authenticated snapshot, arms persistent recovery, and masks/drains the
watcher, dependent I2C service, and worker before replacement. After the RPM
writer exits, recovery only opens a coherent `all-new` graph. A public legacy
install with no worker can have that original absence restored; an unsafe old
worker or mixed state remains masked for adoption by a compatible upgrade. All
starts are asynchronous to avoid an RPM → global-mutex inversion. When already
installed, peers must be `galaxybook-ov02c10-kmod-common >= 1.00.25` and
`galaxybook-setup >= 1.00.48`; these conditional dependencies do not pull in
absent peers.

This migration bootstrap requires a live `systemd` manager. In a chroot or an
offline root, scriptlets do not contact the manager, so they neither arm
recovery nor prove the preset and activation of units introduced by the
upgrade. Do not treat the initial migration as complete in that mode: repeat
the common-package transaction in a live session and validate the watcher.
After successful live recovery, the persistent watcher covers subsequent
reboots; no additional permanent service is introduced.

An explicit downgrade is outside this recovery contract. The normal solver
rejects MAX98390 older than `1.00.12` when the coordinated peers are present.
Do not force a coordinated downgrade, remove those peers, or install an older
build with `--nodeps`: those builds lack the current coordinator, and the local
`1.00.11` WIP included a worker that removed legacy overrides. The `all-old`
path only restores a pre-existing snapshot; it does not authorize a package
downgrade.

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

- `module/`: sources for `snd-hda-scodec-max98390` and
  `snd-hda-scodec-max98390-i2c`
- `scripts/`: per-kernel finalizer, fail-closed `kmodtool` filter, boot, and
  native-support helpers
- `data/`: `systemd` units
- `packaging/fedora/`: RPM/akmod spec and per-kernel payload generation

## Local build

```bash
make build
make rpm
```

`make build` compiles against the running kernel. `make rpm` creates the source
package and the entry packages for the akmod flow; the loadable,
kernel-specific payload is produced when `akmods` builds for that release.
Local artifacts are placed in `dist/`.

The `module/Makefile` `install` target is development-only and does not
participate in the lifecycle mutex. Production systems must use the RPM/akmod
flow and the packaged finalizer exclusively.
