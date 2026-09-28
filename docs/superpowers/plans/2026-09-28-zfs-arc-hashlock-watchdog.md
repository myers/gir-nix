# ZFS ARC Hash-Lock Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A patched zfs 2.3.9 kernel module for gir that names any task holding an ARC buf
hash lock for ≥30 s (pid, state, kernel stack) on the console/netconsole, plus VM tests that
reproduce the stuck-lock condition deterministically (tier 1) and naturally (tier 2).

**Architecture:** Two small patches against OpenZFS `zfs-2.3.9`, developed as commits in a
local clone and exported with `git format-patch` into `gir-nix/patches/zfs/`. A NixOS module
(`gir.zfsDebug.enable`) swaps `boot.zfs.modulePackage` for the patched build. The watchdog is
a `zthr` in `arc.c` that samples the 2048 hash-lock owners; the stack printing lives in SPL
(already GPL) because `sched_show_task()` is `EXPORT_SYMBOL_GPL`. Tests are nixosTests on
kernel 6.12.109, built by the flake.

**Tech Stack:** C (Linux kernel module, OpenZFS 2.3.9 / SPL), Nix flakes, NixOS test driver
(Python testScript), fio, stress-ng.

**Spec:** `docs/superpowers/specs/2026-09-28-zfs-arc-hashlock-watchdog-design.md`
(background: `~/p/gir/2026-09-27-gir-arc-deadlock.md`, `~/p/gir/gir-arc-lockup-session-outcome-20260918.md`).

## Global Constraints

- Patch base: OpenZFS tag `zfs-2.3.9` exactly (what `pkgs.zfs_2_3` builds at nixpkgs `c3eea5b`).
- Kernel: `pkgs.linuxPackages_6_12` (6.12.109) for gir and for every test VM.
- Module parameters and defaults: `zfs_arc_hashlock_wd_threshold_s` = 30 (0 disables),
  `zfs_arc_hashlock_wd_interval_ms` = 10000, `zfs_arc_debug_hold_ms` = 0. All `ZMOD_RW`.
- Report line format (tests grep it): `ZFS: arc hash lock <i> held <n>s by pid <pid> [<comm>] state=<c> waiters=<0|1>`,
  then the `sched_show_task()` stack. Summary: `ZFS: arc hash locks held=<h> stuck=<s> (>=<t>s)`
  (emitted via `cmn_err(CE_WARN)`, so the kernel log shows it prefixed `WARNING: `; tests match
  it as a substring).
- At most 16 holder stacks per scan; a holder is re-reported every 60 s while still stuck.
- `zfs.ko` stays CDDL. GPL-only kernel calls live only in `spl.ko` (`spl_mutex_report_owner`).
- Watchdog and debug hook compile only under `#ifdef _KERNEL`.
- Test VMs set `boot.consoleLogLevel = 7` (gir runs `kernel.printk = 7 4 1 7`).
- The on-disk format and the zfs userland are untouched; only the kernel module is rebuilt.
- Flakes only see git-tracked files: `git add` every new file before `nix build`.
- VM runs on gir: quiet hours; before tier 2, pause CI (no drawbar/Woodpecker builds running).
- Git: add specific files only, never `git add -A` / `git add .`.
- Commit messages end with `Claude-Session: https://claude.ai/code/session_01JnPeqcF2XjqzHsvchBD3Hy`.

## Review Focus

1. **Holder releases the lock or exits between the scan read and the report** — expected: no
   report, no use-after-free. Guarded by the RCU re-check in `spl_mutex_report_owner`; not
   testable deterministically, so the Task 3 reviewer must read that function line by line.
2. **`threshold_s` set to 0 at runtime while a lock is stuck** — expected: scanning stops and
   nothing is printed. Test added in Task 4.
3. **`interval_ms` set to 0 or tiny** — expected: clamped to 1000 ms, no busy loop, reports
   still appear. Test added in Task 4.
4. **Many stuck holders at once (09-18 had 25; gir has seen 1000+ D tasks)** — expected: at
   most 16 stacks per scan plus a summary with the true count. Test added in Task 4.
5. **Pool export and `rmmod zfs` while the watchdog runs** — expected: clean unload, no oops.
   Test added in Task 4.

---

## File Structure

| path | responsibility |
|---|---|
| `~/p/zfs-gir/` (new clone, branch `gir-hashlock-wd`) | where the C changes are written and committed; source of the patches |
| `patches/zfs/0001-arc-debug-hold.patch` | `zfs_arc_debug_hold_ms` test hook in `arc_read` |
| `patches/zfs/0002-arc-hashlock-watchdog.patch` | SPL `spl_mutex_report_owner()` + `arc_hl_wd` zthr + its two parameters |
| `patches/zfs/.gitkeep` | keeps the directory tracked before the first patch exists |
| `pkgs/zfs-kmod-debug.nix` | function: a zfs kernel-module package → same package with `patches/zfs/*.patch` appended |
| `modules/zfs-debug.nix` | option `gir.zfsDebug.enable`; sets `boot.zfs.modulePackage` |
| `tests/zfs-vm-common.nix` | NixOS module shared by both test VMs (kernel, zfs, debug module, loglevel, disks, tools) |
| `tests/zfs-arc-hashlock-tier1.nix` | deterministic nixosTest (in `nix flake check`) |
| `tests/zfs-arc-hashlock-tier2.nix` | natural-stress nixosTest (flake `packages`, run by hand) |
| `flake.nix` | exposes `packages.zfs-kmod-debug`, `packages.zfs-arc-hashlock-tier2`, `checks.zfs-arc-hashlock-tier1` |
| `hosts/gir/configuration.nix` | imports `modules/zfs-debug.nix`, enables it (Task 6) |

