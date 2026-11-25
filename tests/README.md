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
so unit enablement remains declarative and follows Fedora's systemd macros. It
expands the complete spec and rejects any per-kernel `%post`/`%postun` that is
not a strict no-op, as well as any residual in-transaction `depmod` call. The
separate `test_kmodtool_filter.sh` proves the build-time filter for zero, one,
and multiple kernel templates, preserves upstream failure status, and emits no
partial output when the upstream template or expected structure is rejected.
`test_dependency_fence.sh` uses isolated RPM roots to prove that optional peers
remain absent, legacy installed peers block without being removed, and the
declared OV02C10/setup floors solve by upgrading to compatible releases.
`test_upgrade_quiescence.sh` reads the rendered RPM scriptlet interpreter argv,
executes it with a hostile ambient environment, and proves the exact family
ABI, version floors, phase and instance-count forwarding. The shared
`test-finalizer-transaction.sh` then exercises authenticated state, runtime
masks, cgroup drain, all-new commit, safe legacy rollback, unsafe all-old and
mixed fail-closed recovery, interrupted phases, transient adoption, and the
GLOBAL/RPM/worker lock-cycle regression for both driver profiles.

`test_kmod_finalize.sh` exercises the durable queue, exact owner/EVR/vermagic
contract, non-destructive legacy preservation, RPM-compatible OFD read lock,
boot retry, concurrent enqueue convergence, and the global → private → RPM lock
order. `test_depmod_override.sh` uses real `depmod` and `modinfo` in a temporary
module root to prove exact RPM-payload priority, preserved legacy fallback, and
unchanged legacy hashes; CI can inject freshly built payloads through
`MAX98390_CORE_FIXTURE` and `MAX98390_I2C_FIXTURE`, while a matching host module
is used only as a fallback fixture. `test_kmod_lifecycle_lock.sh` covers
contention, metadata and ancestry authentication, descriptor inheritance
across `exec`, path/FD identity,
bounded failure without leaked locks, and the read-only descriptor edge. The
optional `test_rpm6_locking.sh` must run only in an ephemeral root container:

```sh
MAX98390_RPM6_EPHEMERAL_TEST=1 ./tests/test_rpm6_locking.sh
```

It builds and installs disposable fixture RPMs to prove on RPM 6 that a child
`rpm -qf` remains warning-free under the shared OFD lock, a real RPM write is
excluded for the complete critical section, and success, failure, and signal
termination all release the lock. The signal case deliberately leaves a
short-lived child holding the inherited OFD and waits for an exclusive-lock
checkpoint before starting the next RPM transaction, avoiding a scheduler
dependent false failure.
