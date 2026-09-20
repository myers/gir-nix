# gir: host hygiene (ticket 24, module 13) — nix-ld, time, locale, nix settings
# and the small set of tools the host actually uses.
#
# The one load-bearing item here is `programs.nix-ld`. Ticket 11 §6 requires it:
# `/home/myers` is carried over from Ubuntu unchanged and is full of
# Ubuntu-linked ELF binaries that must keep working on NixOS —
# `~/.local/bin/{claude,fj,mise,zed}`, everything in `~/.cargo/bin`, and the uv
# venv behind `~/p/coding-hive/bin/inv`, which `coding-hive-net.service` runs.
# Claude Code itself runs from that home, so nix-ld failing is not a cosmetic
# problem.
#
# Everything else in this file is host-wide plumbing that no other ticket-24
# module owns.
{ pkgs, ... }:

{
  ############################################################################
  ## nix-ld (ticket 11 §6)
  ##
  ## `programs.nix-ld.libraries` is a list option, so what is listed here is
  ## ADDED to the module's own default set (zlib, zstd, stdenv.cc.cc, curl,
  ## openssl, attr, libssh, bzip2, libxml2, acl, libsodium, util-linux, xz,
  ## systemd). Verified against the live binaries on 2026-09-19:
  ##   claude 2.1.278  -> libc, libm, librt, libdl, libpthread  (glibc only)
  ##   fj, mise        -> + libgcc_s, libz, libssl, libcrypto
  ##   ~/.cargo/bin/*  -> + libgcc_s, libz   (rg, zellij, sea-orm-cli, cross…)
  ##   uv cpython 3.13 -> portable build; the interpreter itself needs only
  ##                      glibc, but its extension modules reach for the set
  ##                      below.
  ## The defaults already cover every direct dependency observed; the additions
  ## are the usual second-order set for a CPython/uv venv and for Ubuntu
  ## binaries built against glibc's removed libcrypt.
  ############################################################################

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    libxcrypt # libcrypt.so.1 — split out of glibc, still linked by Ubuntu builds
    libffi # ctypes
    ncurses # readline/curses extension modules, TUIs in ~/.cargo/bin
    readline
    sqlite
    expat # pyexpat
    icu
    krb5 # gssapi, used by several Rust and Python clients
  ];

  ############################################################################
  ## Time and locale — parity with the Ubuntu host
  ##
  ## `timedatectl` on 2026-09-19: Timezone=America/New_York, LocalRTC=no.
  ## /etc/default/locale: LANG=en_US.UTF-8.
  ############################################################################

  time.timeZone = "America/New_York";

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.supportedLocales = [
    "en_US.UTF-8/UTF-8"
    "C.UTF-8/UTF-8"
  ];

  console.keyMap = "us";

  ############################################################################
  ## Nix daemon settings
  ##
  ## Not set on purpose: `nix.gc`. gir is mid-migration and both OSes share the
  ## same `rpool/nixos/nix` store (ticket 12); automatic collection during the
  ## soak could delete a closure the other OS's profile still needs. Collect by
  ## hand, after the soak.
  ##
  ## Also not set: `nix.nrBuildUsers`. The default (32) already matches the
  ## nixbld1-32 accounts Ubuntu's Nix install created at uid 30001-30032.
  ############################################################################

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # myers builds and deploys this flake from his own account.
    trusted-users = [
      "root"
      "myers"
    ];
    # Hard-links identical store paths. Cheap on ZFS and the store is shared
    # between the two OSes, so the duplication is real.
    auto-optimise-store = true;
  };

  # plex (ticket 05, overlay-pinned in plex.nix) is unfree, and so is the
  # Secure Boot OVMF path libvirt.nix needs. Kept here rather than in either of
  # those modules so there is one place to look. Setting it again elsewhere to
  # the same value is harmless; setting it to a different value is an error.
  nixpkgs.config.allowUnfree = true;

  ############################################################################
  ## System packages
  ##
  ## Deliberately small: the interactive and diagnostic tools that are actually
  ## installed and used on the Ubuntu host (checked against `apt-mark
  ## showmanual`, 2026-09-19). Anything a ticket-24 service module pulls in is
  ## NOT repeated here — smartmontools, ipmitool, mdadm, sysstat, samba,
  ## postgresql clients, the ZFS userland and kubectl all arrive with their own
  ## module.
  ############################################################################

  environment.systemPackages = with pkgs; [
    # editing and version control
    git
    vim
    # shells and multiplexers (zsh itself comes from programs.zsh in users.nix)
    screen
    # process and I/O inspection
    htop
    btop
    bottom
    lsof
    ncdu
    # text and data wrangling
    jq
    ripgrep
    file
    sqlite
    gnupg
    python3
    # transfer
    rsync
    curl
    wget
    # archives
    unzip
    p7zip
    # hardware and network diagnosis — this host is debugged from the console
    # and over BMC-KVM during crash soaks
    pciutils
    usbutils
    nvme-cli
    lm_sensors
    ethtool
    # boot.loader.efi.canTouchEfiVariables = false, so NixOS never writes NVRAM and
    # nothing pulls efibootmgr in -- but that setting is exactly why this host edits
    # its boot entries by hand (ticket 06 put NixOS on ESP #2 without reordering
    # anything). Without this, `sudo efibootmgr` is "command not found" at the moment
    # you most need it, which is what happened promoting the BootOrder on 2026-09-20.
    efibootmgr
    # the cluster is k3s, but helm is not part of services.k3s
    kubernetes-helm
  ];

  ############################################################################
  ## /bin/bash for the shared Ubuntu home
  ##
  ## NixOS ships only /bin/sh and /usr/bin/env. /home/myers comes across from
  ## Ubuntu unchanged and is full of scripts that start `#!/bin/bash`, and the
  ## breakage is not limited to shebangs: pyinvoke, which drives the coding-hive
  ## VM, runs every `c.run()` subprocess through a shell and defaults that shell
  ## to /bin/bash. On the first NixOS boot (2026-09-20 12:52) that surfaced as
  ## `FileNotFoundError: [Errno 2] No such file or directory: '/bin/bash'`
  ## inside tasks.py, after the binstub itself had already been fixed.
  ##
  ## This is the same bargain `programs.nix-ld` above already makes: the home is
  ## Ubuntu's, it must keep working, and paying for that centrally beats
  ## discovering each caller one failure at a time. `L+` replaces whatever is
  ## there, so the link is reasserted on every activation.
  ##
  ## bashInteractive, not bash: /bin/sh already points into bashInteractive, so
  ## reusing it keeps one bash in the system closure instead of two.
  ############################################################################
  systemd.tmpfiles.rules = [
    "L+ /bin/bash - - - - ${pkgs.bashInteractive}/bin/bash"
  ];

}