---

### Task 1: Nix plumbing and the failing tier 1 test

**Files:**
- Create: `patches/zfs/.gitkeep`, `pkgs/zfs-kmod-debug.nix`, `modules/zfs-debug.nix`,
  `tests/zfs-vm-common.nix`, `tests/zfs-arc-hashlock-tier1.nix`
- Modify: `flake.nix` (the `outputs` attrset)

**Interfaces:**
- Produces: `pkgs/zfs-kmod-debug.nix` = `{ lib, zfsKernelModule }: <derivation>`;
  NixOS option `gir.zfsDebug.enable` (bool); flake outputs
  `packages.x86_64-linux.zfs-kmod-debug` and `checks.x86_64-linux.zfs-arc-hashlock-tier1`;
  `tests/zfs-vm-common.nix` (NixOS module; disks default `[ 4096 4096 ]` via `mkDefault`).

- [ ] **Step 1: Create the patch directory placeholder**

```bash
cd ~/p/gir-nix && mkdir -p patches/zfs pkgs tests && touch patches/zfs/.gitkeep
```

- [ ] **Step 2: Write `pkgs/zfs-kmod-debug.nix`**

```nix
# The zfs kernel module with gir's local debug patches applied (every
# patches/zfs/*.patch, in name order). Spec:
# docs/superpowers/specs/2026-09-28-zfs-arc-hashlock-watchdog-design.md
#
# Only the kernel module is rebuilt. Userland and the on-disk format are the
# stock package's, so the version assertion in nixos/modules/tasks/filesystems/
# zfs.nix (modulePackage.version == package.version) still holds.
{ lib, zfsKernelModule }:

let
  dir = ../patches/zfs;
  names = lib.sort lib.lessThan
    (lib.filter (lib.hasSuffix ".patch") (lib.attrNames (builtins.readDir dir)));
in
zfsKernelModule.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ map (n: dir + "/${n}") names;
})
```

- [ ] **Step 3: Write `modules/zfs-debug.nix`**

```nix
# gir's patched zfs kernel module: the ARC hash-lock watchdog.
#
# The 09-18 vmcore showed ARC hash-lock holders stuck in direct reclaim inside
# arc_read, invisible to khungtaskd. This build prints any holder of an ARC
# hash lock held >= zfs_arc_hashlock_wd_threshold_s (default 30 s) with its
# stack, so the next hang names it on netconsole even if kdump fails.
# Spec: docs/superpowers/specs/2026-09-28-zfs-arc-hashlock-watchdog-design.md
#
# Rollback: gir.zfsDebug.enable = false, rebuild, reboot.
# Runtime kill switch: echo 0 > /sys/module/zfs/parameters/zfs_arc_hashlock_wd_threshold_s
{ config, lib, ... }:

let
  cfg = config.gir.zfsDebug;
in
{
  options.gir.zfsDebug.enable =
    lib.mkEnableOption "the patched zfs kernel module with the ARC hash-lock watchdog";

  config = lib.mkIf cfg.enable {
    boot.zfs.modulePackage = import ../pkgs/zfs-kmod-debug.nix {
      inherit lib;
      zfsKernelModule =
        config.boot.kernelPackages.${config.boot.zfs.package.kernelModuleAttribute};
    };
  };
}
```

- [ ] **Step 4: Write `tests/zfs-vm-common.nix`**

```nix
# Shared by the zfs-arc-hashlock nixosTests: gir's kernel and zfs, with the
# debug module enabled. /dev/vda is the VM root; the pool uses /dev/vdb, /dev/vdc.
{ lib, pkgs, ... }:
{
  imports = [ ../modules/zfs-debug.nix ];

  gir.zfsDebug.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_6_12;
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.package = pkgs.zfs_2_3;
  # Watchdog lines are KERN_WARNING (4); gir runs kernel.printk = 7 4 1 7.
  boot.consoleLogLevel = 7;
  networking.hostId = "8425e349";

  virtualisation.emptyDiskImages = lib.mkDefault [ 4096 4096 ];
  environment.systemPackages = [ pkgs.fio pkgs.stress-ng ];
}
```

- [ ] **Step 5: Write `tests/zfs-arc-hashlock-tier1.nix`**

