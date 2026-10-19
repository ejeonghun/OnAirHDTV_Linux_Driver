# Built by packaging/build-rpm.sh, which passes the version from dkms.conf.
%global modname onairgt
%{!?pkgver: %global pkgver 0}

Name:           %{modname}-dkms
Version:        %{pkgver}
Release:        1
Summary:        OnAir GT USB HDTV (11ba:1101) ATSC DVB driver (DKMS)
License:        GPL-2.0-or-later
URL:            https://github.com/ejeonghun/OnAirHDTV_Linux_Driver
Source0:        %{modname}-%{version}.tar.gz
BuildArch:      noarch
Requires:       dkms
Requires:       (curl or wget)

%description
Out-of-tree dvb-usb-v2 driver (dvb-usb-onairgt) for the OnAir GT USB HDTV
tuner (Cypress FX2, LGDT3303, LG TDVS-H062F). DKMS builds it for every
installed kernel. The build downloads from kernel.org three kernel-private
headers that distribution header packages do not ship.

%prep
%setup -q -n %{modname}-%{version}

%build

%install
mkdir -p %{buildroot}/usr/src/%{modname}-%{version}
cp -a . %{buildroot}/usr/src/%{modname}-%{version}/

%post
# versions left by an upgrade
for v in $(dkms status -m %{modname} 2>/dev/null | sed -n "s|^%{modname}[/,] *\([^,:]*\).*|\1|p" | sort -u); do
	[ "$v" = "%{version}" ] || dkms remove -m %{modname} -v "$v" --all >/dev/null 2>&1 || :
done
dkms status -m %{modname} -v %{version} 2>/dev/null | grep -q . || dkms add -m %{modname} -v %{version} || :
for d in /lib/modules/*/build; do
	[ -e "$d/Makefile" ] || continue
	k=${d%/build}
	k=${k##*/}
	dkms install -m %{modname} -v %{version} -k "$k" ||
		echo "%{name}: build for $k failed, see /var/lib/dkms/%{modname}/%{version}/build/make.log" >&2
done
:

%preun
# on upgrades the new package's %%post has already removed this version
if [ "$1" -eq 0 ]; then
	dkms remove -m %{modname} -v %{version} --all >/dev/null 2>&1 || :
fi

%postun
if [ "$1" -eq 0 ]; then
	rm -rf /var/cache/%{modname}
fi

%files
%license LICENSE
/usr/src/%{modname}-%{version}
