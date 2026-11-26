%global debug_package %{nil}
%global prjname galaxybook-max98390
%global pkg_version %{?pkg_version_override}%{!?pkg_version_override:1.0.0}
%global source_date_epoch_from_changelog 0
%global clamp_mtime_to_source_date_epoch 1
%{!?_depmoddir:%global _depmoddir %{_prefix}/lib/depmod.d}
%global finalizer_interpreter /usr/bin/env -i PATH=/usr/bin:/usr/sbin GALAXYBOOK_FINALIZER_FAMILY=max98390 GALAXYBOOK_FINALIZER_COMMON_PACKAGE=galaxybook-max98390-kmod-common GALAXYBOOK_FINALIZER_OWN_FLOOR=0:1.00.12-0 GALAXYBOOK_FINALIZER_PEER_PACKAGE=galaxybook-ov02c10-kmod-common GALAXYBOOK_FINALIZER_PEER_FLOOR=0:1.00.25-0 GALAXYBOOK_FINALIZER_SETUP_PACKAGE=galaxybook-setup GALAXYBOOK_FINALIZER_SETUP_FLOOR=0:1.00.48-0 GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS=max98390-kmod-finalize.path GALAXYBOOK_FINALIZER_DEPENDENT_UNITS=max98390-hda-i2c-setup.service GALAXYBOOK_FINALIZER_SERVICE_UNIT=max98390-kmod-finalize.service GALAXYBOOK_FINALIZER_PENDING_DIRECTORY=/var/lib/galaxybook-max98390/pending GALAXYBOOK_FINALIZER_RECOVERY_UNIT=galaxybook-max98390-finalizer-transaction-recovery.service GALAXYBOOK_FINALIZER_STATE_DIRECTORY=/run/galaxybook-max98390-finalizer-transaction GALAXYBOOK_FINALIZER_SERVICE_CGROUP=/sys/fs/cgroup/system.slice/max98390-kmod-finalize.service/cgroup.procs /usr/bin/bash --noprofile --norc

Name:           %{prjname}-kmod
Version:        %{pkg_version}
Release:        1%{?dist}
Summary:        MAX98390 speaker amplifier driver for Samsung Galaxy Book on Fedora
License:        GPL-2.0-only
URL:            https://github.com/regiscaio/fedora-galaxy-book-max98390
Source0:        %{name}-%{version}.tar.gz
Source1:        kmodtool-queue-only-filter.sh
Source2:        finalizer-transaction.sh
Source3:        finalizer-transaction-pretrans.sh

ExclusiveArch:  x86_64

BuildRequires:  akmods
BuildRequires:  bash
BuildRequires:  coreutils
BuildRequires:  diffutils
BuildRequires:  elfutils-libelf-devel
BuildRequires:  gcc
BuildRequires:  kmodtool
BuildRequires:  make
BuildRequires:  systemd-rpm-macros

%global kmodtool_queue_only_build_verified 0
%global kmodtool_queue_only_filter_deferred 0
%if %{exists:/usr/bin/kmodtool}
%global kmodtool_queue_only_filter_ok 0
%{expand:%(/usr/bin/bash "%{SOURCE1}" --expected-kernels "%{?kernels}" -- /usr/bin/kmodtool --target %{_target_cpu} --repo fedora --kmodname %{prjname} --akmod %{?kernels:--for-kernels "%{?kernels}"})}
%if %{kmodtool_queue_only_filter_ok} != 1
%{error:kmodtool queue-only filtering failed}
%endif
%global kmodtool_queue_only_build_verified 1
%undefine kmodtool_queue_only_filter_ok
%else
%{?kernels:%{error:kmodtool is required to generate a source RPM with explicit kernels}}
# The initial COPR source-package chroot has rpm-build but has not installed
# BuildRequires yet.  Define only the names needed to parse an SRPM.  Rebuilding
# that SRPM installs kmodtool, reparses this spec, and must take the verified
# branch above before any binary stage is allowed to run.
%global kmod_pkg_name kmod-%{prjname}
%global pkg_kmod_name %{prjname}-kmod
%global kmodinstdir_prefix /lib/modules/
%global kmodinstdir_postfix /extra/%{prjname}/
%global kernel_versions %{nil}
%global kmodtool_queue_only_filter_deferred 1
%endif