```nix
# Tier 1: force an ARC hash lock to be held (zfs_arc_debug_hold_ms) and check
# that the watchdog names the holder. Deterministic, ~3 min.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "zfs-arc-hashlock-tier1";

  nodes.machine = {
    imports = [ ./zfs-vm-common.nix ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
  };

  testScript = ''
    P = "/sys/module/zfs/parameters/"

    def setp(name, value):
        machine.succeed(f"echo {value} > {P}{name}")

    def bg(cmd):
        return machine.succeed(f"{cmd} >/dev/null 2>&1 & echo $!").strip()

    machine.wait_for_unit("multi-user.target")
    machine.succeed("modprobe zfs")
    machine.succeed("zpool create -f -O compression=off -O recordsize=128k tank /dev/vdb /dev/vdc")
    # f: 8 records (one L1 indirect). g0..g23: one record each, for the flood test.
    machine.succeed("dd if=/dev/urandom of=/tank/f bs=128k count=8")
    machine.succeed("for i in $(seq 0 23); do dd if=/dev/urandom of=/tank/g$i bs=128k count=1 2>/dev/null; done")
    machine.succeed("sync && zpool export tank && zpool import -d /dev tank")

    setp("zfs_prefetch_disable", 1)
    # Warm the metadata of f (dnode, L1) and record 0, so reading record 7
    # misses on exactly one block: the L0 we hold the lock for.
    machine.succeed("dd if=/tank/f of=/dev/null bs=128k count=1")

    with subtest("holder is reported with pid, state, waiters and arc_read stack"):
        setp("zfs_arc_hashlock_wd_threshold_s", 10)
        setp("zfs_arc_hashlock_wd_interval_ms", 2000)
        setp("zfs_arc_debug_hold_ms", 60000)
        machine.succeed("dmesg -C")
        holder = bg("dd if=/tank/f of=/dev/null bs=128k skip=7 count=1")
        machine.sleep(2)
        waiter = bg("dd if=/tank/f of=/dev/null bs=128k skip=7 count=1")
        machine.sleep(5)
        machine.succeed(f"kill -0 {holder} && kill -0 {waiter}")
        machine.wait_until_succeeds(
            f"dmesg | grep -E 'ZFS: arc hash lock [0-9]+ held [0-9]+s by pid {holder} \\[dd\\] state=D waiters=1'",
            timeout=30)
        machine.succeed(f"dmesg | grep -A60 'by pid {holder} ' | grep -q arc_read")
        machine.succeed("dmesg | grep -E 'ZFS: arc hash locks held=[0-9]+ stuck=[1-9][0-9]* \\(>=10s\\)'")

    with subtest("lock released: readers finish and reports stop"):
        setp("zfs_arc_debug_hold_ms", 0)
        machine.wait_until_fails(f"kill -0 {holder}", timeout=90)
        machine.wait_until_fails(f"kill -0 {waiter}", timeout=30)
        machine.sleep(3)
        machine.succeed("dmesg -C")
        machine.sleep(10)
        machine.fail("dmesg | grep 'ZFS: arc hash lock'")
  '';
}
```

- [ ] **Step 6: Wire the flake** — in `flake.nix`, inside `outputs` next to `checks`, add a
  `packages` attrset and extend `checks`:

```nix
      # docs/superpowers/specs/2026-09-28-zfs-arc-hashlock-watchdog-design.md
      packages.${system} = {
        zfs-kmod-debug = import ./pkgs/zfs-kmod-debug.nix {
          inherit (testPkgs) lib;
          zfsKernelModule = testPkgs.linuxPackages_6_12.zfs_2_3;
        };
      };
```

and inside the existing `checks.${system} = { ... };`:

```nix
        zfs-arc-hashlock-tier1 = import ./tests/zfs-arc-hashlock-tier1.nix { pkgs = testPkgs; };
```

- [ ] **Step 7: Track the files and check that the stock module still builds**

```bash
cd ~/p/gir-nix
git add patches/zfs/.gitkeep pkgs/zfs-kmod-debug.nix modules/zfs-debug.nix \
  tests/zfs-vm-common.nix tests/zfs-arc-hashlock-tier1.nix flake.nix
nix build .#zfs-kmod-debug -L 2>&1 | tail -5
```
Expected: builds (no patches yet), prints nothing alarming, `result` → `zfs-kernel-2.3.9-6.12.109`.

- [ ] **Step 8: Run tier 1 and watch it fail**

```bash
nix build .#checks.x86_64-linux.zfs-arc-hashlock-tier1 -L 2>&1 | tail -20
```
Expected: FAIL in subtest "holder is reported…" at
`echo 60000 > /sys/module/zfs/parameters/zfs_arc_debug_hold_ms` (the parameter does not exist:
`Permission denied` or `No such file or directory`). Any earlier failure (pool create, import)
is a test bug: fix it before continuing.

- [ ] **Step 9: Commit**

```bash
git commit -m "zfs-debug: nix plumbing for patched zfs kmod + failing tier1 test

Claude-Session: https://claude.ai/code/session_01JnPeqcF2XjqzHsvchBD3Hy"
```

---

### Task 2: `zfs_arc_debug_hold_ms` test hook (patch 0001)

**Files:**
- Create: clone `~/p/zfs-gir`; `patches/zfs/0001-arc-debug-hold.patch` (generated)
- Modify (in the clone): `module/zfs/arc.c` — the parameter block near
  `zfs_arc_eviction_pct` (line ~363), `arc_read` just before `arc_hdr_alloc_abd(hdr, alloc_flags);`
  (line ~6196), the `ZFS_MODULE_PARAM` list at the end (line ~11293)

