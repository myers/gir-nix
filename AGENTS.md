# AGENTS.md

Working notes for agents in the flake for host **gir**. Read `README.md` first
for the layout, how to build and deploy, and the checks.

## You build; the user deploys

- Prove every change with `nixos-rebuild build --flake .#gir`. The user runs
  `switch`, reboots, and deliberate crashes (`sysrq-c`). Hand them the exact
  command, plus what to check afterwards.
- A build includes uncommitted edits to tracked files. Run `git status` before
  handing over a `switch`, so nobody else's work-in-progress gets deployed with
  yours.
- To prove a pure refactor, compare the built system's store path before and
  after. An identical `/nix/store/…-nixos-system-gir-…` path means nothing changed.

## Comments carry provenance

Every module opens with a header naming its ticket and why it exists. Inline
comments record dates, the live values read off the host, and the incident behind
a choice. Write new code the same way; a gir-nix comment is often the only place
a decision is recorded.

- `ticket NN` means `~/p/gir/.scratch/nixos-migration/issues/NN-*.md`.
- Incident analyses live in `~/p/gir/2026-MM-DD-*.md`. `~/p/gir/AGENTS.md` covers
  that host-management project: tickets, incidents, and gtx.

## Couplings to know before editing

- **The crash kernel boots this closure's stage 2.** Anything that runs in stage 2
  also runs inside a 2 GiB kdump kernel, unless `kdump.nix` masks it on the
  crash kernel's command line. For example, `systemd-sysctl` is masked because
  gir's `vm.min_free_kbytes` OOM-killed the 2026-09-27 capture. Read
  `kdump.nix`'s header before touching boot, sysctl or early services.
- **ZFS module parameters go in `boot.extraModprobeConfig`** (`sysctl.nix`). They
  are read at module load inside the initrd, so they take effect after a reboot.
  That file explains why they are not sysctls or `boot.kernelParams`.
- **k3s is pinned twice:** by the `nixpkgs-k3s-1344` input and by
  `hosts/gir/k3s-guard.nix`. Bumping nixpkgs leaves k3s alone. A k3s upgrade is a
  separate, deliberate change.
- **The rpool PNY NVMe drives are exempt from smartd self-tests**
  (`monitoring.nix`). A self-test hangs both drives until AC power is removed.
  Keep new smartd or maintenance schedules off them.

## Specs and plans

Designs live in `docs/superpowers/specs/`, implementation plans in
`docs/superpowers/plans/`. Check them before changing an area one of them covers.
