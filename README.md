# gir-nix

The NixOS configuration for **gir**, a Supermicro M12SWA-TF (Threadripper PRO
3975WX, 128 GB ECC) that runs ZFS storage, a single-node k3s cluster, and a
handful of bare-metal services (PostgreSQL, Plex, Samba, Syncthing, NUT,
Postfix). gir moved from Ubuntu to NixOS in September 2026. This flake is the
result of that migration and is now the host's source of truth.

## Layout

| Path | What it holds |
|---|---|
| `flake.nix` | Inputs (nixpkgs pinned to a 26.05 channel head, plus a second pin for k3s), the `gir` system and its VM checks |
| `hosts/gir/configuration.nix` | Boot, pools, kernel/ZFS pairing, and the list of modules |
| `hosts/gir/k3s-guard.nix` | Refuses to build a config that would upgrade, re-key or convert the live k3s cluster |
| `modules/*.nix` | One area per module: `storage`, `users`, `networking`, `ssh`, `monitoring`, `kdump`, `netconsole`, `sysctl`, `postgresql`, … Each file opens with a header saying what it owns and why |
| `modules/basic.nix` | Everyday console and diagnostic tools |
| `docs/superpowers/` | Design specs and implementation plans |

Each module header explains its choices: the live values read off the Ubuntu host,
and the tickets and incidents behind them. `ticket NN` refers to
`~/p/gir/.scratch/nixos-migration/issues/NN-*.md`. Incident write-ups live in
`~/p/gir/` as dated `2026-MM-DD-*.md` files.

## Build and deploy

```sh
nixos-rebuild build --flake ~/p/gir-nix#gir          # build only, no changes to the host
sudo nixos-rebuild switch --flake ~/p/gir-nix#gir    # activate
```

A flake only sees files git tracks, so `git add` a new file before building. Tracked
files are built as they are in the working tree, including uncommitted edits.

Rollback: pick the previous generation in the boot menu, or run
`sudo nixos-rebuild switch --rollback`.

Changes to the kernel, the ZFS module, or anything read only at boot (initrd
contents, `boot.extraModprobeConfig`) take effect after a reboot. kdump re-arms
itself on `switch` (`kdump-load.service`), so crash-kernel changes do not need one.

## Checks

```sh
nix build .#checks.x86_64-linux.<name> -L    # one check
nix flake check                              # all of them; boots several VMs
```

The checks are NixOS VM tests: k3s single-node and configuration tests that gate k3s
changes. They need `/dev/kvm` and take minutes each.

## Crash capture

gir panics on hung tasks (`sysctl.nix`). It streams its kernel log to misfit over
netconsole (`netconsole.nix`), and kdump saves a vmcore to `/var/crash/<stamp>/`
before rebooting (`kdump.nix`). The crash kernel boots this same system closure.
Read `kdump.nix`'s header before changing boot, sysctl or stage-2 services.