**Interfaces:**
- Consumes: Task 1's patch pickup (`patches/zfs/*.patch`) and tier 1 test.
- Produces: module parameter `zfs_arc_debug_hold_ms` (uint, RW, default 0). When non-zero,
  a thread in `arc_read` sleeps that many ms **holding the buf hash lock** before allocating
  the ABD. Task 3's watchdog and all tests rely on it.

- [ ] **Step 1: Clone the exact base and branch**

```bash
git clone --branch zfs-2.3.9 --depth 1 https://github.com/openzfs/zfs ~/p/zfs-gir
cd ~/p/zfs-gir && git switch -c gir-hashlock-wd
grep -n "arc_hdr_alloc_abd(hdr, alloc_flags);" module/zfs/arc.c
```
Expected: one hit at line 6196. If the line differs, the tag is wrong: stop.

- [ ] **Step 2: Add the parameter variable** — after the line
  `static uint_t zfs_arc_eviction_pct = 200;` insert:

```c
/*
 * gir debug patch: test hook for the ARC hash-lock watchdog. When non-zero,
 * arc_read() sleeps this many milliseconds while holding the buf hash lock,
 * just before allocating the ABD -- the spot where the 2026-09-18 holders sat
 * in direct reclaim. Test-only; never set it on a production host.
 */
static uint_t zfs_arc_debug_hold_ms = 0;
```

- [ ] **Step 3: Add the hook in `arc_read`** — replace

```c
		arc_hdr_set_flags(hdr, ARC_FLAG_IO_IN_PROGRESS);
		arc_hdr_alloc_abd(hdr, alloc_flags);
```
with
```c
		arc_hdr_set_flags(hdr, ARC_FLAG_IO_IN_PROGRESS);
#ifdef _KERNEL
		if (zfs_arc_debug_hold_ms != 0 && hash_lock != NULL)
			delay(MSEC_TO_TICK(zfs_arc_debug_hold_ms));
#endif
		arc_hdr_alloc_abd(hdr, alloc_flags);
```

- [ ] **Step 4: Register the parameter** — directly after the `eviction_pct` `ZFS_MODULE_PARAM`
  (the one ending `"When full, ARC allocation waits for eviction of this % of alloc size");`) add:

```c
ZFS_MODULE_PARAM(zfs_arc, zfs_arc_, debug_hold_ms, UINT, ZMOD_RW,
	"gir debug: arc_read sleeps this many ms holding the hash lock (test only)");
```

- [ ] **Step 5: Commit in the clone and export the patch**

```bash
cd ~/p/zfs-gir
git add module/zfs/arc.c
git commit -m "arc: zfs_arc_debug_hold_ms test hook (gir debug)"
git format-patch --zero-commit -1 --stdout > ~/p/gir-nix/patches/zfs/0001-arc-debug-hold.patch
cd ~/p/gir-nix && git add patches/zfs/0001-arc-debug-hold.patch
nix build .#zfs-kmod-debug -L 2>&1 | tail -5
```
Expected: module builds; the log shows `applying patch .../0001-arc-debug-hold.patch`.

- [ ] **Step 6: Run tier 1: it must now get past the hook and fail on the missing report**

```bash
nix build .#checks.x86_64-linux.zfs-arc-hashlock-tier1 -L 2>&1 | tail -20
```
Expected: `kill -0 {holder} && kill -0 {waiter}` succeeds (both readers blocked), then FAIL at
`wait_until_succeeds(... 'ZFS: arc hash lock ...')` after its 30 s timeout. If it fails
earlier because the readers already exited, the hold did not engage: check that
`zfs_prefetch_disable` took effect and that record 7 was not warmed.

- [ ] **Step 7: Commit**

```bash
git commit -m "zfs-debug: patch 0001, arc_read debug hold hook

Claude-Session: https://claude.ai/code/session_01JnPeqcF2XjqzHsvchBD3Hy"
```

---

### Task 3: The watchdog (patch 0002)

**Files:**
- Modify (in `~/p/zfs-gir`): `include/os/linux/spl/sys/mutex.h` (declaration),
  `module/os/linux/spl/spl-thread.c` (helper), `module/zfs/arc.c` (params, zthr, init/fini)
- Create: `patches/zfs/0002-arc-hashlock-watchdog.patch` (generated)

**Interfaces:**
- Consumes: `zfs_arc_debug_hold_ms` (Task 2) via the tier 1 test.
- Produces:
  `boolean_t spl_mutex_report_owner(kmutex_t *mp, kthread_t *owner, const char *what, uint64_t held_s);`
  exported from `spl.ko`; module parameters `zfs_arc_hashlock_wd_threshold_s` (uint, RW,
  default 30) and `zfs_arc_hashlock_wd_interval_ms` (uint, RW, default 10000, clamped ≥1000);
  kernel log lines in the Global Constraints format.

- [ ] **Step 1: Declare the SPL helper** — in `include/os/linux/spl/sys/mutex.h`, after the
  `#define MUTEX_NOT_HELD(mp)` line, add:

```c
/*
 * gir debug patch: if mp is still owned by `owner`, print one line naming the
 * owner (pid, comm, state, waiters) followed by its kernel stack, and return
 * B_TRUE; otherwise print nothing and return B_FALSE. Lives in spl.ko because
 * sched_show_task() and put_task_struct() are EXPORT_SYMBOL_GPL.
 */
extern boolean_t spl_mutex_report_owner(kmutex_t *mp, kthread_t *owner,
    const char *what, uint64_t held_s);
```

