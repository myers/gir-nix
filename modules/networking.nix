# Ticket 24 — host networking and firewalling for gir (ticket 14's decisions).
#
# This is the last module of the port. Everything here is *parity with Ubuntu at
# cutover*; every hardening idea waits until after the soak. Ticket 14
# (`.scratch/nixos-migration/issues/14-firewall-and-host-networking.md`) is the
# decision record — this file implements it and does not re-decide it.
#
# Scope. This module owns: systemd-networkd, the two MAC-pinned `.link` files,
# eno1's and lan1g's `.network` files, the firewall switch and its backend,
# /etc/hosts, DNS, and the networking sysctls. It owns nothing else:
#   * ssh.nix       owns sshd and fail2ban (it reads `networking.enableIPv6` and
#                   `networking.nftables.enable` from here — see the note below)
#   * netconsole.nix owns the outbound netconsole target; it re-derives its
#                   device and source address from the default route, so it only
#                   needs `network-online.target` to be real
#   * storage.nix   owns fileSystems; users.nix owns the accounts
#   * hosts/gir/configuration.nix owns `networking.hostName` and
#                   `networking.hostId` — not restated here
#
# Note for ssh.nix's TODO: this module deliberately does **not** set
# `networking.enableIPv6 = false`. IPv6 is disabled the way Ubuntu disables it,
# with `net.ipv6.conf.*.disable_ipv6` sysctls, so sshd still lands on
# `AddressFamily any` and fail2ban still gets its `::1` from nixpkgs. Setting the
# NixOS option would additionally add `ipv6.disable=1` to the kernel command line
# and kill the link-local addresses that eno1 and lan1g carry today.
{ lib, pkgs, ... }:

{
  ############################################################################
  # 1. Firewall: OFF. This is the single most important line in the module.
  ############################################################################

  # NixOS defaults `networking.firewall.enable` to TRUE. Ubuntu filters nothing:
  # `ufw` is installed but inactive, and every rule in `iptables-save` on gir
  # today comes from k3s/kube-router, CNI or libvirt. gir sits on a trusted LAN
  # behind misfit.
  #
  # Leaving the NixOS default in place would be a silent, self-inflicted
  # migration outage that looks like a k3s failure: pod→apiserver (6443),
  # kubelet metrics (10250), flannel VXLAN (8472/udp), the servicelb hostPorts
  # and every NodePort would all start dropping. So: off, explicitly, with the
  # reason written down. The k3s module's `after`/`wants = firewall.service`
  # becomes a harmless no-op.
  #
  # Consequence that is expected and correct: nixpkgs emits the eval warning
  # "fail2ban can not be used without a firewall". It is a warning, not an
  # assertion; bans still land through the iptables-nft shim. ssh.nix documents
  # why it is not silenced.
  #
  # Turning this back on is a post-soak hardening decision with its own ticket.
  # samba.nix, plex.nix and ssh.nix all keep their `openFirewall`-style options
  # explicitly false so that day is a deliberate, visible change.
  networking.firewall.enable = false;

  # Backend: iptables-nft, i.e. the `iptables v1.8.7 (nf_tables)` shim Ubuntu
  # runs. `false` is already the nixpkgs default; it is restated because three
  # separate consumers silently change behaviour with it:
  #   * k3s/kube-router  ships and calls `iptables`
  #   * fail2ban         picks banaction `iptables-multiport` only while this is
  #                      false (nftables → `nftables-multiport`)
  #   * libvirt          `firewallBackend` defaults to `iptables` while this is
  #                      false, matching Ubuntu's libvirt 8.0
  # Mixing native nft with the iptables shim is the known failure mode here.
  # Nothing on this host should be moved to native nft during the migration.
  networking.nftables.enable = false;

  # Ubuntu has the iptables CLI on PATH; with the firewall disabled nixpkgs does
  # not install it (the firewall module adds it only when enabled) and k3s keeps
  # its copy private to its unit. First-boot test 3 needs `iptables -V` and
  # `iptables-legacy-save`, and so does anyone debugging a KUBE- chain.
  environment.systemPackages = [ pkgs.iptables ];

  ############################################################################
  # 2. Network stack: systemd-networkd
  ############################################################################

  # The same stack netplan renders into /run on Ubuntu today, minus netplan.
  networking.useNetworkd = true;

  # Must be false. `networking.useDHCP` defaults to TRUE, and under networkd it
  # generates a catch-all `99-ethernet-default-dhcp.network` matching every
  # physical ether link. That would start a DHCP client on lan1g and on the BMC's
  # USB NIC `enxb03af2b6059f`, both of which are deliberately without IPv4 today.
  networking.useDHCP = false;

  ############################################################################
  # 3. NIC naming — MAC-pinned .link files
  ############################################################################

  # The collision, from netplan/01-netcfg.yaml and confirmed on the host: this
  # board's SMBIOS marks BOTH NICs as "Onboard Device / Type Instance: 1", so
  # udev's default policy computes `eno1` for both and the loser of the rename
  # race falls back to `ethN`. On 2026-08-29 that coin flip turned into a full
  # outage needing BMC console access.
  #
  # Names must therefore be pinned by MAC from the initrd, before udev
  # enumerates the PCI NICs. NixOS 26.05 uses systemd stage 1, and
  # nixos/modules/system/boot/networkd.nix copies every `.link` unit from
  # `systemd.network.links` into the initrd for exactly this reason ("Networkd
  # link files are used early by udev to set up interfaces early. This must be
  # done in stage 1 to avoid race conditions"). So these two entries are
  # sufficient; no `boot.initrd.systemd.network` configuration is needed.
  #
  # `AlternativeNamesPolicy=path` reproduces the altnames the host carries today
  # (`enp105s0` on eno1, `enp102s0` on lan1g).

  systemd.network.links."10-eno1" = {
    # Aquantia AQC113C, 10GbE, pci 0000:69:00.0, driver atlantic.
    matchConfig.MACAddress = "3c:ec:ef:7f:2a:96";
    linkConfig = {
      Name = "eno1";
      AlternativeNamesPolicy = "path";
    };
  };

  systemd.network.links."10-lan1g" = {
    # Intel I210, 1GbE, pci 0000:66:00.0, driver igb.
    matchConfig.MACAddress = "3c:ec:ef:7f:28:aa";
    linkConfig = {
      Name = "lan1g";
      AlternativeNamesPolicy = "path";
    };
  };

  ############################################################################
  # 4. Addressing
  ############################################################################

  # RULE: the `.network` units match on PermanentMACAddress ONLY, never on
  # `Name=`. If the `.link` above ever loses its race and the card comes up as
  # `ethN`, a MAC-only match degrades to a cosmetic naming problem; adding
  # `Name=` would make networkd skip the link entirely and leave the host with
  # NO NETWORK. This is the mistake netplan's comment block warns about at
  # length, and it is the difference between a reboot and a BMC session.
  #
  # The name `eno1` is still load-bearing elsewhere (coding-hive's second NIC is
  # a `type='direct'` macvtap on `dev='eno1'`), which is what the `.link` file is
  # for. The `.network` file must not depend on it.

  systemd.network.networks."10-eno1" = {
    matchConfig.PermanentMACAddress = "3c:ec:ef:7f:2a:96";

    # DHCPv4 only, as netplan's `dhcp4: true` / no dhcp6 renders today. The
    # default route (via 192.168.42.1), DNS (192.168.42.1) and the search domain
    # (home.arpa) all arrive from the lease, exactly as they do now.
    networkConfig = {
      DHCP = "ipv4";
      # Ubuntu's rendered value; also networkd's default. Stated because the
      # 192.168.69.1 address below is IPv4-only and it should be obvious that
      # the fe80:: address on this link is intentional.
      LinkLocalAddressing = "ipv6";
      # Ticket 14. There are no RAs on this segment today (eno1 carries only a
      # link-local v6 address), so this is parity in effect while making the
      # absence of a global v6 address a decision rather than an accident.
      # lan1g is left at networkd's default: it has no addresses at all and
      # nothing depends on it.
      IPv6AcceptRA = false;
    };

    ####################################################################
    # DHCP client identity — pinned byte-for-byte. Read this before editing.
    ####################################################################
    #
    # misfit (Kea) holds the reservation for 192.168.42.8. Today networkd sends
    # a type-255 client-id built from an IAID plus a DUID-EN, and that DUID is
    # derived from /etc/machine-id. NO TICKET CARRIES /etc/machine-id OVER to
    # NixOS (Ubuntu's is 16292c6825744542a470ca2660207b27; NixOS will generate a
    # fresh one on first boot). Left alone, the client-id would therefore change
    # at cutover, and if Kea keys the reservation on client-id rather than
    # hw-address the host comes back on a different address — with the k3s
    # node-ip, the apiserver SANs, Samba's `interfaces = 192.168.42.8` and every
    # LAN client pointing at the old one.
    #
    # So the identity is pinned literally. The wire value, from the host's own
    # networkd lease file (`network/2`, i.e. /run/systemd/netif/leases/2, the
    # lease for ifindex 2 = eno1):
    #
    #   CLIENTID=ffb6220feb00020000ab11280a732640d13f64
    #
    # decomposed as systemd builds it:
    #   ff                         type 255 (IAID + DUID)
    #   b6 22 0f eb                IAID  = 0xb6220feb = 3055685611
    #   00 02                      DUID type 2 (DUID-EN, vendor-assigned)
    #   00 00 ab 11                IANA enterprise number 43793 (systemd)
    #   28 0a 73 26 40 d1 3f 64    the machine-id-derived identifier
    #
    # `networkctl status eno1` corroborates it:
    #   DHCP4 Client ID: IAID:0xb6220feb/DUID
    #   DHCP6 Client DUID: DUID-EN/Vendor:0000ab11280a732640d13f64...
    #
    # Per systemd.network(5), for `DUIDType=vendor` the enterprise number is part
    # of `DUIDRawData` — the raw data is everything after the 2-byte DUID type.
    # Do not strip the leading 00:00:ab:11.
    #
    # Corroborating evidence for the reservation itself:
    # `misfit-kea-gir-leases-2026-08-30.log`.
    dhcpV4Config = {
      ClientIdentifier = "duid";
      IAID = 3055685611; # 0xb6220feb — nixpkgs asserts this is an integer
      DUIDType = "vendor";
      DUIDRawData = "00:00:ab:11:28:0a:73:26:40:d1:3f:64";

      # netplan writes RouteMetric=100 for dhcp4 on ethernets; networkd's own
      # default is 1024. `ip route` on gir shows `metric 100` on both the default
      # route and the 192.168.42.0/24 link route, so 100 it is.
      RouteMetric = 100;
    };

    # 192.168.69.1/24 — host-only secondary, deliberately DEPRECATED.
    #
    # `PreferredLifetime = 0` is the deprecated flag: the address stays usable as
    # a destination and for explicit binds, but the kernel will never pick it as
    # a source address for outbound connections. That is what keeps it from
    # hijacking traffic that belongs on 192.168.42.8.
    #
    # It has no neighbours on the wire at all. Pods reach it for postgres
    # (`listen_addresses = 'localhost,192.168.69.1'`), coturn, and cbm-dolt's
    # hostIP 3306 — so postgresql.nix must be ordered after
    # `network-online.target` or the bind fails on a cold boot.
    #
    # DROPPED vs netplan: the `label: "eno1:0"` (visible today as
    # `... scope global deprecated eno1:0`). Ticket 14 specifies this address
    # without a label, and deliberately so — the kernel rejects an address label
    # that is not `<ifname>` or `<ifname>:<suffix>`, so `Label=eno1:0` would
    # reintroduce exactly the hard dependency on winning the naming race that
    # matching by MAC exists to remove. A lost race would then mean no
    # 192.168.69.1 and a dead postgres bind instead of a cosmetic wrong name.
    # Nothing reads the label; it is an ifconfig-era artifact.
    addresses = [
      {
        Address = "192.168.69.1/24";
        PreferredLifetime = 0;
      }
    ];

    # netplan has no `optional:` on this NIC, so boot waits for it to be
    # routable. Keep that: if eno1 is not up, nothing on this host works anyway,
    # and netconsole.nix's witness must be armed before the heavy stage-2
    # services start.
    linkConfig.RequiredForOnline = "routable";
  };

  systemd.network.networks."10-lan1g" = {
    matchConfig.PermanentMACAddress = "3c:ec:ef:7f:28:aa";

    # Managed and up, but no IPv4 — netplan's `dhcp4: false`. IPv6 link-local
    # only, which is all it carries today.
    networkConfig = {
      DHCP = "no";
      LinkLocalAddressing = "ipv6";
    };

    # netplan's `optional: true`. Without this, systemd-networkd-wait-online
    # blocks the boot for its full timeout whenever this port is unplugged.
    linkConfig.RequiredForOnline = "no";
  };

  # Not configured, on purpose: the BMC's USB RNDIS NIC `enxb03af2b6059f`
  # (b0:3a:f2:b6:05:9f). It is unmanaged on Ubuntu (`Network File: n/a`) and
  # stays unmanaged here — with `networking.useDHCP = false` no catch-all
  # `.network` exists to claim it. Its `ifname` comes from systemd's own
  # 73-usb-net-by-mac.link, which ships in the package.
  #
  # Also not here: the libvirt NAT bridges virbr0/virbr2 (libvirt creates and
  # rules them itself), the podman bridges cni-podman2/3, and flannel's
  # cni0/flannel.1 — all owned by their daemons, none by networkd.

  ############################################################################
  # 5. DNS
  ############################################################################

  # gir's /etc/resolv.conf is a symlink to
  # ../run/systemd/resolve/stub-resolv.conf, so resolved runs in STUB mode:
  # 127.0.0.53 in resolv.conf, and the real upstream (192.168.42.1, search
  # domain home.arpa) learned per-link from the DHCP lease.
  #
  # `services.resolved.enable` defaults to FALSE in nixpkgs, so this has to be
  # explicit; the module then symlinks /etc/resolv.conf to the same stub file.
  # Its other defaults already match Ubuntu's stock resolved.conf (which is
  # entirely commented out): DNSSEC off, DNSOverTLS off, LLMNR on, no static
  # DNS= or Domains=. Nothing else is set — the lease is the source of truth,
  # here as on Ubuntu.
  services.resolved.enable = true;

  ############################################################################
  # 6. /etc/hosts — byte parity with Ubuntu's
  ############################################################################

  # Ubuntu's /etc/hosts is, in full:
  #   127.0.0.1       localhost
  #   127.0.1.1       brainframe
  #   ::1             localhost ip6-localhost ip6-loopback
  #   ff02::1         ip6-allnodes
  #   ff02::2         ip6-allrouters
  #
  # `127.0.0.1 localhost` and `::1 localhost` are emitted by nixpkgs itself
  # (the latter because `networking.enableIPv6` is left at its default true), so
  # only the remainder is listed here.
  #
  # `brainframe` is a leftover from this machine's former hostname. It is
  # reproduced rather than cleaned up: it costs nothing, and cutover night is
  # not when to discover that something still says "brainframe".
  networking.hosts = {
    "127.0.1.1" = [ "brainframe" ];
    "::1" = [
      "ip6-localhost"
      "ip6-loopback"
    ];
    "ff02::1" = [ "ip6-allnodes" ];
    "ff02::2" = [ "ip6-allrouters" ];

    # DIFFERS FROM NIXOS DEFAULT, deliberately. nixos/modules/config/networking.nix
    # adds `127.0.0.2 gir` so that `hostname -f` resolves locally. Ubuntu has no
    # such entry: `gir` resolves through DNS (search domain home.arpa) to
    # 192.168.42.8. Keeping the NixOS default would silently change what the
    # name `gir` means to every local process — Samba, postfix
    # (`mydestination = gir.maski.org, gir.motherbrain.local, ...`), any script
    # that connects to `gir` — from the LAN address to a loopback one. The
    # migration rule is parity, so it is removed.
    #
    # If something on NixOS turns out to need `hostname -f`, the fix is to add
    # this back deliberately, not to leave it in by accident.
    "127.0.0.2" = lib.mkForce [ ];
  };

  ############################################################################
  # 7. Networking sysctls — parity, stated explicitly
  ############################################################################

  boot.kernel.sysctl = {
    # Loose reverse-path filtering, Ubuntu's value from
    # /usr/lib/sysctl.d/50-default.conf. Strict (1) breaks asymmetric paths;
    # k3s/flannel and the libvirt NAT bridges both rely on this being 2 or 0.
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;

    # IPv6 off the Ubuntu way. Evidence this is really in effect today: `lo` has
    # NO ::1 address in `ip -d addr show`, only 127.0.0.1/8.
    #
    # This is not a contradiction of the fe80:: addresses on eno1 and lan1g:
    # systemd-networkd writes `net.ipv6.conf.<iface>.disable_ipv6 = 0` for links
    # it manages with LinkLocalAddressing=ipv6, so the two managed NICs get
    # link-local addresses back and everything else — lo included — stays v6-less.
    # That is precisely the state gir is in now.
    #
    # Note this is done with sysctls and NOT with `networking.enableIPv6 = false`,
    # which would also add `ipv6.disable=1` to the kernel command line and take
    # the link-local addresses with it. See the header note for ssh.nix.
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
    "net.ipv6.conf.lo.disable_ipv6" = 1;
  };

  # Not set here, on purpose: ip_forward, route_localnet and the
  # bridge-nf-call-* sysctls. k3s sets all of those itself at runtime, and
  # ticket 03 owns the br_netfilter / overlay module loads. Pinning them here
  # would fight k3s for ownership.
}