%description
This package ships the out-of-tree MAX98390 HDA side-codec modules needed by
some Samsung Galaxy Book systems whose built-in speakers stay silent on Fedora
despite the audio codec being otherwise detected. It also installs the boot-time
service that creates the missing I2C devices for the speaker amplifiers.

%package -n %{pkg_kmod_name}-common
Summary:        Common files for the %{prjname} kernel module packaging
Requires:       bash
Requires:       binutils
Requires:       coreutils
Requires:       diffutils
Requires:       findutils
Requires:       grep
Requires:       gzip
Requires:       i2c-tools
Requires:       kmod
Requires:       rpm
Requires:       sed
Requires:       systemd
Requires:       util-linux-core
Requires:       xz
Requires:       zstd
Requires:       (galaxybook-ov02c10-kmod-common >= 1.00.25 if galaxybook-ov02c10-kmod-common)
Requires:       (galaxybook-setup >= 1.00.48 if galaxybook-setup)
Recommends:     alsa-sof-firmware
Requires(pretrans): bash
Requires(pretrans): coreutils
Requires(pretrans): diffutils
Requires(pretrans): rpm
Requires(pretrans): systemd
Requires(pretrans): util-linux-core
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
Requires(posttrans): bash
Requires(posttrans): coreutils
Requires(posttrans): diffutils
Requires(posttrans): rpm
Requires(posttrans): systemd
Requires(posttrans): util-linux-core

%description -n %{pkg_kmod_name}-common
Common documentation, boot-time helpers and licensing files for the
%{prjname} kernel module packaging.

%prep
%if %{kmodtool_queue_only_build_verified} != 1 || %{kmodtool_queue_only_filter_deferred} != 0
printf '%s\n' 'kmodtool queue-only filtering was deferred; refusing an unverified binary build' >&2
exit 65
%endif
%setup -q -n %{name}-%{version}