- [ ] **Step 2: Implement it** — in `module/os/linux/spl/spl-thread.c` add the includes after
  `#include <sys/misc.h>`:

```c
#include <sys/mutex.h>
#include <linux/rcupdate.h>
#include <linux/sched/debug.h>
#include <linux/sched/task.h>
```
and at the end of the file:

```c
/*
 * gir debug patch, see the declaration in sys/mutex.h.
 *
 * `owner` was read without any lock, so it may already have dropped mp and
 * even exited. Task structs are freed through RCU: re-reading m_owner inside
 * an RCU read section and finding the same pointer proves the task still held
 * mp inside this section, so its task_struct is valid and can be pinned.
 */
boolean_t
spl_mutex_report_owner(kmutex_t *mp, kthread_t *owner, const char *what,
    uint64_t held_s)
{
	/* MUTEX_FLAG_WAITERS from kernel/locking/mutex.c (not in headers). */
	const unsigned long waiters_flag = 0x01UL;
	struct task_struct *t = owner;
	int waiters;

	rcu_read_lock();
	if (mutex_owner(mp) != owner) {
		rcu_read_unlock();
		return (B_FALSE);
	}
	get_task_struct(t);
	rcu_read_unlock();

	waiters = (atomic_long_read(&MUTEX(mp)->owner) & waiters_flag) ? 1 : 0;
	printk(KERN_WARNING "ZFS: %s held %llus by pid %d [%s] state=%c "
	    "waiters=%d\n", what, (unsigned long long)held_s, task_pid_nr(t),
	    t->comm, task_state_to_char(t), waiters);
	sched_show_task(t);
	put_task_struct(t);
	return (B_TRUE);
}
EXPORT_SYMBOL(spl_mutex_report_owner);
```

- [ ] **Step 3: Add the watchdog to `arc.c`** — directly after the
  `static uint_t zfs_arc_debug_hold_ms = 0;` block from Task 2, add:

```c
/*
 * gir debug patch: ARC hash-lock watchdog. On 2026-09-18 every holder of a
 * stuck ARC hash lock was runnable, looping in direct reclaim inside
 * arc_read(); khungtaskd never lists such a task. This zthr samples the owner
 * of each buf hash lock every zfs_arc_hashlock_wd_interval_ms. An owner seen
 * on every sample for >= zfs_arc_hashlock_wd_threshold_s is reported with its
 * stack (spl_mutex_report_owner). The lock sites are not instrumented: the
 * hold time is "consecutive samples with the same owner" x interval.
 * threshold 0 disables scanning.
 */
static uint_t zfs_arc_hashlock_wd_threshold_s = 30;
static uint_t zfs_arc_hashlock_wd_interval_ms = 10000;

#ifdef _KERNEL
#define	ARC_HL_WD_MIN_INTERVAL_MS	1000
#define	ARC_HL_WD_MAX_STACKS		16
#define	ARC_HL_WD_REREPORT_S		60

static zthr_t *arc_hl_wd_zthr;
static hrtime_t arc_hl_wd_next;
/* Private to the zthr: no locking. */
static kthread_t *arc_hl_wd_owner[BUF_LOCKS];
static uint32_t arc_hl_wd_streak[BUF_LOCKS];
static uint64_t arc_hl_wd_reported_at[BUF_LOCKS];	/* held_s; 0 = never */

static uint_t
arc_hl_wd_interval_ms(void)
{
	return (MAX(zfs_arc_hashlock_wd_interval_ms,
	    ARC_HL_WD_MIN_INTERVAL_MS));
}

static boolean_t
arc_hl_wd_cb_check(void *arg, zthr_t *zthr)
{
	(void) arg, (void) zthr;
	return (zfs_arc_hashlock_wd_threshold_s != 0 &&
	    gethrtime() >= arc_hl_wd_next);
}

static void
arc_hl_wd_cb(void *arg, zthr_t *zthr)
{
	(void) arg, (void) zthr;
	uint_t interval_ms = arc_hl_wd_interval_ms();
	uint64_t threshold_s = zfs_arc_hashlock_wd_threshold_s;
	uint_t held = 0, stuck = 0, stacks = 0;
	char what[32];

	arc_hl_wd_next = gethrtime() + MSEC2NSEC(interval_ms);

	for (int i = 0; i < BUF_LOCKS; i++) {
		kmutex_t *mp = &buf_hash_table.ht_locks[i];
		kthread_t *owner = mutex_owner(mp);

		if (owner == NULL) {
			arc_hl_wd_owner[i] = NULL;
			arc_hl_wd_streak[i] = 0;
			arc_hl_wd_reported_at[i] = 0;
			continue;
		}
		held++;
		if (owner == arc_hl_wd_owner[i]) {
			arc_hl_wd_streak[i]++;
		} else {
			arc_hl_wd_owner[i] = owner;
			arc_hl_wd_streak[i] = 1;
			arc_hl_wd_reported_at[i] = 0;
		}

		uint64_t held_s =
		    (uint64_t)arc_hl_wd_streak[i] * interval_ms / 1000;
		if (held_s < threshold_s)
			continue;
		stuck++;
		if (arc_hl_wd_reported_at[i] != 0 &&
		    held_s - arc_hl_wd_reported_at[i] < ARC_HL_WD_REREPORT_S)
			continue;
		if (stacks >= ARC_HL_WD_MAX_STACKS)
			continue;
		(void) snprintf(what, sizeof (what), "arc hash lock %d", i);
		if (spl_mutex_report_owner(mp, owner, what, held_s)) {
			stacks++;
			arc_hl_wd_reported_at[i] = held_s;
		}
	}

	/* cmn_err, not printk: common ZFS code goes through SPL for output. */
	if (stuck > 0) {
		cmn_err(CE_WARN, "ZFS: arc hash locks held=%u stuck=%u (>=%llus)",
		    held, stuck, (u_longlong_t)threshold_s);
	}
}
#endif /* _KERNEL */
```