############################################################################
# FIRST-BOOT TESTS — ticket 14, for Window B
#
# Run these in order, right after the first NixOS boot. There is no WAN gate:
# misfit's port forwards stay open throughout, and gir is unreachable while it
# is down anyway. The BMC console is the way back if 1 or 2 fail.
#
# 1. NAMING
#      ip -br link
#        -> eno1  = 3c:ec:ef:7f:2a:96
#           lan1g = 3c:ec:ef:7f:28:aa
#           and NO ethN anywhere.
#      networkctl status eno1 lan1g
#        -> Link File names 10-eno1.link / 10-lan1g.link.
#      The initrd carries both .link files: list the initrd from
#      /boot/EFI/nixos/ (lsinitrd, or cpio) and look for
#      etc/systemd/network/10-eno1.link.
#
# 2. ADDRESSING
#      networkctl status eno1      -> 192.168.42.8 (DHCP4 via 192.168.42.1)
#      ip -4 addr show eno1        -> 192.168.69.1/24 ... deprecated
#      ip route                    -> default via 192.168.42.1 (metric 100)
#      On misfit, the Kea log shows the SAME cid for 3c:ec:ef:7f:2a:96 as today:
#        ff:b6:22:0f:eb:00:02:00:00:ab:11:28:0a:73:26:40:d1:3f:64
#      Worth proving EARLIER, in the rehearsal VM, that networkd emits that cid
#      from the pinned IAID/DUID above — not on cutover night.
#
# 3. BACKEND
#      iptables -V                 -> reports "(nf_tables)"
#      iptables-legacy-save        -> empty
#      iptables -S | grep -c KUBE- -> non-zero
#      iptables -S | grep -c LIBVIRT_ -> non-zero once libvirtd is up
#
# 4. CLUSTER NETWORKING
#      kubectl get node -o wide    -> Ready, InternalIP 192.168.42.8
#      From a pod: 10.43.0.1:443 (apiserver) and 192.168.69.1:5432 (postgres)
#        both answer.
#      kubectl top node            -> works (metrics-server -> kubelet 10250)
#      openssl s_client -connect 127.0.0.1:6443
#        -> SANs still include 192.168.42.8 and 192.168.69.1
#      A servicelb port (traefik 443) answers from the LAN.
#
# 5. SSHD AND FAIL2BAN  (ssh.nix owns these; listed here so the order is kept)
#      sshd -T | grep -E 'passwordauth|kbdinteractive|gatewayports|x11forwarding'
#        -> matches Ubuntu
#      fail2ban-client status sshd -> jail active
#      fail2ban-client get sshd ignoreip / maxretry / bantime
#        -> 127.0.0.1/8 ::1 192.168.42.0/24 ; 5 ; 600
#      Once the first internet ban lands: iptables -S f2b-sshd shows the REJECT.
#
# 6. SAMBA
#      ss -tln  -> smbd on 192.168.42.8:139 and :445 ONLY
#      A LAN Mac mounts one ordinary share and sees a Time Machine share.
#
# 7. THE DROPS ARE REAL
#      Nothing listens on 2049 or 111 (NFS export /stuff/srv/goodstuff and
#      rpcbind are gone — this reverses ticket 05's "keep"; the data under
#      /stuff/srv/goodstuff is untouched), and nothing listens on UDP 6666
#      (rsyslog's squirrel netconsole RECEIVER is gone; gir's own netconsole
#      SENDER in netconsole.nix is unaffected and must be up from boot one).
#      squirrel (192.168.42.89) will keep sending into a closed port, which is
#      harmless. Repoint or disable it on squirrel whenever convenient.
############################################################################
