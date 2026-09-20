# gir: libvirt / QEMU-KVM (ticket 24, module 8).
#
# Implements decisions already made; nothing here re-decides them:
#   * ticket 05 -- libvirt is kept natively and owned by `virtualisation.libvirtd.*`
#     (NOT `services.`). `coding-hive` must come back up on the first NixOS boot.
#     `winship-house` is shut off today and is the ONLY deferred service in the
#     whole migration: it gets a definition here, but no autostart, and it must
#     not be booted until the swtpm TODO at the bottom of this file is closed.
#   * ticket 05 -- `coding-hive-net.service` is kept, as a hand-written unit.
#   * ticket 07 item 16 -- `rpool/srv/libvirt` -> /var/lib/libvirt is SHARED with
#     Ubuntu. NixOS builds libvirt with `--sysconfdir=/var/lib`, so the guest and
#     network definitions Ubuntu keeps in /etc/libvirt/qemu do NOT come across and
#     each one needs a separate NixOS definition (below). Snapshot the dataset
#     before each VM's first NixOS boot; take no libvirt-managed snapshots during
#     the soak; winship-house's swtpm state is REUSED, never recreated.
#   * ticket 07 (2026-09-19) -- winship-house boots Secure Boot OVMF, so NixOS
#     needs an MS-keyed Secure Boot firmware. `/etc/libvirt/secrets` is empty, so
#     nothing is owed there.
#   * ticket 11 -- coding-hive's seed ISO is /home/myers/p/coding-hive/cloud-init/seed.iso
#     on `vmpool/myers/p`, and coding-hive-net.service's WorkingDirectory/ExecStart
#     are under /home/myers/p/coding-hive. Both are reachable only once that
#     dataset is mounted.
#   * users.nix section "Cross-module UID/GID parity" -- this module owes the
#     libvirt-qemu 64055 / kvm 109 pin. Decided 2026-09-19: service accounts that
#     own files on shared datasets keep Ubuntu's NUMERIC ids; nixpkgs' NAMES stay.
#   * storage.nix -- declares the /var/lib/libvirt mount and libvirtd's
#     RequiresMountsFor for it. This module adds /home/myers/p to that list;
#     `unitConfig.RequiresMountsFor` is list-valued, so the two concatenate.
#
# Facts below were read on 2026-09-19 from the sudo collection
# `logs/port-configs-20260919-191439/libvirt/` (both domain XMLs, both network
# XMLs, `virsh list --all`, `virsh pool-list`, a listing of /var/lib/libvirt) and
# from the live host (/etc/passwd, /etc/group, /usr/share/OVMF, the autostart
# symlink trees under /etc/libvirt, `systemctl cat coding-hive-net.service`,
# /etc/default/libvirt-guests, /etc/libvirt/libvirtd.conf).
#
##############################################################################
# WHAT IN THE LIVE XML DOES NOT SURVIVE UNCHANGED -- the full list
#
#  1. `<emulator>/usr/bin/qemu-system-x86_64</emulator>`
#     There is no /usr/bin on NixOS. Rewritten to the stable symlink farm
#     libvirtd-config maintains: /run/libvirt/nix-emulators/qemu-system-x86_64.
#     A raw /nix/store path must NOT be used: the domain XML lives on a ZFS
#     dataset, is not a GC root, and the store path would be collected.
#  2. OVMF, winship-house only.
#     `<loader>/usr/share/OVMF/OVMF_CODE_4M.ms.fd` (a symlink to
#     OVMF_CODE_4M.secboot.fd) and `<nvram template='/usr/share/OVMF/OVMF_VARS_4M.ms.fd'>`.
#     Neither path exists on NixOS, and `virtualisation.libvirtd.qemu.ovmf.*` was
#     REMOVED in 26.05 (the module now only exposes QEMU's own bundled edk2 via
#     /run/libvirt/nix-ovmf, which has no MS-keyed variables template). Built here
#     from `pkgs.OVMF` with `secureBoot`+`msVarsTemplate` -- the same Debian
#     edk2-vars-generator.py and Debian PkKek cert Ubuntu's own ovmf package uses --
#     and exposed at a stable, GC-rooted /run/gir-ovmf/ path via tmpfiles.
#     The nvram FILE itself (/var/lib/libvirt/qemu/nvram/winship-house_VARS.fd,
#     540672 bytes, the 4M layout) is on the shared dataset and is reused as-is;
#     the template is only consulted when the file is missing. That file is where
#     the enrolled MS keys and the Windows boot entries actually live.
#  3. Live-only XML that `virsh define` rejects or that pins a boot-specific id:
#     the `id='1'` attribute on `<domain>`, every `<alias name='...'/>` (define
#     only accepts user aliases, prefixed `ua-`), `index='N'` on `<source>`,
#     `<backingStore/>`, `state='connected'`, `<target dev='vnet0'/>` and
#     `<target dev='macvtap0'/>` on the interfaces, the guest-agent channel's
#     `<source path='.../domain-1-coding-hive/...'/>` (it embeds the domain id),
#     and both `<seclabel>` blocks. All stripped below.
#  4. `<seclabel type='dynamic' model='apparmor'>`. NixOS ships no AppArmor
#     profiles for libvirt and no virt-aa-helper policy, so the apparmor security
#     driver is off here and `security_driver = "none"` is set explicitly in
#     qemu.conf rather than left to libvirt's runtime probe. The DAC driver is
#     separate and still runs, which is what the second `<seclabel model='dac'>`
#     (+64055:+109) in the live dump actually describes -- see the uid/gid pin.
#  5. `<interface type='direct'><source dev='eno1' mode='bridge'/>`.
#     Survives ONLY while the host NIC is still called `eno1`. Both Ubuntu and
#     NixOS use systemd predictable names and the NIC is onboard, so it should
#     hold, but it is a hard dependency of the VM's LAN side and is asserted at
#     Window B by the rehearsal, not here (an eval-time check cannot see it).
#  6. `<interface type='bridge'><source bridge='virbr0'/>`.
#     virbr0 is not a host bridge; it belongs to libvirt's `default` network.
#     coding-hive attaches to it as a RAW bridge, so libvirt does not refcount the
#     network -- if `default` is not defined and autostarted, virbr0 does not
#     exist and the domain will not start. Both networks are therefore seeded with
#     their Ubuntu UUIDs, MACs and autostart symlinks below.
#  7. `machine='pc-q35-6.2'` on both domains. Ubuntu has QEMU 6.2; this nixpkgs
#     pin has QEMU 10.2.4. Versioned machine types are kept upstream for six
#     years, so pc-q35-6.2 (Dec 2021) is still there -- but it MUST be, because
#     changing the machine type changes guest-visible hardware, which for
#     winship-house means a Windows 11 reactivation and a BitLocker prompt. See
#     TODO(verify) at the bottom for the one-line Window B check.
#  8. CPU model: `host-passthrough`, no named model, on both. Nothing to
#     translate -- the physical CPU is the same machine. The `<topology>` is kept
#     verbatim so the guests see the same socket/core layout.
#  9. Host devices: there are NONE. Neither domain has a `<hostdev>`, so there is
#     no PCI/USB passthrough, no VFIO binding and no vfio-pci kernelParams to
#     carry. (tasks.py has `usb.attach`/`usb.detach`, but those hot-plug and are
#     not in the persistent XML.)
# 10. Hugepages: there are NONE. Neither domain has `<memoryBacking>` or
#     `<hugepages/>`, so no hugepage reservation, no `boot.kernelParams` and no
#     `hugetlbfs` mount is owed. coding-hive is a 64 GiB-max / 16 GiB-current
#     virtio-balloon domain -- worth remembering next to the 24 GiB arc_max, but
#     that is ticket 19's problem, not a config item here.
# 11. Disk backing: `/dev/zvol/vmpool/vms/{coding-hive,coding-hive-root,winship-house}`.
#     The paths are identical on NixOS (ZFS makes them), so they are kept
#     verbatim -- but they only exist after vmpool is imported, which is why
#     libvirtd gets a mount dependency here.
# 12. The CD-ROM and the serial/console log
#     (/home/myers/p/coding-hive/{cloud-init/seed.iso,logs/console.log}) are on
#     `vmpool/myers/p`, i.e. inside a home directory. Paths unchanged; the
#     dependency is handled by RequiresMountsFor on libvirtd and on
#     coding-hive-net.service.
# 13. Storage pools (`cloud-init`, `coding-hive`, `iso`) are NOT ported -- see
#     TODO(pools). They are directory pools used by virt-manager/virt-install;
#     no path in either domain XML resolves through a pool.
##############################################################################
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # ---------------------------------------------------------------------------
  # Stable paths. Everything a domain XML points at has to outlive a `nix-collect-
  # garbage`, because the XML is on a ZFS dataset and is not a GC root.
  # ---------------------------------------------------------------------------

  # Maintained by nixpkgs' own libvirtd-config.service (RuntimeDirectory, with
  # RuntimeDirectoryPreserve=yes), which symlinks every qemu-system-* into it.
  emulator = "/run/libvirt/nix-emulators/qemu-system-x86_64";

  # Ours, so it cannot collide with libvirtd-config's RuntimeDirectory handling.
  # The symlink targets are store paths held by systemd.tmpfiles.rules, which IS
  # part of the system closure -- that is what makes them GC-safe.
  ovmfDir = "/run/gir-ovmf";
  ovmfCode = "${ovmfDir}/OVMF_CODE_4M.ms.fd";
  ovmfVarsTemplate = "${ovmfDir}/OVMF_VARS_4M.ms.fd";

  # secureBoot => -D SECURE_BOOT_ENABLE, -D SMM_REQUIRE (matching `<smm state='on'/>`
  # in winship-house.xml) and -D FD_SIZE_4MB, which is the layout the existing
  # 540672-byte VARS file was made with. msVarsTemplate runs Debian's
  # edk2-vars-generator.py to enroll the Microsoft KEK/db with Debian's PkKek as
  # PK -- the same provenance as Ubuntu's OVMF_VARS_4M.ms.fd.
  ovmfMs = pkgs.OVMF.override {
    secureBoot = true;
    msVarsTemplate = true;
  };

  # libvirt's per-domain swtpm state is ${localstatedir}/lib/libvirt/swtpm/<uuid>.
  # nixpkgs builds libvirt with localstatedir=/var (only sysconfdir moves to
  # /var/lib), so the path is byte-identical to Ubuntu's and lands on the SHARED
  # dataset. Reuse is therefore automatic -- PROVIDED the domain keeps its UUID
  # and swtpm runs as the same numeric user. Both are handled below.
  swtpmStateDir = "/var/lib/libvirt/swtpm";

  # ---------------------------------------------------------------------------
  # Network definitions -- verbatim from the collection, UUID and MAC included.
  #
  # The UUIDs matter: nixpkgs' libvirtd-config.service seeds libvirt's stock
  # `default.xml` into /var/lib/libvirt/qemu/networks on first boot, libvirtd then
  # assigns it a RANDOM uuid and writes it back, and after that `virsh net-define`
  # with Ubuntu's uuid fails ("network 'default' already exists with uuid ...").
  # That is why the seeding unit below runs BEFORE libvirtd and overwrites the
  # network files instead of calling net-define after the fact.
  # ---------------------------------------------------------------------------

  netDefault = pkgs.writeText "libvirt-net-default.xml" ''
    <network>
      <name>default</name>
      <uuid>142c1b85-430c-460c-bf83-93fded216b99</uuid>
      <forward mode="nat">
        <nat>
          <port start="1024" end="65535"/>
        </nat>
      </forward>
      <bridge name="virbr0" stp="on" delay="0"/>
      <mac address="52:54:00:27:db:16"/>
      <ip address="192.168.122.1" netmask="255.255.255.0">
        <dhcp>
          <range start="192.168.122.2" end="192.168.122.254"/>
        </dhcp>
      </ip>
    </network>
  '';

  netWinshipHouse = pkgs.writeText "libvirt-net-winship-house-net.xml" ''
    <network>
      <name>winship-house-net</name>
      <uuid>88202af1-97c4-4419-87ac-15cab124a0e7</uuid>
      <forward mode="nat">
        <nat>
          <port start="1024" end="65535"/>
        </nat>
      </forward>
      <bridge name="virbr2" stp="on" delay="0"/>
      <mac address="52:54:00:3f:07:f0"/>
      <ip address="192.168.124.1" netmask="255.255.255.0">
        <dhcp>
          <range start="192.168.124.100" end="192.168.124.250"/>
        </dhcp>
      </ip>
    </network>
  '';

  # ---------------------------------------------------------------------------
  # Domain definitions.
  #
  # These are the live `virsh dumpxml` output with the live-only elements listed
  # in item 3 of the header stripped, and the two path classes in items 1 and 2
  # rewritten. Everything else -- UUID, PCI addresses, the fourteen pcie-root-ports,
  # MAC addresses, machine type, clock timers, VNC ports -- is preserved verbatim,
  # because all of it is guest-visible: the PCI addresses are what keep Debian's
  # `enp1s0`/`enp8s0` and Windows' NIC identity stable across the move.
  # ---------------------------------------------------------------------------

  domCodingHive = pkgs.writeText "libvirt-domain-coding-hive.xml" ''
    <domain type="kvm">
      <name>coding-hive</name>
      <uuid>6629e86b-3f50-4617-b734-068e36dc1a9a</uuid>
      <metadata>
        <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
          <libosinfo:os id="http://debian.org/debian/13"/>
        </libosinfo:libosinfo>
      </metadata>
      <memory unit="KiB">67108864</memory>
      <currentMemory unit="KiB">16777216</currentMemory>
      <vcpu placement="static">32</vcpu>
      <resource>
        <partition>/machine</partition>
      </resource>
      <os>
        <type arch="x86_64" machine="pc-q35-6.2">hvm</type>
        <boot dev="hd"/>
      </os>
      <features>
        <acpi/>
        <apic/>
      </features>
      <cpu mode="host-passthrough" check="none" migratable="on">
        <topology sockets="1" dies="1" cores="32" threads="1"/>
      </cpu>
      <clock offset="utc">
        <timer name="rtc" tickpolicy="catchup"/>
        <timer name="pit" tickpolicy="delay"/>
        <timer name="hpet" present="no"/>
      </clock>
      <on_poweroff>destroy</on_poweroff>
      <on_reboot>restart</on_reboot>
      <on_crash>destroy</on_crash>
      <pm>
        <suspend-to-mem enabled="no"/>
        <suspend-to-disk enabled="no"/>
      </pm>
      <devices>
        <emulator>${emulator}</emulator>
        <disk type="block" device="disk">
          <driver name="qemu" type="raw" cache="none" io="native" discard="unmap"/>
          <source dev="/dev/zvol/vmpool/vms/coding-hive-root"/>
          <target dev="vda" bus="virtio"/>
          <address type="pci" domain="0x0000" bus="0x04" slot="0x00" function="0x0"/>
        </disk>
        <disk type="block" device="disk">
          <driver name="qemu" type="raw" cache="none" io="native" discard="unmap"/>
          <source dev="/dev/zvol/vmpool/vms/coding-hive"/>
          <target dev="vdb" bus="virtio"/>
          <address type="pci" domain="0x0000" bus="0x05" slot="0x00" function="0x0"/>
        </disk>
        <disk type="file" device="cdrom">
          <driver name="qemu" type="raw"/>
          <source file="/home/myers/p/coding-hive/cloud-init/seed.iso"/>
          <target dev="sda" bus="sata"/>
          <readonly/>
          <address type="drive" controller="0" bus="0" target="0" unit="0"/>
        </disk>
        <controller type="usb" index="0" model="qemu-xhci" ports="15">
          <address type="pci" domain="0x0000" bus="0x02" slot="0x00" function="0x0"/>
        </controller>
        <controller type="pci" index="0" model="pcie-root"/>
        <controller type="pci" index="1" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="1" port="0x10"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x0" multifunction="on"/>
        </controller>
        <controller type="pci" index="2" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="2" port="0x11"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x1"/>
        </controller>
        <controller type="pci" index="3" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="3" port="0x12"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x2"/>
        </controller>
        <controller type="pci" index="4" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="4" port="0x13"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x3"/>
        </controller>
        <controller type="pci" index="5" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="5" port="0x14"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x4"/>
        </controller>
        <controller type="pci" index="6" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="6" port="0x15"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x5"/>
        </controller>
        <controller type="pci" index="7" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="7" port="0x16"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x6"/>
        </controller>
        <controller type="pci" index="8" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="8" port="0x17"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x7"/>
        </controller>
        <controller type="pci" index="9" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="9" port="0x18"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x0" multifunction="on"/>
        </controller>
        <controller type="pci" index="10" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="10" port="0x19"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x1"/>
        </controller>
        <controller type="pci" index="11" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="11" port="0x1a"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x2"/>
        </controller>
        <controller type="pci" index="12" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="12" port="0x1b"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x3"/>
        </controller>
        <controller type="pci" index="13" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="13" port="0x1c"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x4"/>
        </controller>
        <controller type="pci" index="14" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="14" port="0x1d"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x5"/>
        </controller>
        <controller type="sata" index="0">
          <address type="pci" domain="0x0000" bus="0x00" slot="0x1f" function="0x2"/>
        </controller>
        <controller type="virtio-serial" index="0">
          <address type="pci" domain="0x0000" bus="0x03" slot="0x00" function="0x0"/>
        </controller>
        <interface type="bridge">
          <mac address="52:54:00:23:09:72"/>
          <source bridge="virbr0"/>
          <model type="virtio"/>
          <address type="pci" domain="0x0000" bus="0x01" slot="0x00" function="0x0"/>
        </interface>
        <interface type="direct">
          <mac address="52:54:00:42:00:10"/>
          <source dev="eno1" mode="bridge"/>
          <model type="virtio"/>
          <address type="pci" domain="0x0000" bus="0x08" slot="0x00" function="0x0"/>
        </interface>
        <serial type="file">
          <source path="/home/myers/p/coding-hive/logs/console.log"/>
          <target type="isa-serial" port="0">
            <model name="isa-serial"/>
          </target>
        </serial>
        <console type="file">
          <source path="/home/myers/p/coding-hive/logs/console.log"/>
          <target type="serial" port="0"/>
        </console>
        <channel type="unix">
          <target type="virtio" name="org.qemu.guest_agent.0"/>
          <address type="virtio-serial" controller="0" bus="0" port="1"/>
        </channel>
        <input type="tablet" bus="usb">
          <address type="usb" bus="0" port="1"/>
        </input>
        <input type="mouse" bus="ps2"/>
        <input type="keyboard" bus="ps2"/>
        <graphics type="vnc" port="5900" autoport="yes" listen="127.0.0.1">
          <listen type="address" address="127.0.0.1"/>
        </graphics>
        <audio id="1" type="none"/>
        <video>
          <model type="virtio" heads="1" primary="yes"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x01" function="0x0"/>
        </video>
        <memballoon model="virtio">
          <address type="pci" domain="0x0000" bus="0x06" slot="0x00" function="0x0"/>
        </memballoon>
        <rng model="virtio">
          <backend model="random">/dev/urandom</backend>
          <address type="pci" domain="0x0000" bus="0x07" slot="0x00" function="0x0"/>
        </rng>
      </devices>
    </domain>
  '';

  # DEFERRED (ticket 05). Defined so the definition is not lost and so a single
  # `virsh start winship-house` is all that Window B+7 needs -- but deliberately
  # NOT autostarted, and not to be started until TODO(swtpm-owner) is closed.
  domWinshipHouse = pkgs.writeText "libvirt-domain-winship-house.xml" ''
    <domain type="kvm">
      <name>winship-house</name>
      <uuid>f056caf1-6702-4e2c-8d23-6b8ed1f18e90</uuid>
      <metadata>
        <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
          <libosinfo:os id="http://microsoft.com/win/11"/>
        </libosinfo:libosinfo>
      </metadata>
      <memory unit="KiB">8388608</memory>
      <currentMemory unit="KiB">8388608</currentMemory>
      <vcpu placement="static">4</vcpu>
      <os>
        <type arch="x86_64" machine="pc-q35-6.2">hvm</type>
        <loader readonly="yes" secure="yes" type="pflash">${ovmfCode}</loader>
        <nvram template="${ovmfVarsTemplate}">/var/lib/libvirt/qemu/nvram/winship-house_VARS.fd</nvram>
        <boot dev="hd"/>
      </os>
      <features>
        <acpi/>
        <apic/>
        <hyperv mode="custom">
          <relaxed state="on"/>
          <vapic state="on"/>
          <spinlocks state="on" retries="8191"/>
          <reset state="on"/>
        </hyperv>
        <smm state="on"/>
      </features>
      <cpu mode="host-passthrough" check="none" migratable="on">
        <topology sockets="1" dies="1" cores="4" threads="1"/>
      </cpu>
      <clock offset="localtime">
        <timer name="pit" tickpolicy="delay"/>
        <timer name="rtc" tickpolicy="catchup"/>
        <timer name="hpet" present="no"/>
        <timer name="hypervclock" present="yes"/>
      </clock>
      <on_poweroff>destroy</on_poweroff>
      <on_reboot>restart</on_reboot>
      <on_crash>destroy</on_crash>
      <pm>
        <suspend-to-mem enabled="no"/>
        <suspend-to-disk enabled="no"/>
      </pm>
      <devices>
        <emulator>${emulator}</emulator>
        <disk type="block" device="disk">
          <driver name="qemu" type="raw" cache="none" io="native" discard="unmap"/>
          <source dev="/dev/zvol/vmpool/vms/winship-house"/>
          <target dev="sda" bus="sata"/>
          <address type="drive" controller="0" bus="0" target="0" unit="0"/>
        </disk>
        <controller type="usb" index="0" model="qemu-xhci">
          <address type="pci" domain="0x0000" bus="0x02" slot="0x00" function="0x0"/>
        </controller>
        <controller type="pci" index="0" model="pcie-root"/>
        <controller type="pci" index="1" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="1" port="0x10"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x0" multifunction="on"/>
        </controller>
        <controller type="pci" index="2" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="2" port="0x11"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x1"/>
        </controller>
        <controller type="pci" index="3" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="3" port="0x12"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x2"/>
        </controller>
        <controller type="pci" index="4" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="4" port="0x13"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x3"/>
        </controller>
        <controller type="pci" index="5" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="5" port="0x14"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x4"/>
        </controller>
        <controller type="pci" index="6" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="6" port="0x15"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x5"/>
        </controller>
        <controller type="pci" index="7" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="7" port="0x16"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x6"/>
        </controller>
        <controller type="pci" index="8" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="8" port="0x17"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x7"/>
        </controller>
        <controller type="pci" index="9" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="9" port="0x18"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x0" multifunction="on"/>
        </controller>
        <controller type="pci" index="10" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="10" port="0x19"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x1"/>
        </controller>
        <controller type="pci" index="11" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="11" port="0x1a"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x2"/>
        </controller>
        <controller type="pci" index="12" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="12" port="0x1b"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x3"/>
        </controller>
        <controller type="pci" index="13" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="13" port="0x1c"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x4"/>
        </controller>
        <controller type="pci" index="14" model="pcie-root-port">
          <model name="pcie-root-port"/>
          <target chassis="14" port="0x1d"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x03" function="0x5"/>
        </controller>
        <controller type="sata" index="0">
          <address type="pci" domain="0x0000" bus="0x00" slot="0x1f" function="0x2"/>
        </controller>
        <interface type="network">
          <mac address="52:54:00:18:c7:0d"/>
          <source network="winship-house-net"/>
          <model type="e1000e"/>
          <address type="pci" domain="0x0000" bus="0x01" slot="0x00" function="0x0"/>
        </interface>
        <serial type="pty">
          <target type="isa-serial" port="0">
            <model name="isa-serial"/>
          </target>
        </serial>
        <console type="pty">
          <target type="serial" port="0"/>
        </console>
        <input type="tablet" bus="usb">
          <address type="usb" bus="0" port="1"/>
        </input>
        <input type="mouse" bus="ps2"/>
        <input type="keyboard" bus="ps2"/>
        <tpm model="tpm-crb">
          <backend type="emulator" version="2.0"/>
        </tpm>
        <graphics type="vnc" port="5930" autoport="no" listen="127.0.0.1">
          <listen type="address" address="127.0.0.1"/>
        </graphics>
        <audio id="1" type="none"/>
        <video>
          <model type="virtio" heads="1" primary="yes"/>
          <address type="pci" domain="0x0000" bus="0x00" slot="0x01" function="0x0"/>
        </video>
        <memballoon model="virtio">
          <address type="pci" domain="0x0000" bus="0x03" slot="0x00" function="0x0"/>
        </memballoon>
      </devices>
    </domain>
  '';