- [ ] **Step 4: Start it in `arc_init()`** — after the two lines creating `arc_reap_zthr`
  (`arc_reap_zthr = zthr_create_timer("arc_reap", ... minclsyspri);`) add:

```c
#ifdef _KERNEL
	/* Wakes every second; arc_hl_wd_cb_check() applies the interval. */
	arc_hl_wd_zthr = zthr_create_timer("arc_hl_wd", arc_hl_wd_cb_check,
	    arc_hl_wd_cb, NULL, SEC2NSEC(1), minclsyspri);
#endif
```

- [ ] **Step 5: Stop it in `arc_fini()`** — after `(void) zthr_cancel(arc_reap_zthr);` add

```c
#ifdef _KERNEL
	(void) zthr_cancel(arc_hl_wd_zthr);
#endif
```
and after `zthr_destroy(arc_reap_zthr);` add
```c
#ifdef _KERNEL
	zthr_destroy(arc_hl_wd_zthr);
#endif
```
The cancel is before `buf_fini()` (which destroys the hash locks): verify with
`grep -n "zthr_cancel(arc_hl_wd_zthr)\|buf_fini();" module/zfs/arc.c` — the cancel's line
number must be smaller.

- [ ] **Step 6: Register the parameters** — after the `debug_hold_ms` `ZFS_MODULE_PARAM` add:

```c
ZFS_MODULE_PARAM(zfs_arc, zfs_arc_, hashlock_wd_threshold_s, UINT, ZMOD_RW,
	"gir debug: report ARC hash-lock holders held >= this many s (0 = off)");

ZFS_MODULE_PARAM(zfs_arc, zfs_arc_, hashlock_wd_interval_ms, UINT, ZMOD_RW,
	"gir debug: ARC hash-lock watchdog scan period in ms (min 1000)");
```

- [ ] **Step 7: Commit in the clone, export, build**

```bash
cd ~/p/zfs-gir
git add include/os/linux/spl/sys/mutex.h module/os/linux/spl/spl-thread.c module/zfs/arc.c
git commit -m "arc: hash-lock watchdog reporting long-held owners (gir debug)"
git format-patch --zero-commit -1 --stdout > ~/p/gir-nix/patches/zfs/0002-arc-hashlock-watchdog.patch
cd ~/p/gir-nix && git add patches/zfs/0002-arc-hashlock-watchdog.patch
nix build .#zfs-kmod-debug -L 2>&1 | grep -iE "applying patch|error|warning: .*arc\.c|spl-thread" | head -20
```
Expected: both patches applied; no errors; no `modpost: GPL-incompatible module zfs.ko uses GPL-only symbol`
(if that appears, a GPL-only call leaked into arc.c — move it into the SPL helper).

- [ ] **Step 8: Run tier 1 — must pass**

```bash
nix build .#checks.x86_64-linux.zfs-arc-hashlock-tier1 -L 2>&1 | tail -30
```
Expected: both subtests pass. If the report shows `state=D waiters=0`, the waiter reached
the lock after the sample: raise the `machine.sleep(5)` before the check, don't weaken the regex.

- [ ] **Step 9: Commit**

```bash
git commit -m "zfs-debug: patch 0002, ARC hash-lock watchdog

Claude-Session: https://claude.ai/code/session_01JnPeqcF2XjqzHsvchBD3Hy"
```

---

### Task 4: Review-Focus tests (kill switch, interval clamp, flood cap, unload)

**Files:**
- Modify: `tests/zfs-arc-hashlock-tier1.nix` (append subtests to `testScript`)

**Interfaces:**
- Consumes: parameters and log formats from Tasks 2–3; the `setp`/`bg` helpers, files
  `f` (records 0 and 7 already read; 1–6 cold) and `g0..g23` (cold data) from Task 1.

- [ ] **Step 1: Append the subtests** at the end of `testScript` (same indentation as the
  existing `with subtest` blocks):

