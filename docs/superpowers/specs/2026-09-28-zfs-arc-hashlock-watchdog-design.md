# ZFS ARC hash-lock watchdog and VM reproduction — design

Date: 2026-09-28. Status: approved in conversation, awaiting spec review.
Stage 1 of "prove, then fix". Stage 2 (the `arc_read` fix) gets its own spec once
stage 1 has produced evidence.

## Problem

gir hangs with every ZFS thread waiting on an ARC buf hash lock (09-18, 09-23 incident 1,
09-27; see `~/p/gir/2026-09-27-gir-arc-deadlock.md`). The 09-18 vmcore (Ubuntu, ZFS 2.2.2)
named the holders: 25 threads in `arc_read` that took the hash lock, then allocated the ABD
(`arc_hdr_alloc_abd` → `abd_alloc_chunks`, `GFP_NOIO`, direct reclaim allowed) and sat in
`reclaim_throttle` holding it. ZFS 2.3 removed the amplifier (the ARC shrinker ignoring
`!__GFP_FS` reclaim), but 2.3.9 still allocates under the lock (`arc.c:6196`, lock released
~`6357`) and can also sleep in `arc_wait_for_eviction` (`arc.c:5239`) there.

On 2.3.9 the holder has never been observed: both NixOS-era hangs lost their vmcore, and
the holder is invisible to khungtaskd because a task looping through `reclaim_throttle`
keeps context-switching, so it is never "hung". `hung_task_all_cpu_backtrace` would only
catch it if it happened to be on-CPU.

## Goals

1. Name any task holding an ARC hash lock for ≥30 s, with its kernel stack, on netconsole,
   during a livelock and without a vmcore.
2. Reproduce the hang in a VM: deterministically (tier 1, tests the watchdog) and naturally
   (tier 2, the before/after test for the stage-2 fix).

Non-goals: fixing the bug (stage 2); the kdump OOM (separate one-line change, §6.1 of the
09-27 doc); CI memory caps.

## Components

### 1. Patches `patches/zfs/0001-arc-debug-hold.patch` and `0002-arc-hashlock-watchdog.patch` (against zfs 2.3.9)

Changes in `module/zfs/arc.c`, plus the SPL owner-report helper (see License).

**Watchdog thread `arc_hl_wd`.** Started at the end of `arc_init()`, stopped at the start
of `arc_fini()`, using whichever thread/cv idiom arc.c already uses for its own threads.
Each wake-up (every `zfs_arc_hashlock_wd_interval_ms`):

```
for i in 0..BUF_LOCKS-1:
    owner = mutex_owner(&buf_hash_table.ht_locks[i])        // READ_ONCE of m_owner
    if owner != NULL && owner == last_owner[i]: streak[i]++
    else: last_owner[i] = owner; streak[i] = 1; reported_at[i] = 0
    held_s = streak[i] * interval
    if owner && held_s >= threshold && (reported_at[i] == 0 || held_s - reported_at[i] >= 60):
        report(i, owner, held_s); reported_at[i] = held_s
```

State arrays (`last_owner`, `streak`, `reported_at`, 2048 entries each) are private to the
thread: no locking. The lock sites are not instrumented; persistence of the same owner across
consecutive samples is the hold-time estimate. A false positive requires one task to hold the
same lock at every sample and costs one log line.

**report()** runs under `rcu_read_lock()`: re-read `m_owner`, and only if it still equals
`owner`, `get_task_struct()`; leave RCU; print; `put_task_struct()`. Output, `KERN_WARNING`:

```
ZFS: arc hash lock <i> held <n>s by pid <pid> [<comm>] state=<R|S|D|...> waiters=<0|1>
<sched_show_task(owner)>
```

`waiters` is the `MUTEX_FLAG_WAITERS` bit of the kernel mutex owner word (no wait-list walk).
At most 16 holder stacks per scan; after the per-holder lines, one summary line
`ZFS: arc hash locks held=<h> stuck=<s> (>=<threshold>s)`. With `hung_task_panic=1` the
panic path already calls `console_verbose()`, and gir runs `kernel.printk = 7 4 1 7`
(console loglevel 7), so these `KERN_WARNING` (4) lines reach netconsole either way. VMs
must set `boot.consoleLogLevel = 7` for the same reason.

