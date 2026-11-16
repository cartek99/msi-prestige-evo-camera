# Fedora packaging for libcamera-loopback (https://github.com/alanbato/libcamera-loopback).
# Built from the upstream v0.1.0 tag. Fedora changes from upstream's own packages:
#   - settings live in /etc/sysconfig/libcamera-loopback (Fedora convention),
#     with Fedora's libcamera and libcamera-gstreamer instead of /opt/libcamera;
#   - scripts go in /usr/libexec/libcamera-loopback;
#   - a systemd drop-in makes the service conflict with v4l2-relayd instances,
#     instead of masking them in a scriptlet, so switching back is one command;
#   - the libcamera AGC patch (written for libcamera 0.8.0) is not shipped.
#
# Before installing: v4l2loopback 0.13 or later (akmod build, from RPM Fusion),
# the patched libcamera tuning module installed system-wide, and libcamera
# version-locked. The relay runs as root and uses the system-wide module.
#
# Rollback: this package sets v4l2loopback max_buffers=3; v4l2-relayd was proven
# on the stock value (2). Re-enabling v4l2-relayd alone does not restore it:
#   systemctl disable --now libcamera-loopback
#   dnf remove libcamera-loopback
#   rm -f /etc/modprobe.d/v4l2loopback-maxbuffers.conf   (if set-loopback-buffers.sh ran)
#   systemctl enable v4l2-relayd.service   (the stub; its generator brings back the instances)
#   reboot

Name:           libcamera-loopback
Version:        0.1.0
Release:        6%{?dist}
Summary:        On-demand libcamera to v4l2loopback webcam relay

License:        AGPL-3.0-or-later
URL:            https://github.com/alanbato/libcamera-loopback
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz
Source1:        libcamera-loopback.sysconfig
Source2:        libcamera-loopback-fedora.conf
Source3:        v4l2loopback-libcamera-loopback.conf
# Stop the camera before suspend (IPU7 ISYS refuses to suspend while streaming).
Patch0:         0001-stop-camera-before-suspend.patch
Patch1:         0002-fallback-source.patch
Patch2:         0003-label-alternatives.patch
Patch3:         0004-watchdog-retry.patch

BuildArch:      noarch
# The relay hard-codes x86_64 ioctl structure layouts.
ExclusiveArch:  x86_64 noarch

BuildRequires:  systemd-rpm-macros

Requires:       python3
Requires:       python3-gobject
Requires:       gstreamer1
Requires:       gstreamer1-plugins-base
Requires:       libcamera-gstreamer
Requires:       libcamera-ipa
# vapostproc (Intel GPU denoise/sharpen) lives in the gst "va" plugin.
Recommends:     gstreamer1-plugins-bad-free
# The v4l2loopback kernel module comes from RPM Fusion.
Recommends:     v4l2loopback
%{?systemd_requires}

%description
libcamera-loopback feeds a v4l2loopback device from a libcamera camera through
GStreamer's libcamerasrc, so browsers, video-call apps and PipeWire can use MIPI
laptop cameras (Intel IPU6/IPU7) like a regular webcam. The camera only runs
while an application is reading. It replaces v4l2-relayd and writes frames with
write(), which avoids frozen video in PipeWire apps and crashes in browsers.

%prep
%autosetup -p1 -n %{name}-%{version}
sed -i '1s|^#!/usr/bin/env bash|#!/usr/bin/bash|' set-loopback-buffers.sh

%build
# Nothing to build: one Python program plus helper scripts.

%install
install -Dpm0755 libcamera-loopback.py   %{buildroot}%{_libexecdir}/%{name}/libcamera-loopback.py
install -Dpm0755 set-loopback-buffers.sh %{buildroot}%{_libexecdir}/%{name}/set-loopback-buffers.sh
install -Dpm0755 tools/frame-timing.py   %{buildroot}%{_libexecdir}/%{name}/tools/frame-timing.py

install -d %{buildroot}%{_unitdir}
sed -e 's|/usr/local/lib/libcamera-loopback/|%{_libexecdir}/%{name}/|' \
    -e 's|/etc/default/libcamera-loopback|%{_sysconfdir}/sysconfig/%{name}|' \
    libcamera-loopback.service > %{buildroot}%{_unitdir}/%{name}.service
chmod 0644 %{buildroot}%{_unitdir}/%{name}.service
install -Dpm0644 %{SOURCE2} %{buildroot}%{_unitdir}/%{name}.service.d/fedora.conf

install -Dpm0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/sysconfig/%{name}
install -Dpm0644 %{SOURCE3} %{buildroot}%{_modprobedir}/v4l2loopback-libcamera-loopback.conf
install -Dpm0644 packaging/common/modules-load.conf %{buildroot}%{_modulesloaddir}/%{name}.conf

%post
%systemd_post %{name}.service
# Upgrade from <= 0.1.0-3: the loopback was "Intel MIPI Camera". The module keeps that
# label until it is reloaded (reboot), so accept both until then (patch 0003), and add the
# fallback source (patch 0002) if the file has none. %config(noreplace) never rewrites it.
if [ $1 -ge 2 ]; then
    f=%{_sysconfdir}/sysconfig/%{name}
    sed -i 's/^LOOPBACK_LABEL=Intel MIPI Camera$/LOOPBACK_LABEL=Built-in Camera (Enhanced)|Intel MIPI Camera/' "$f" || :
    grep -q '^LOOPBACK_FALLBACK_SOURCE=' "$f" || \
        printf "%%s\n" "LOOPBACK_FALLBACK_SOURCE='libcamerasrc camera-name=\\\\_SB_.LNK0'" >> "$f" || :
fi

%preun
%systemd_preun %{name}.service

%postun
%systemd_postun_with_restart %{name}.service

%files
%license LICENSE
%doc README.md
%{_libexecdir}/%{name}/
%{_unitdir}/%{name}.service
%{_unitdir}/%{name}.service.d/
%config(noreplace) %{_sysconfdir}/sysconfig/%{name}
%{_modprobedir}/v4l2loopback-libcamera-loopback.conf
%{_modulesloaddir}/%{name}.conf

%changelog
* Tue Nov 10 2026 Keith Carter <oss@keithbcarter.com> - 0.1.0-6
- Stall watchdog, per-open retry of the main source, give up after repeated failures (patch 0004)
- Default --linger 10

* Tue Nov 10 2026 Keith Carter <oss@keithbcarter.com> - 0.1.0-5
- Fall back to LOOPBACK_FALLBACK_SOURCE when the source chain fails (patch 0002)
- --label accepts several labels separated by | (patch 0003); upgrade migrates the label

* Tue Nov 10 2026 Keith Carter <oss@keithbcarter.com> - 0.1.0-4
- Loopback card label "Built-in Camera (Enhanced)"; the relay is the only camera apps see

* Tue Nov 10 2026 Keith Carter <oss@keithbcarter.com> - 0.1.0-3
- Wait for akmods and load v4l2loopback in ExecStartPre instead of skipping silently
- Mesa shader cache dir for the root service

* Tue Nov 10 2026 Keith Carter <oss@keithbcarter.com> - 0.1.0-2
- Stop the camera before suspend; restart it on resume if an app is reading

* Mon Nov 09 2026 Keith Carter <oss@keithbcarter.com> - 0.1.0-1
- Initial Fedora package of upstream v0.1.0