```python
    with subtest("threshold 0 is a runtime kill switch"):
        setp("zfs_arc_hashlock_wd_threshold_s", 0)
        setp("zfs_arc_debug_hold_ms", 15000)
        machine.succeed("dmesg -C")
        r = bg("dd if=/tank/f of=/dev/null bs=128k skip=6 count=1")
        machine.wait_until_fails(f"kill -0 {r}", timeout=40)
        machine.fail("dmesg | grep 'ZFS: arc hash lock'")

    with subtest("interval 0 is clamped to 1000 ms and still reports"):
        setp("zfs_arc_hashlock_wd_interval_ms", 0)
        setp("zfs_arc_hashlock_wd_threshold_s", 2)
        setp("zfs_arc_debug_hold_ms", 8000)
        machine.succeed("dmesg -C")
        r = bg("dd if=/tank/f of=/dev/null bs=128k skip=5 count=1")
        machine.wait_until_succeeds(f"dmesg | grep -q 'by pid {r} '", timeout=10)
        machine.wait_until_fails(f"kill -0 {r}", timeout=30)
        load1 = float(machine.succeed("cut -d' ' -f1 /proc/loadavg"))
        assert load1 < 4, f"watchdog busy-looping? loadavg {load1}"

    with subtest("many holders: at most 16 stacks per scan, true count in summary"):
        setp("zfs_arc_debug_hold_ms", 0)
        machine.succeed("stat /tank/g* >/dev/null")  # warm dnodes; data stays cold
        setp("zfs_arc_hashlock_wd_threshold_s", 4)
        setp("zfs_arc_hashlock_wd_interval_ms", 1000)
        setp("zfs_arc_debug_hold_ms", 20000)
        machine.succeed("dmesg -C")
        pids = [bg(f"dd if=/tank/g{i} of=/dev/null bs=128k count=1") for i in range(24)]
        machine.wait_until_succeeds(
            "dmesg | grep -E 'arc hash locks held=[0-9]+ stuck=(1[7-9]|2[0-9])'", timeout=20)
        setp("zfs_arc_debug_hold_ms", 0)
        for p in pids:
            machine.wait_until_fails(f"kill -0 {p}", timeout=60)
        log = machine.succeed("dmesg")
        per_scan = 0
        for line in log.splitlines():
            if "ZFS: arc hash lock " in line and " by pid " in line:
                per_scan += 1
                assert per_scan <= 16, "more than 16 holder stacks in one scan"
            elif "ZFS: arc hash locks held=" in line:
                per_scan = 0

    with subtest("export and unload with the watchdog running"):
        setp("zfs_arc_hashlock_wd_threshold_s", 30)
        setp("zfs_arc_hashlock_wd_interval_ms", 10000)
        machine.succeed("zpool export tank")
        machine.succeed("modprobe -r zfs")
        machine.fail("dmesg | grep -E 'BUG:|Oops|general protection|WARNING: CPU'")
```

- [ ] **Step 2: Run tier 1**

```bash
cd ~/p/gir-nix && git add tests/zfs-arc-hashlock-tier1.nix
nix build .#checks.x86_64-linux.zfs-arc-hashlock-tier1 -L 2>&1 | tail -30
```
Expected: all six subtests pass. A failure here is a real watchdog bug (fix the C in
`~/p/zfs-gir`, amend that commit, re-export `0002`) unless it is the flood test's
`stuck>=17` threshold: 24 records can share hash locks, so if it fails with e.g. `stuck=16`,
raise the reader count to 32, don't lower the bound.

- [ ] **Step 3: Commit**

```bash
git commit -m "zfs-debug: tier1 tests for kill switch, interval clamp, flood cap, unload

Claude-Session: https://claude.ai/code/session_01JnPeqcF2XjqzHsvchBD3Hy"
```

---

### Task 5: Tier 2 natural-stress VM

**Files:**
- Create: `tests/zfs-arc-hashlock-tier2.nix`
- Modify: `flake.nix` (`packages.${system}`)

**Interfaces:**
- Consumes: `tests/zfs-vm-common.nix`, the watchdog log format.
- Produces: `packages.x86_64-linux.zfs-arc-hashlock-tier2`, a nixosTest that **passes when
  the hang is reproduced** (a watchdog line appears on the serial console) and fails at
  `globalTimeout` (4 h) when it is not. This is the stage-2 before/after harness.

- [ ] **Step 1: Write `tests/zfs-arc-hashlock-tier2.nix`**