**Debug hook.** In `arc_read`, immediately before `arc_hdr_alloc_abd(hdr, alloc_flags)`:
`if (zfs_arc_debug_hold_ms) delay(MSEC_TO_TICK(zfs_arc_debug_hold_ms));` — the hash lock
is held at that point. Test-only.

**Module parameters** (`ZFS_MODULE_PARAM`, runtime-writable, read on each scan):

| parameter | default | meaning |
|---|---|---|
| `zfs_arc_hashlock_wd_threshold_s` | 30 | report holders held ≥ this; 0 disables the scan |
| `zfs_arc_hashlock_wd_interval_ms` | 10000 | scan period |
| `zfs_arc_debug_hold_ms` | 0 | test hook: sleep this long holding the hash lock in `arc_read` |

**License.** `sched_show_task()` and `__put_task_struct()` are `EXPORT_SYMBOL_GPL`
(verified in the 6.12.109 `Module.symvers`). `spl.ko` is already `MODULE_LICENSE("GPL")`, so
the owner-report helper lives in SPL (`spl_mutex_report_owner()` in `spl-thread.c`), and
`zfs.ko` stays CDDL and calls it. This replaces the original idea of retagging `META`, which
would also flip configure-time GPL-symbol checks. Private build, never distributed; the
stage-2 fix stays upstream-clean.

### 2. Nix wiring `modules/zfs-debug.nix`

Option `gir.zfsDebug.enable` (bool). When true, `boot.zfs.package` =
the pinned zfs 2.3.9 with the patch appended to `patches` (kernel module rebuilt; userland is
the same 2.3.9 and the on-disk format is untouched). Imported by `hosts/gir`; enabled on gir.
Rollback: set false, rebuild, reboot.

### 3. Tier 1 check `checks.zfs-arc-hashlock-tier1` (nixosTest, in `nix flake check`)

VM: same kernel (6.12.109) and patched zfs, 2 GB RAM, 2 vCPU, two virtio disks.
1. Create a pool, write a 1 GiB file, export/import (cold ARC).
2. Set `zfs_arc_debug_hold_ms=60000`, `zfs_arc_hashlock_wd_threshold_s=10`,
   `zfs_arc_hashlock_wd_interval_ms=2000`; start `dd` reading the file in the background.
3. Assert within 30 s: a `ZFS: arc hash lock ... by pid <dd pid>` line in dmesg whose stack
   contains `arc_read`.
4. Set the hold to 0; assert `dd` finishes and no new report appears for 20 s.

### 4. Tier 2 nixosTest `packages.zfs-arc-hashlock-tier2` (manual, not in `checks`)

VM: 4 GB RAM, 8 vCPU, `zfs_arc_max=3G`, 256 MB swap, patched zfs with defaults.
Load, concurrently: `fio` random 16K reads across a 20 GB dataset (ARC misses);
`stress-ng --vm` plus mmap-write jobs (the `rust-lld` pattern); sync writers keeping
`z_wr_int`/`txg_sync` busy. Runs up to a configurable wall time, capturing the serial
console to a timestamped log.
Success = a hang with watchdog lines naming holders. After 3 runs without a hang, retry with
`fail_page_alloc`-style slowdown (fault injection to delay, not fail, order-0 allocations).
This runner is the before/after harness for stage 2.

## Operations

- VM runs on gir during quiet hours with CI paused. Guest RAM is fixed, so guest pressure
  stays in the guest; disk I/O lands on the host pool backing the test images.
- Deploying the watchdog to gir: `nixos-rebuild switch` + reboot at a planned time, after
  tier 1 passes.
- At the next gir hang: read misfit's netconsole for `ZFS: arc hash lock` lines; the holder
  stack decides stage 2 (allocation under hash lock, `arc_wait_for_eviction`, or something
  new).

## Risks

- **Watchdog bug in a kernel module on the production host.** Mitigated by: read-only scan,
  RCU-guarded task access, tier 1 first, threshold-0 kill switch at runtime.
- **Tier 2 never reproduces.** Accepted; the watchdog on gir still answers the question at
  the next natural hang.
- **Local patch drift** when nixpkgs bumps zfs. The patch applies to 2.3.9 only; a bump
  fails the build loudly, which is the desired signal.