in
{
  ############################################################################
  ## 1. The daemon
  ############################################################################

  virtualisation.libvirtd = {
    enable = true;

    # Ubuntu runs qemu-system-x86 (the x86-only build), not the all-targets
    # package. `qemu_kvm` is nixpkgs' hostCpuOnly build, which is the same shape
    # and a much smaller closure. Nothing on gir emulates a foreign arch. If that
    # ever changes, this is a one-line switch to `pkgs.qemu`; the emulator path
    # in the domain XML does not move either way.
    qemu.package = pkgs.qemu_kvm;

    # Ubuntu's libvirt is compiled with user=libvirt-qemu, group=kvm, which is
    # what the live dump's `<seclabel model='dac'>+64055:+109</seclabel>` records.
    # nixpkgs defaults to running qemu AS ROOT; leaving that would make every
    # file libvirt touches on the shared dataset root-owned and would silently
    # diverge from the Ubuntu fallback. false makes the module emit
    # `user = "qemu-libvirtd"` / `group = "qemu-libvirtd"` into qemu.conf, and
    # section 2 pins those two names to Ubuntu's NUMBERS.
    qemu.runAsRoot = false;

    # swtpm for winship-house's `<tpm model='tpm-crb'><backend type='emulator'>`.
    # This only puts swtpm on libvirtd's PATH; the STATE is the shared dataset's
    # and is never recreated. See TODO(swtpm-owner) and TODO(swtpm-version).
    qemu.swtpm.enable = true;

    qemu.verbatimConfig = ''
      # nixpkgs' default, kept: libvirt's per-domain mount namespace rebuilds a
      # /dev tree for qemu and does not cope with the Nix store, so it is off.
      namespaces = []

      # Ubuntu labels domains with AppArmor (the live dump carries a
      # `<seclabel model='apparmor'>`). NixOS ships no libvirt AppArmor policy
      # and no virt-aa-helper profile, so the driver is disabled EXPLICITLY here
      # rather than left to libvirt's runtime probe -- a future
      # `security.apparmor.enable = true` elsewhere in this config would
      # otherwise make libvirt pick up a driver with no profiles and fail to
      # start every domain. The DAC driver is a separate, always-on stack entry
      # and still relabels disks to the qemu uid/gid, as on Ubuntu.
      security_driver = "none"

      # libvirt's own default is the "tss" account, which exists on Ubuntu as
      # 112:122 and therefore owns ${swtpmStateDir}/<uuid>/tpm2 on the SHARED
      # dataset. Stated explicitly, and the account is pinned in section 2, so
      # the existing TPM state stays readable from both OSes.
      swtpm_user = "tss"
      swtpm_group = "tss"
    '';

    # /etc/default/libvirt-guests on Ubuntu sets exactly these two and leaves
    # ON_BOOT/ON_SHUTDOWN at the script defaults (start / suspend). nixpkgs'
    # defaults differ (0 and 300), so both are carried. See TODO(managedsave).
    parallelShutdown = 10;
    shutdownTimeout = 120;
    onBoot = "start";
    onShutdown = "suspend";
  };

  # `<interface type='direct' ...>` needs macvtap, and virtio-net with vhost
  # acceleration needs vhost_net. Both are normally autoloaded via netlink
  # aliases; naming them removes a boot-order race that has already bitten this
  # host once (see the comment block inside coding-hive-net.service, which exists
  # because libvirt's autostart of coding-hive failed on a cold boot).
  boot.kernelModules = [
    "macvtap"
    "vhost_net"
  ];

  ############################################################################
  ## 2. UID/GID parity on the shared dataset
  ##
  ## users.nix section "Cross-module UID/GID parity" records this and leaves it
  ## here on purpose. /var/lib/libvirt/qemu is 0750 `libvirt-qemu:kvm` = 64055:109
  ## on disk and that dataset is shared with the Ubuntu fallback, so a chown is
  ## not available -- the numbers are pinned instead, exactly as postgresql.nix
  ## (110:119) and nut.nix (125:135) do. Names stay nixpkgs': the group that
  ## carries gid 109 here is called `qemu-libvirtd`, not `kvm`.
  ##
  ## `ids.uids`/`ids.gids` rather than `users.users.*.uid` because the libvirtd
  ## module derives both from `config.ids.*`; overriding there keeps a single
  ## definition and merges cleanly with users.nix. mkForce is required (unlike
  ## nut) because `qemu-libvirtd` = 301 DOES exist in nixpkgs' misc/ids.nix.
  ##
  ## Checked for collisions at this nixpkgs pin: uid 64055 is unused; gid 109 is
  ## reserved for `jenkins`, which is not enabled on gir; nixpkgs' own `kvm`
  ## group keeps gid 302, which is harmless because NixOS' udev ships
  ## /dev/kvm as MODE=0666 (Ubuntu has it 0660 root:109) -- qemu therefore does
  ## not need kvm-group membership to open it on either OS.
  ############################################################################

  ids.uids.qemu-libvirtd = lib.mkForce 64055;
  ids.gids.qemu-libvirtd = lib.mkForce 109;

  # Required BECAUSE of the pin, and easy to miss. nixpkgs' users-groups
  # assertion treats an account as a system user only if `isSystemUser` is set or
  # its uid is below 1000. Upstream's libvirtd module sets neither flag and relies
  # on 301 < 1000; Ubuntu's 64055 is above it, so without this the whole
  # configuration fails to evaluate with "Exactly one of
  # users.users.qemu-libvirtd.isSystemUser and ...isNormalUser must be set".
  users.users.qemu-libvirtd.isSystemUser = true;

  # swtpm runs under its own account, not qemu's. Ubuntu's `tss` is 112:122 and
  # owns the per-domain TPM state under ${swtpmStateDir} on the shared dataset;
  # NixOS has no `tss` unless `security.tpm2` is enabled, so libvirt would fall
  # back to root and chown winship-house's TPM state to 0:0 on first start --
  # which is precisely the "REUSED, never recreated" rule in ticket 07 item 16
  # being broken by omission. Neither id is in nixpkgs' misc/ids.nix (112 is a
  # commented-out ngircd, 122 is hydra, which is not enabled here).
  users.groups.tss.gid = 122;
  users.users.tss = {
    uid = 112;
    group = "tss";
    isSystemUser = true;
    description = "TPM software stack";
    home = "/var/lib/tpm";
  };

  ############################################################################
  ## 3. MS-keyed Secure Boot OVMF at a stable path
  ##
  ## `virtualisation.libvirtd.qemu.ovmf.*` was removed in 26.05, so there is no
  ## module option left to add a firmware to /run/libvirt/nix-ovmf. This builds
  ## the firmware and publishes it under a directory this module owns. tmpfiles
  ## rules are part of the system closure, so the store paths below are GC roots
  ## for as long as this generation exists -- which is what lets a domain XML
  ## sitting on a ZFS dataset safely point at them.
  ############################################################################

  systemd.tmpfiles.rules = [
    "d ${ovmfDir} 0755 root root -"
    "L+ ${ovmfCode} - - - - ${ovmfMs.firmware}"
    "L+ ${ovmfVarsTemplate} - - - - ${ovmfMs.variablesMs}"
  ];

  ############################################################################
  ## 4. Guest and network definitions
  ##
  ## MECHANISM: import the XML at activation, into libvirt's sysconfdir.
  ##
  ## NixOS has no first-class declarative domain option at this pin (the
  ## `virtualisation.libvirt.*` guest options live in the out-of-tree NixVirt
  ## flake, which this configuration does not take). The two candidates were
  ## (a) a post-start `virsh define` pass and (b) seeding the XML files that
  ## libvirt reads at startup. (b) is used, for one concrete reason: nixpkgs'
  ## libvirtd-config.service seeds libvirt's STOCK `default.xml` before libvirtd
  ## starts, libvirtd assigns it a random UUID, and from then on `virsh
  ## net-define` with Ubuntu's 142c1b85-... UUID is refused outright. Getting in
  ## before libvirtd is the only way to keep the existing network identity, and
  ## once this unit has to run there anyway, the domains ride along.
  ##
  ## The two halves have deliberately different write policies:
  ##
  ##   networks -- rewritten on every activation. They are small, fully described
  ##     here, and the stock default.xml must be overwritten on the first boot.
  ##
  ##   domains -- seeded ONLY IF ABSENT. coding-hive's own tooling edits the
  ##     persistent domain config at boot: `vm.boot-setup` calls `_ensure_lan_nic`,
  ##     which attaches the macvtap NIC with `virsh attach-device --config` when
  ##     it is missing. An unconditional rewrite would fight that on every switch.
  ##     Once seeded, the XML on the dataset is libvirt's, and the file here is
  ##     the canonical source to fold changes back into.
  ##
  ## To re-seed a domain deliberately (after editing the XML above):
  ##     virsh destroy <name>            # only if it must be recreated now
  ##     rm /var/lib/libvirt/qemu/<name>.xml
  ##     systemctl restart libvirtd.service
  ## which re-runs this unit through its Requires= edge.
  ##
  ## Ubuntu keeps all of this in /etc/libvirt/qemu instead (sysconfdir=/etc), so
  ## the files written here are invisible to the fallback boot and nothing
  ## conflicts. That is also why NONE of it came across on the shared dataset and
  ## why each VM needs its own NixOS definition (ticket 07 item 16).
  ############################################################################

  systemd.services.gir-libvirt-definitions = {
    description = "gir: seed libvirt network and domain definitions into /var/lib/libvirt";

    # Runs after libvirtd-config has seeded libvirt's stock files, and before
    # libvirtd reads the directory. requiredBy makes libvirtd pull it in and makes
    # it fail-closed: if the shared dataset is not mounted, libvirtd does not
    # start rather than start against an empty directory (ticket 07 rule 9).
    after = [ "libvirtd-config.service" ];
    before = [ "libvirtd.service" ];
    requiredBy = [ "libvirtd.service" ];
    wantedBy = [ "multi-user.target" ];

    unitConfig.RequiresMountsFor = [ "/var/lib/libvirt" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    # NOTE: mkdir -p, never `install -d`. /var/lib/libvirt/qemu already exists on
    # the shared dataset as 0750 libvirt-qemu:kvm; `install -d` would chmod and
    # chown an existing directory and quietly change what the Ubuntu fallback
    # sees. mkdir -p leaves an existing directory exactly as it is.
    script = ''
      set -eu

      domdir=/var/lib/libvirt/qemu
      netdir=$domdir/networks

      mkdir -p "$domdir" "$domdir/autostart" "$netdir" "$netdir/autostart"

      seed_network() {
        # $1 = network name, $2 = source XML
        install -m 0600 -o root -g root "$2" "$netdir/$1.xml"
        ln -sfn "$netdir/$1.xml" "$netdir/autostart/$1.xml"
      }

      seed_domain() {
        # $1 = domain name, $2 = source XML, $3 = autostart (yes|no)
        if [ ! -e "$domdir/$1.xml" ]; then
          echo "seeding new domain definition: $1"
          install -m 0600 -o root -g root "$2" "$domdir/$1.xml"
        fi
        if [ "$3" = yes ]; then
          ln -sfn "$domdir/$1.xml" "$domdir/autostart/$1.xml"
        else
          rm -f "$domdir/autostart/$1.xml"
        fi
      }

      seed_network default ${netDefault}
      seed_network winship-house-net ${netWinshipHouse}

      # coding-hive autostarts, matching /etc/libvirt/qemu/autostart/coding-hive.xml
      # on Ubuntu. coding-hive-net.service starts it too, and is written to cope
      # with either having won -- see `vm_boot_setup` in tasks.py.
      seed_domain coding-hive ${domCodingHive} yes

      # winship-house is the deferred service (ticket 05). Defined, never started.
      seed_domain winship-house ${domWinshipHouse} no
    '';
  };

  ############################################################################
  ## 5. libvirtd's own mount dependencies
  ##
  ## storage.nix already adds /var/lib/libvirt. coding-hive autostarts the moment
  ## libvirtd comes up, and its CD-ROM (the cloud-init seed ISO) and its console
  ## log are both on `vmpool/myers/p`. `unitConfig.RequiresMountsFor` is
  ## list-valued, so this definition concatenates with storage.nix's rather than
  ## conflicting -- the same merge nut.nix relies on.
  ############################################################################

  systemd.services.libvirtd.unitConfig.RequiresMountsFor = [ "/home/myers/p" ];

  ############################################################################
  ## 6. coding-hive-net.service
  ##
  ## Ported from /etc/systemd/system/coding-hive-net.service on the live host
  ## (read with `systemctl cat`, 2026-09-19). The unit itself is kept intact; the
  ## comments below record only what had to change and why.
  ##
  ## What it does: starts the domain if libvirt's own autostart did not, waits for
  ## the guest agent, then starts the mitmproxy MitM proxy and installs the
  ## host->VM iptables port forwards (8090/8091/8092) and the virbr0 allow-list
  ## chain. ExecStop tears the proxy and the rules back down.
  ############################################################################

  systemd.services.coding-hive-net = {
    description = "Coding Hive VM (autostart + proxy + port forwards)";
    wantedBy = [ "multi-user.target" ];

    requires = [ "libvirtd.service" ];
    after = [ "libvirtd.service" ];

    # Verbatim from the Ubuntu unit: the VM's macvtap LAN NIC hangs off the
    # physical eno1, and libvirt cannot create the macvtap device before that NIC
    # exists. vm.boot-setup starts the VM itself, so ordering THIS unit after the
    # network is what guarantees the parent NIC is up.
    wants = [ "network-online.target" ];

    # Ubuntu says `Requires=/After=zfs-mount.service` because tasks.py, bin/inv
    # and the uv venv all live on `vmpool/myers/p`, which mounts long after the
    # pool is imported. NixOS does not have zfs-mount.service -- and does not need
    # the proxy: /home/myers/p is a real entry in `fileSystems` (storage.nix), so
    # naming the path is both exact and stronger than ordering on a unit that
    # mounts everything.
    unitConfig.RequiresMountsFor = [
      "/home/myers/p"
      "/var/lib/libvirt"
    ];

    # tasks.py shells out to virsh, `sudo iptables`, `sudo sysctl`, pkill/ps, ip,
    # free and tail. Setting `path` would REPLACE PATH with only those store
    # paths and drop /run/wrappers/bin, where NixOS' setuid sudo lives -- so PATH
    # is written out in full instead, wrappers first. mkForce because the systemd
    # module already defines environment.PATH from `path`'s default set
    # (coreutils/findutils/gnugrep/gnused/systemd) for every service.
    environment = {
      LIBVIRT_DEFAULT_URI = "qemu:///system";
      PATH = lib.mkForce (
        lib.concatStringsSep ":" [
          "/run/wrappers/bin"
          (lib.makeBinPath [
            config.virtualisation.libvirtd.package # virsh
            config.networking.firewall.package # iptables
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.iproute2
            pkgs.procps
            pkgs.systemd
          ])
          "/run/current-system/sw/bin"
        ]
      );
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/home/myers/p/coding-hive";
      ExecStart = "/home/myers/p/coding-hive/bin/inv vm.boot-setup";
      ExecStop = "/home/myers/p/coding-hive/bin/inv proxy.stop";
    };

    # A `nixos-rebuild switch` must not bounce the proxy and the port forwards
    # (and so the VM's network) underneath a running coding-hive.
    restartIfChanged = false;
  };

  ############################################################################
  ## 7. Guards
  ############################################################################

  assertions = [
    {
      assertion =
        config.users.users.qemu-libvirtd.uid == 64055 && config.users.groups.qemu-libvirtd.gid == 109;
      message = ''
        libvirt's qemu account must keep Ubuntu's 64055:109 -- /var/lib/libvirt/qemu
        lives on rpool/srv/libvirt, which is shared with the Ubuntu fallback, and
        every file under it is owned by those numeric ids.
      '';
    }
    {
      assertion = !config.virtualisation.libvirtd.qemu.runAsRoot;
      message = ''
        virtualisation.libvirtd.qemu.runAsRoot must stay false: running qemu as
        root would write root-owned files onto the shared rpool/srv/libvirt
        dataset and diverge from Ubuntu, which runs qemu as 64055:109.
      '';
    }
    {
      assertion = config.users.users.tss.uid == 112 && config.users.groups.tss.gid == 122;
      message = ''
        The tss account must keep Ubuntu's 112:122: libvirt runs swtpm as `tss`
        and winship-house's TPM state under /var/lib/libvirt/swtpm is on the
        shared dataset. Ticket 07 item 16: that state is REUSED, never recreated.
      '';
    }
    {
      # coding-hive-net.service drives the `iptables` binary directly (nat
      # PREROUTING REDIRECT to mitmproxy, a FORWARD allow-list, POSTROUTING
      # MASQUERADE out of eno1). With networking.nftables.enable the NixOS
      # firewall stops managing iptables chains and libvirt switches its own
      # network backend to nftables, and those hand-written rules would silently
      # stop matching -- the VM would have unfiltered egress or none at all.
      assertion = !config.networking.nftables.enable;
      message = ''
        networking.nftables.enable must stay false while coding-hive-net.service
        installs raw iptables rules (see tasks.py IPTABLES_RULES). Porting the
        proxy to nftables is a separate piece of work, not a firewall-backend flip.
      '';
    }
    {
      # Cheap eval-time guard on the one nixpkgs API this module depends on that
      # was removed rather than renamed in 26.05.
      assertion = config.virtualisation.libvirtd.qemu.ovmf.packages == null;
      message = ''
        virtualisation.libvirtd.qemu.ovmf is a removed submodule at this nixpkgs
        pin. winship-house's MS-keyed Secure Boot firmware is supplied by this
        module through ${ovmfDir} instead; do not reintroduce the option.
      '';
    }
  ];

  ############################################################################
  ## Open items carried out of this module
  ##
  ## TODO(swtpm-owner) -- BLOCKS winship-house's first NixOS start, nothing else.
  ##   /var/lib/libvirt/swtpm is 0711 root:root and its contents could not be read
  ##   unprivileged, so the numeric owner of
  ##   /var/lib/libvirt/swtpm/f056caf1-6702-4e2c-8d23-6b8ed1f18e90/tpm2/ is
  ##   INFERRED (tss 112:122, libvirt's default swtpm_user and an account that
  ##   does exist on Ubuntu), not observed. Confirm with root before that domain
  ##   is ever started:
  ##       ls -lnR /var/lib/libvirt/swtpm
  ##   If it is 0:0, drop swtpm_user/swtpm_group from qemu.verbatimConfig and the
  ##   tss account above; if it is some other pair, pin that pair instead. Getting
  ##   this wrong makes libvirt chown the TPM state on first start, which breaks
  ##   the Ubuntu fallback and, if the state is then regenerated, takes
  ##   BitLocker's key with it.
  ##
  ## TODO(swtpm-version) -- same blast radius, same gate.
  ##   Ubuntu has swtpm 0.6.3; this nixpkgs pin has 0.10.1. The state directory is
  ##   shared, and while 0.10 reads 0.6 state, the reverse is not guaranteed. Take
  ##   the ticket 07 item 16 snapshot of rpool/srv/libvirt IMMEDIATELY before
  ##   winship-house's first NixOS start, and treat a rollback to Ubuntu after
  ##   that start as needing the snapshot, not a retry.
  ##
  ## TODO(verify) -- Window B, one line each, before declaring libvirt green:
  ##   1. qemu-system-x86_64 -M help | grep -w pc-q35-6.2
  ##      Both domains pin that machine type. If QEMU 10.2 has dropped it, the
  ##      migration needs a deliberate machine-type bump, which is guest-visible.
  ##   2. ip -br link | grep -w eno1
  ##      coding-hive's LAN NIC is a macvtap on eno1 by NAME.
  ##   3. virsh -c qemu:///system net-list --all
  ##      Expect `default` (virbr0) and `winship-house-net` (virbr2), both active
  ##      and autostart, and check their UUIDs are 142c1b85-... and 88202af1-...
  ##      A fresh UUID means this module lost the race with libvirtd-config.
  ##   4. virsh dumpxml coding-hive | grep -E 'emulator|nix-emulators'
  ##      Must be the /run/libvirt path, never /usr/bin and never /nix/store.
  ##
  ## TODO(pools) -- not on the critical path. Three autostarting directory pools
  ##   (`cloud-init`, `coding-hive`, `iso`, all on vmpool/myers/p) exist on Ubuntu
  ##   and are NOT ported: their XML is 0600 root in /etc/libvirt/storage and was
  ##   not in the collection, and no path in either domain XML resolves through a
  ##   pool, so no guest depends on them. They are virt-manager/virt-install
  ##   convenience. To port them later, collect with root:
  ##       cat /etc/libvirt/storage/{cloud-init,coding-hive,iso}.xml
  ##   and add a seed_network-shaped block for /var/lib/libvirt/storage.
  ##
  ## TODO(qemu.conf) -- /etc/libvirt/qemu.conf is 0600 root and could not be
  ##   diffed unprivileged. It is a dpkg conffile still carrying the package's own
  ##   2023-05-26 mtime, and `dpkg -V` could not check it for the same permission
  ##   reason, so "stock Ubuntu defaults" is strongly indicated but not proven.
  ##   The settings carried above (qemu user/group via the uid pin, swtpm_user,
  ##   namespaces, security_driver) are the ones that matter for a shared state
  ##   dataset. Before Window B, confirm nothing else is set:
  ##       grep -vE '^\s*#|^\s*$' /etc/libvirt/qemu.conf
  ##   /etc/libvirt/libvirtd.conf WAS readable and carries exactly two settings,
  ##   `auth_unix_ro = "none"` and `auth_unix_rw = "none"` (Ubuntu gates the
  ##   socket by the `libvirt` group instead). Those are deliberately NOT carried:
  ##   nixpkgs hardcodes polkit auth and ships a rule granting the `libvirtd`
  ##   group, which users.nix already puts myers in. Same reachability, better
  ##   default -- but it is a real behavioural delta, recorded here.
  ##
  ## TODO(managedsave) -- onShutdown = "suspend" is Ubuntu's effective setting and
  ##   is carried unchanged, but it means a host shutdown managedsaves coding-hive:
  ##   up to 64 GiB written into /var/lib/libvirt/qemu/save on rpool before the
  ##   host can power off. Ticket 05's NUT note already flags that
  ##   `override.battery.runtime.low = 300` assumes ZFS root + k3s + libvirt stop
  ##   inside five minutes and has never been measured. Measure it with the soak
  ##   quiet; if it does not fit, `onShutdown = "shutdown"` (parallelShutdown and
  ##   shutdownTimeout are already set for it) is the change.
  ##
  ## TODO(nix-ld) -- not this module's option, but this module's failure if it is
  ##   missing: ExecStart is /home/myers/p/coding-hive/bin/inv, a binstub into a
  ##   uv venv built for Ubuntu's file layout. Ticket 11 §6 enables
  ##   programs.nix-ld for exactly this; the rehearsal must run
  ##   `coding-hive-net.service` unchanged from the shared home before Window B.
  ############################################################################
}