```nix
# Tier 2: try to reproduce the 09-18/09-27 hang naturally. ARC dominates a
# small VM; random reads keep arc_read allocating under hash locks while
# anonymous and mmap-file memory pressure forces direct reclaim and sync
# writers keep z_wr_int/txg_sync busy. PASS = the watchdog reports a stuck
# holder (bug reproduced). FAIL at globalTimeout = not reproduced this run.
# Run on gir in quiet hours with CI paused; see the plan, Task 5.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "zfs-arc-hashlock-tier2";
  globalTimeout = 4 * 3600;

  nodes.machine = { pkgs, ... }: {
    imports = [ ./zfs-vm-common.nix ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 8;
    virtualisation.emptyDiskImages = [ 32768 32768 ];
    boot.kernelParams = [ "zfs.zfs_arc_max=3221225472" ];
    swapDevices = [ { device = "/swapfile"; size = 256; } ];

    systemd.services = let
      load = script: {
        path = [ pkgs.fio pkgs.stress-ng ];
        inherit script;
        serviceConfig.Restart = "always";
      };
    in {
      load-read = load ''
        fio --name=rr --directory=/tank/rand --nrfiles=20 --filesize=1g \
          --rw=randread --bs=16k --numjobs=16 --ioengine=psync \
          --time_based --runtime=86400
      '';
      load-anon = load "stress-ng --vm 4 --vm-bytes 85% --vm-keep --timeout 0";
      load-mmap = load "stress-ng --mmap 4 --mmap-bytes 512m --mmap-file --temp-path /tank/mm --timeout 0";
      load-sync = load ''
        fio --name=sw --directory=/tank/sync --rw=randwrite --bs=4k --size=2g \
          --fsync=1 --numjobs=4 --time_based --runtime=86400
      '';
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("modprobe zfs")
    machine.succeed("zpool create -f -O compression=off tank /dev/vdb /dev/vdc")
    machine.succeed("zfs create -o recordsize=16k tank/rand && zfs create tank/mm && zfs create tank/sync")
    machine.succeed(
        "fio --name=fill --directory=/tank/rand --nrfiles=20 --filesize=1g --rw=write --bs=1m",
        timeout=3600)
    machine.succeed("sync && zpool export tank && zpool import -d /dev tank")
    machine.succeed("systemctl start load-read load-anon load-mmap load-sync")
    # The guest may livelock, so watch the serial console, not the backdoor shell.
    machine.wait_for_console_text(r"ZFS: arc hash lock [0-9]+ held [0-9]+s by pid")
    machine.wait_for_console_text(r"ZFS: arc hash locks held=")
  '';
}
```

- [ ] **Step 2: Expose it** — in `flake.nix` `packages.${system}` add:

```nix
        # Manual, up to 4 h; not in `nix flake check`. Quiet hours, CI paused.
        zfs-arc-hashlock-tier2 = import ./tests/zfs-arc-hashlock-tier2.nix { pkgs = testPkgs; };
```

- [ ] **Step 3: Check that it evaluates and the VM boots its loads** (a real run is Step 4):

```bash
cd ~/p/gir-nix && git add tests/zfs-arc-hashlock-tier2.nix flake.nix
nix build .#zfs-arc-hashlock-tier2.driver -L 2>&1 | tail -3
```
Expected: the driver builds. Then smoke-test interactively:
`./result/bin/nixos-test-driver --interactive`, run `start_all()`,
`machine.wait_for_unit("multi-user.target")`, `machine.succeed("modprobe zfs && swapon --show")`,
then `machine.shutdown()`. Expected: `/swapfile` listed, zfs loads.

- [ ] **Step 4: Real run (quiet hours, CI paused; confirm with the user first)**

```bash
ts=$(date +%Y%m%d-%H%M%S)
nix build .#zfs-arc-hashlock-tier2 -L --rebuild 2>&1 | tee ~/p/gir/logs/zfs-tier2-$ts.log | tail -40
```
Expected: either PASS (bug reproduced; the log holds the holder stacks — this is stage-2
evidence) or timeout FAIL (not reproduced). Append one line per run to
`~/p/gir/logs/zfs-tier2-runs.md`: `<ts> PASS|FAIL <duration> logs/zfs-tier2-<ts>.log`.
After 3 runs without a reproduction, stop: the fault-injection fallback in the spec is a
separate, later change.

- [ ] **Step 5: Commit**

```bash
git commit -m "zfs-debug: tier2 natural-stress VM (manual, stage-2 harness)

Claude-Session: https://claude.ai/code/session_01JnPeqcF2XjqzHsvchBD3Hy"
```

---

### Task 6: Enable on gir (build only; the switch is the user's)

**Files:**
- Modify: `hosts/gir/configuration.nix` (the `imports` list, and one setting)

**Interfaces:**
- Consumes: `modules/zfs-debug.nix` (`gir.zfsDebug.enable`).

- [ ] **Step 1: Import and enable** — in `hosts/gir/configuration.nix`, add
  `../../modules/zfs-debug.nix` to `imports` after `../../modules/zfs-maintenance.nix`, and
  after `boot.zfs.package = pkgs.zfs_2_3;` add:

```nix
  # ARC hash-lock watchdog (patched zfs kmod); modules/zfs-debug.nix.
  gir.zfsDebug.enable = true;
```

- [ ] **Step 2: Prove the host picks up the patched module**

```bash
cd ~/p/gir-nix && git add hosts/gir/configuration.nix
nix eval --raw .#nixosConfigurations.gir.config.boot.zfs.modulePackage.drvPath; echo
nix eval --raw .#packages.x86_64-linux.zfs-kmod-debug.drvPath; echo
nixos-rebuild build --flake .#gir 2>&1 | tail -3
```
Expected: the two `.drv` paths are identical; the build succeeds.

- [ ] **Step 3: Commit**

```bash
git commit -m "gir: enable the ARC hash-lock watchdog zfs kmod

Claude-Session: https://claude.ai/code/session_01JnPeqcF2XjqzHsvchBD3Hy"
```

- [ ] **Step 4: Hand the deploy to the user** (a reboot of gir; never do it yourself). Give them:

```
sudo nixos-rebuild switch --flake ~/p/gir-nix#gir   # then reboot at a planned time
# after the reboot:
cat /sys/module/zfs/parameters/zfs_arc_hashlock_wd_threshold_s   # expect 30
cat /sys/module/zfs/parameters/zfs_arc_debug_hold_ms              # expect 0
```
