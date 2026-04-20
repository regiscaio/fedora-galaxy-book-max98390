%global debug_package %{nil}
%global prjname galaxybook-max98390

Name:           %{prjname}-kmod
Version:        1.0.0
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

Requires:       i2c-tools
Recommends:     alsa-sof-firmware
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

%{expand:%(kmodtool --target %{_target_cpu} --repo fedora --kmodname %{prjname} --akmod 2>/dev/null)}

%description
This package ships the out-of-tree MAX98390 HDA side-codec modules needed by
some Samsung Galaxy Book systems whose built-in speakers stay silent on Fedora
despite the audio codec being otherwise detected. It also installs the boot-time
service that creates the missing I2C devices for the speaker amplifiers.

%package -n %{pkg_kmod_name}-common
Summary:        Common files for the %{prjname} kernel module packaging

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
install -Dm0644 data/modules-load.d/galaxybook-max98390.conf \
  %{buildroot}%{_modulesloaddir}/galaxybook-max98390.conf
install -d %{buildroot}%{_libexecdir}/%{prjname}
install -m 0755 scripts/max98390-hda-i2c-setup.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/max98390-hda-i2c-setup.sh
install -m 0755 scripts/max98390-hda-check-upstream.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/max98390-hda-check-upstream.sh
install -Dm0644 data/systemd/max98390-hda-i2c-setup.service \
  %{buildroot}%{_unitdir}/max98390-hda-i2c-setup.service
install -Dm0644 data/systemd/max98390-hda-check-upstream.service \
  %{buildroot}%{_unitdir}/max98390-hda-check-upstream.service

for kernel_version in %{?kernel_versions}; do
  install -Dm0755 _kmod_build_${kernel_version%%___*}/snd-hda-scodec-max98390.ko \
    %{buildroot}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/sound/hda/codecs/side-codecs/snd-hda-scodec-max98390.ko
  install -Dm0755 _kmod_build_${kernel_version%%___*}/snd-hda-scodec-max98390-i2c.ko \
    %{buildroot}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/sound/hda/codecs/side-codecs/snd-hda-scodec-max98390-i2c.ko
done

%{?akmod_install}

%post -n %{pkg_kmod_name}-common
%systemd_post max98390-hda-i2c-setup.service max98390-hda-check-upstream.service
systemctl enable max98390-hda-i2c-setup.service >/dev/null 2>&1 || :
systemctl enable max98390-hda-check-upstream.service >/dev/null 2>&1 || :

%preun -n %{pkg_kmod_name}-common
if [ $1 -eq 0 ]; then
  systemctl disable max98390-hda-i2c-setup.service >/dev/null 2>&1 || :
  systemctl disable max98390-hda-check-upstream.service >/dev/null 2>&1 || :
fi
%systemd_preun max98390-hda-i2c-setup.service max98390-hda-check-upstream.service

%postun -n %{pkg_kmod_name}-common
%systemd_postun_with_restart max98390-hda-i2c-setup.service max98390-hda-check-upstream.service

%files -n %{pkg_kmod_name}-common
%{_datadir}/doc/%{pkg_kmod_name}/README.md
%license %{_datadir}/licenses/%{name}/LICENSE
%{_modulesloaddir}/galaxybook-max98390.conf
%{_libexecdir}/%{prjname}/max98390-hda-i2c-setup.sh
%{_libexecdir}/%{prjname}/max98390-hda-check-upstream.sh
%{_unitdir}/max98390-hda-i2c-setup.service
%{_unitdir}/max98390-hda-check-upstream.service

%changelog
* Mon Apr 20 2026 Caio Régis <regiscaio@users.noreply.github.com> - 1.0.0-1
- Add the initial Fedora akmod packaging for the MAX98390 speaker fix
