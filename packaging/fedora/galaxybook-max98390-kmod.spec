%global debug_package %{nil}
%global prjname galaxybook-max98390
%global pkg_version %{?pkg_version_override}%{!?pkg_version_override:1.0.0}
%global source_date_epoch_from_changelog 0
%global clamp_mtime_to_source_date_epoch 1

Name:           %{prjname}-kmod
Version:        %{pkg_version}
Release:        1%{?dist}
Summary:        MAX98390 speaker amplifier driver for Samsung Galaxy Book on Fedora
License:        GPL-2.0-only
URL:            https://github.com/regiscaio/fedora-galaxy-book-max98390
Source0:        %{name}-%{version}.tar.gz

ExclusiveArch:  x86_64

BuildRequires:  akmods
BuildRequires:  elfutils-libelf-devel
BuildRequires:  gcc
BuildRequires:  kmodtool
BuildRequires:  make
BuildRequires:  systemd-rpm-macros

%{expand:%(kmodtool --target %{_target_cpu} --repo fedora --kmodname %{prjname} --akmod %{?kernels:--for-kernels "%{?kernels}"} 2>/dev/null)}

%description
This package ships the out-of-tree MAX98390 HDA side-codec modules needed by
some Samsung Galaxy Book systems whose built-in speakers stay silent on Fedora
despite the audio codec being otherwise detected. It also installs the boot-time
service that creates the missing I2C devices for the speaker amplifiers.

%package -n %{pkg_kmod_name}-common
Summary:        Common files for the %{prjname} kernel module packaging
Requires:       binutils
Requires:       coreutils
Requires:       findutils
Requires:       grep
Requires:       gzip
Requires:       i2c-tools
Requires:       kmod
Requires:       rpm
Requires:       sed
Requires:       xz
Requires:       zstd
Recommends:     alsa-sof-firmware
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

%description -n %{pkg_kmod_name}-common
Common documentation, boot-time helpers and licensing files for the
%{prjname} kernel module packaging.

%prep
%setup -q -n %{name}-%{version}

%build
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
install -m 0755 scripts/max98390-hda-i2c-setup.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/max98390-hda-i2c-setup.sh
install -m 0755 scripts/max98390-hda-check-upstream.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/max98390-hda-check-upstream.sh
install -Dm0644 data/systemd/max98390-hda-i2c-setup.service \
  %{buildroot}%{_unitdir}/max98390-hda-i2c-setup.service
install -Dm0644 data/systemd/max98390-hda-check-upstream.service \
  %{buildroot}%{_unitdir}/max98390-hda-check-upstream.service
install -Dm0644 data/systemd-preset/80-galaxybook-max98390.preset \
  %{buildroot}%{_presetdir}/80-galaxybook-max98390.preset

for kernel_version in %{?kernel_versions}; do
  install -Dm0644 _kmod_build_${kernel_version%%___*}/snd-hda-scodec-max98390.ko \
    %{buildroot}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/sound/hda/codecs/side-codecs/snd-hda-scodec-max98390.ko
  install -Dm0644 _kmod_build_${kernel_version%%___*}/snd-hda-scodec-max98390-i2c.ko \
    %{buildroot}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/sound/hda/codecs/side-codecs/snd-hda-scodec-max98390-i2c.ko
done

%{?akmod_install}

%post -n %{pkg_kmod_name}-common
%systemd_post max98390-hda-i2c-setup.service max98390-hda-check-upstream.service

%preun -n %{pkg_kmod_name}-common
%systemd_preun max98390-hda-i2c-setup.service max98390-hda-check-upstream.service

%postun -n %{pkg_kmod_name}-common
%systemd_postun_with_restart max98390-hda-i2c-setup.service max98390-hda-check-upstream.service

%transfiletriggerin -n %{pkg_kmod_name}-common -- /lib/modules
set -eu
kernel_releases=""

while IFS= read -r installed_path; do
  case "$installed_path" in
    /lib/modules/*/extra/galaxybook-max98390/*snd-hda-scodec-max98390*.ko*)
      relative_path=${installed_path#/lib/modules/}
      # RPM consumes each doubled percent sign while expanding the spec.
      kernel_release=${relative_path%%%%/*}
      kernel_releases="${kernel_releases}${kernel_release}\n"
      ;;
  esac
done

printf '%b' "$kernel_releases" | sort -u | while IFS= read -r kernel_release; do
  [ -n "$kernel_release" ] || continue

  expected_owner="kmod-galaxybook-max98390-${kernel_release}"
  payload_root="/lib/modules/${kernel_release}/extra/galaxybook-max98390"

  # Validate the complete replacement before touching an unmanaged legacy
  # override. A partial kmod transaction must leave the working copy intact.
  for module_name in snd-hda-scodec-max98390 snd-hda-scodec-max98390-i2c; do
    payload_path=$(find "$payload_root" -type f \
      \( -name "${module_name}.ko" -o -name "${module_name}.ko.xz" -o -name "${module_name}.ko.zst" \) \
      -print -quit)
    if [ -z "$payload_path" ]; then
      echo "Missing packaged ${module_name} payload for ${kernel_release}" >&2
      exit 1
    fi

    owner_nevra=$(rpm -qf "$payload_path")
    case "$owner_nevra" in
      ${expected_owner}-*) ;;
      *)
        echo "Unexpected owner for ${payload_path}: ${owner_nevra}" >&2
        exit 1
        ;;
    esac

    vermagic=$(modinfo -F vermagic "$payload_path")
    case "$vermagic" in
      "${kernel_release} "*) ;;
      *)
        echo "Invalid vermagic for ${payload_path}: ${vermagic}" >&2
        exit 1
        ;;
    esac
  done

  for module_name in snd-hda-scodec-max98390 snd-hda-scodec-max98390-i2c; do
    for extension in ko ko.xz ko.zst; do
      legacy_path="/lib/modules/${kernel_release}/updates/sound/hda/codecs/side-codecs/${module_name}.${extension}"
      if [ -e "$legacy_path" ] && ! rpm -qf "$legacy_path" >/dev/null 2>&1; then
        rm -f -- "$legacy_path"
      fi
    done
  done

  depmod -a "$kernel_release"

  for module_name in snd-hda-scodec-max98390 snd-hda-scodec-max98390-i2c; do
    resolved_path=$(modinfo -k "$kernel_release" -n "$module_name")
    case "$resolved_path" in
      /lib/modules/${kernel_release}/extra/galaxybook-max98390/*) ;;
      *)
        echo "${module_name} resolved outside the packaged payload for ${kernel_release}: ${resolved_path}" >&2
        exit 1
        ;;
    esac
  done
done

%files -n %{pkg_kmod_name}-common
%{_datadir}/doc/%{pkg_kmod_name}/README.md
%license %{_datadir}/licenses/%{name}/LICENSE
%{_libexecdir}/%{prjname}/max98390-hda-i2c-setup.sh
%{_libexecdir}/%{prjname}/max98390-hda-check-upstream.sh
%{_unitdir}/max98390-hda-i2c-setup.service
%{_unitdir}/max98390-hda-check-upstream.service
%{_presetdir}/80-galaxybook-max98390.preset

%changelog