%build
%if %{kmodtool_queue_only_build_verified} != 1 || %{kmodtool_queue_only_filter_deferred} != 0
printf '%s\n' 'kmodtool queue-only filtering was deferred; refusing an unverified binary build' >&2
exit 65
%endif
for kernel_version in %{?kernel_versions}; do
  cp -a module _kmod_build_${kernel_version%%___*}
  make -C ${kernel_version##*___} M=${PWD}/_kmod_build_${kernel_version%%___*} modules
done

%install
install -d %{buildroot}%{_datadir}/doc/%{pkg_kmod_name}
install -m 0644 README.md %{buildroot}%{_datadir}/doc/%{pkg_kmod_name}/README.md
install -d %{buildroot}%{_datadir}/licenses/%{name}
install -m 0644 LICENSE %{buildroot}%{_datadir}/licenses/%{name}/LICENSE
install -d %{buildroot}%{_libexecdir}/%{prjname}
install -m 0755 scripts/prepare-samsung-dsm.py \
  %{buildroot}%{_libexecdir}/%{prjname}/prepare-samsung-dsm.py
install -m 0755 scripts/max98390-hda-i2c-setup.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/max98390-hda-i2c-setup.sh
install -m 0755 scripts/max98390-hda-check-upstream.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/max98390-hda-check-upstream.sh
install -m 0755 scripts/max98390-kmod-finalize.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/max98390-kmod-finalize.sh
install -Dm0755 %{SOURCE2} \
  %{buildroot}%{_libexecdir}/%{prjname}/finalizer-transaction
install -m 0644 scripts/kmod-lifecycle-lock.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/kmod-lifecycle-lock.sh
install -Dm0644 data/depmod.d/galaxybook-max98390.conf \
  %{buildroot}%{_depmoddir}/galaxybook-max98390.conf
install -Dm0644 data/systemd/max98390-hda-i2c-setup.service \
  %{buildroot}%{_unitdir}/max98390-hda-i2c-setup.service
install -Dm0644 data/systemd/max98390-hda-check-upstream.service \
  %{buildroot}%{_unitdir}/max98390-hda-check-upstream.service
install -Dm0644 data/systemd/max98390-kmod-finalize.service \
  %{buildroot}%{_unitdir}/max98390-kmod-finalize.service
install -Dm0644 data/systemd/max98390-kmod-finalize.path \
  %{buildroot}%{_unitdir}/max98390-kmod-finalize.path
install -Dm0644 data/systemd-preset/80-galaxybook-max98390.preset \
  %{buildroot}%{_presetdir}/80-galaxybook-max98390.preset
install -d -m0755 %{buildroot}%{_sharedstatedir}/galaxybook-max98390/pending
install -d -m0755 %{buildroot}%{_sharedstatedir}/galaxybook-max98390/deferred

for kernel_version in %{?kernel_versions}; do
  install -Dm0644 _kmod_build_${kernel_version%%___*}/snd-hda-scodec-max98390.ko \
    %{buildroot}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/sound/hda/codecs/side-codecs/snd-hda-scodec-max98390.ko
  install -Dm0644 _kmod_build_${kernel_version%%___*}/snd-hda-scodec-max98390-i2c.ko \
    %{buildroot}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/sound/hda/codecs/side-codecs/snd-hda-scodec-max98390-i2c.ko
done

%{?akmod_install}

%post -n %{pkg_kmod_name}-common
%systemd_post max98390-hda-i2c-setup.service max98390-hda-check-upstream.service max98390-kmod-finalize.path max98390-kmod-finalize.service

%pretrans -n %{pkg_kmod_name}-common -p "%{finalizer_interpreter}" -f %{SOURCE3}

%posttrans -n %{pkg_kmod_name}-common -p "%{finalizer_interpreter}"
%{_libexecdir}/%{prjname}/finalizer-transaction --posttrans "$1"

%preun -n %{pkg_kmod_name}-common
%systemd_preun max98390-hda-i2c-setup.service max98390-hda-check-upstream.service max98390-kmod-finalize.path max98390-kmod-finalize.service

%postun -n %{pkg_kmod_name}-common
%systemd_postun_with_restart max98390-hda-i2c-setup.service max98390-hda-check-upstream.service max98390-kmod-finalize.path max98390-kmod-finalize.service

%transfiletriggerin -n %{pkg_kmod_name}-common -p /usr/bin/bash -- /lib/modules /usr/lib/modules
%{_libexecdir}/%{prjname}/max98390-kmod-finalize.sh --from-rpm-trigger

%files -n %{pkg_kmod_name}-common
%{_datadir}/doc/%{pkg_kmod_name}/README.md
%license %{_datadir}/licenses/%{name}/LICENSE
%{_libexecdir}/%{prjname}/prepare-samsung-dsm.py
%{_libexecdir}/%{prjname}/max98390-hda-i2c-setup.sh
%{_libexecdir}/%{prjname}/max98390-hda-check-upstream.sh
%{_libexecdir}/%{prjname}/max98390-kmod-finalize.sh
%{_libexecdir}/%{prjname}/finalizer-transaction
%{_libexecdir}/%{prjname}/kmod-lifecycle-lock.sh
%{_depmoddir}/galaxybook-max98390.conf
%{_unitdir}/max98390-hda-i2c-setup.service
%{_unitdir}/max98390-hda-check-upstream.service
%{_unitdir}/max98390-kmod-finalize.path
%{_unitdir}/max98390-kmod-finalize.service
%{_presetdir}/80-galaxybook-max98390.preset
%dir %{_sharedstatedir}/galaxybook-max98390
%dir %{_sharedstatedir}/galaxybook-max98390/deferred
%dir %{_sharedstatedir}/galaxybook-max98390/pending

%changelog
