Name: max98390-rpm-lock-writer
Version: 1
Release: 1
Summary: MAX98390 RPM write-lock regression payload
License: MIT
BuildArch: noarch

%description
Writer used only inside the ephemeral RPM 6 transaction regression test.

%prep

%build

%install
install -d %{buildroot}/opt/max98390-rpm-lock-test
printf '%s\n' fixture > %{buildroot}/opt/max98390-rpm-lock-test/writer

%files
/opt/max98390-rpm-lock-test/writer
