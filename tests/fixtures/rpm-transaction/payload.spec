Name: max98390-rpm-lock-payload
Version: 1
Release: 1
Summary: MAX98390 RPM read-lock regression payload
License: MIT
BuildArch: noarch

%description
Payload used only inside the ephemeral RPM 6 transaction regression test.

%prep

%build

%install
install -d %{buildroot}/opt/max98390-rpm-lock-test
printf '%s\n' fixture > %{buildroot}/opt/max98390-rpm-lock-test/module.ko

%files
/opt/max98390-rpm-lock-test/module.ko
