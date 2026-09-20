# gir: Network UPS Tools (ticket 24, module 9).
#
# Implements decisions already made; nothing here re-decides them:
#   * ticket 05 — NUT driver/server/monitor/upslog is a **day-one reliability
#     service**, kept natively and owned by `power.ups.*`, *not* `services.*`.
#     `nut-prom`, `nut-selftest` and the `repair-nut.py` helper are kept too, as
#     hand-written units and timers. The Prometheus *server* is dropped; the
#     node-exporter textfile collector is not, so both `.prom` writers stay.
#   * ticket 07 item 15 — `/var/lib/nut` is **not** shared (empty on Ubuntu,
#     runtime-only on NixOS; the upstream module's tmpfiles rule creates it).
#     `rpool/srv/nut-state/{notify,events-repair}` carry `/var/lib/nut-notify`
#     and `/var/lib/nut-events-repair`, which **are** shared. The `fileSystems`
#     entries for both live in `storage.nix`, not here.
#   * ticket 07 item 12 — NUT's passwords live on `rpool/srv/secrets` →
#     `/etc/gir-secrets`. Window A copies `/etc/nut/upsd.users` and
#     `/etc/nut/upsmon.conf` there verbatim, as `nut-upsd.users` and
#     `nut-upsmon.conf` (`windowa-06-copy.sh`, phase 3). No password is inlined
#     in this file or in the Nix store.
#   * 2026-09-19 user decision — service accounts that own files on a shared
#     dataset keep their Ubuntu numeric IDs. For NUT that is **125:135**, read
#     from the live `/etc/passwd` and `/etc/group` on 2026-09-19:
#         nut:x:125:135::/var/lib/nut:/usr/sbin/nologin
#         nut:x:135:
#
# Every UPS fact below was read from the collected Ubuntu configuration
# (`logs/port-configs-20260919-182118/nut/`, and the same files quoted in
# `logs/privileged-audit-20260916-072444.txt` §7f, which is readable without
# root). Live device: CyberPower CP1500PFCLCDa, USB HID 0764:0601, `usbhid-ups`.
#
# ---------------------------------------------------------------------------
# upssched: nothing to port.
# ---------------------------------------------------------------------------
# Ticket 24 flags "upsmon/upssched wiring" as an open item. It is closed here,
# and the answer is that **upssched is dead on gir**:
#
#   * `/etc/nut/upssched.conf` is still the pristine Debian sample, mtime
#     2022-03-24, 3879 bytes, byte-identical to the package's. Its only
#     non-comment line is `CMDSCRIPT /bin/upssched-cmd`. There is **no `AT`
#     line at all**, and `PIPEFN`/`LOCKFN` are both still commented out, so
#     upssched could not even start if it were invoked.
#   * `upsmon.conf` stopped invoking it on 2026-08-31: the `ups-fixes` run
#     replaced `NOTIFYCMD /usr/sbin/upssched` with `NOTIFYCMD
#     /usr/local/sbin/nut-notify` and added `+EXEC` to all seven NOTIFYFLAGs.
#     Since 2026-09-12 that script is a shim onto `gir-nut-health.py notify`.
#
# So there are zero timers and zero commands to carry over. `schedulerRules`
# below writes an inert file that says so, rather than leaving NixOS' default
# (the upstream sample) sitting in `/etc/nut/upssched.conf` to be misread later.
#
# ---------------------------------------------------------------------------
# The shutdown path
# ---------------------------------------------------------------------------
# Ubuntu: upsmon reaches FSD -> touches POWERDOWNFLAG `/etc/killpower` -> runs
# SHUTDOWNCMD `/sbin/shutdown -h +0` -> on the way down
# `/lib/systemd/system-shutdown/nutshutdown` sees the flag and calls
# `upsdrvctl shutdown`, which tells the UPS to cut the load.
#
# NixOS: identical, with one deliberate substitution. The flag moves to
# `/run/killpower` (nixpkgs' default) and the hook becomes the module's own
# `ups-killpower.service` — `ConditionPathExists=<POWERDOWNFLAG>`,
# `WantedBy=shutdown.target`, `Before=final.target`, `ExecStart=upsdrvctl -u
# root shutdown`. `/etc` is a read-only-ish activation-managed tree on NixOS
# while `/run` is the last filesystem standing at `final.target`, so `/run` is
# the correct home for the flag. Every other link in the chain is verbatim.
#
# The path is therefore *complete and wired*, but it is **still unproven** —
# exactly as `2026-09-12-nut-failure-analysis.md` says of the Ubuntu side
# ("end-to-end power-failure protection is not presently functional or
# validated"). See the TODO(verify) at the bottom of this file.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  upsName = "cyberpower";

  # The package the module installs; the helpers must call the same `upsc`.
  nut = config.power.ups.package;

  # ticket 07: shared datasets, declared in storage.nix.
  notifyDir = "/var/lib/nut-notify";
  stateDir = "/var/lib/nut-events-repair";

  # ticket 07: `rpool/srv/secrets`, `neededForBoot`, root 0700.
  secretsDir = "/etc/gir-secrets";
  # Window A copies the whole Ubuntu conf file, not a bare password.
  upsmonSecret = "${secretsDir}/nut-upsmon.conf";
  # ...so the password is lifted out of it at boot, into a root-only runtime
  # file that `LoadCredential=` can take. Never on a command line, never in the
  # store, never in a world-readable path.
  passwordFile = "/run/nut-secrets/upsmon-password";

  # TODO(collect): monitoring.nix (module 10) owns node-exporter. Ubuntu's
  # textfile directory is `--collector.textfile.directory` default
  # `/var/lib/prometheus/node-exporter`; if monitoring.nix picks a different
  # one, change this single binding to match it.
  textfileDir = "/var/lib/prometheus/node-exporter";

  csvDir = "/var/log/nut";
  csv = "${csvDir}/ups.csv";

  binPath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.util-linux
  ];

  ##############################################################################
  # The local health helper.
  #
  # Verbatim `/usr/local/libexec/gir-nut-health.py` (installed 2026-09-12 by
  # `repair-nut.py`, byte-identical to `~/p/gir/nut-health-helper.py`), with
  # only these mechanical changes:
  #   * the shebang, the three hard-coded `/usr/bin/*` tools and the fallback
  #     PATH now point at the Nix store / the system profile;
  #   * STATE, COLLECTOR and the UPS name are interpolated from the bindings
  #     above instead of being repeated;
  #   * two empty-string literals were respelled `""` instead of `''`, because
  #     `''` would end this Nix indented string. No semantic change.
  #
  # TODO(collect): after the cutover, diff this against the Ubuntu original one
  # last time. The two must not drift; `repair-nut.py` is still the recovery
  # tool of record and it rewrites the Ubuntu copy.
  ##############################################################################
  nutHealth = pkgs.writeTextFile {
    name = "gir-nut-health.py";
    executable = true;
    destination = "/libexec/gir-nut-health.py";
    text = ''
      #!${pkgs.python3}/bin/python3
      """Bounded UPS collection and notification; installed by repair-nut.py."""
      import datetime
      import fcntl
      import json
      import math
      import os
      from pathlib import Path
      import re
      import subprocess
      import sys
      import tempfile
      import time

      STATE = Path('${stateDir}')
      COLLECTOR = Path('${textfileDir}/nut.prom')
      UPS = '${upsName}@127.0.0.1'


      def command(argv, seconds=8, data=None):
          try:
              return subprocess.run(argv, input=data, text=True, capture_output=True,
                                    timeout=seconds, check=False)
          except (OSError, subprocess.TimeoutExpired):
              return None


      def atomic(path, text, mode=0o644):
          fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
          try:
              with os.fdopen(fd, 'w') as stream:
                  stream.write(text)
                  stream.flush()
                  os.fchmod(stream.fileno(), mode)
              os.replace(tmp, path)
          finally:
              if os.path.exists(tmp):
                  os.unlink(tmp)


      def query():
          result = command(['${nut}/bin/upsc', UPS])
          if result is None or result.returncode:
              return {}
          return dict(line.split(': ', 1) for line in result.stdout.splitlines() if ': ' in line)


      def number(value):
          try:
              return math.isfinite(float(value))
          except (TypeError, ValueError):
              return False


      def collect():
          data = query()
          up = bool(data.get('ups.status')) and all(
              number(data.get(k)) for k in ('battery.charge', 'battery.runtime', 'ups.load'))
          lines = ['# HELP nut_up 1 if a bounded UPS query returned status and numeric telemetry.',
                   '# TYPE nut_up gauge', 'nut_up ' + str(int(up)),
                   '# TYPE nut_collect_timestamp_seconds gauge',
                   'nut_collect_timestamp_seconds ' + str(int(time.time()))]
          if up:
              status = data['ups.status'].split()
              for name, flag in [('online', 'OL'), ('onbattery', 'OB'), ('lowbattery', 'LB'),
                                 ('replacebattery', 'RB'), ('charging', 'CHRG')]:
                  lines.append('nut_status_' + name + ' ' + str(int(flag in status)))
              fields = {'battery_charge_percent': 'battery.charge',
                        'battery_runtime_seconds': 'battery.runtime', 'battery_volts': 'battery.voltage',
                        'input_volts': 'input.voltage', 'output_volts': 'output.voltage',
                        'load_percent': 'ups.load'}
              for metric, field in fields.items():
                  if number(data.get(field)):
                      lines.append('nut_' + metric + ' ' + data[field])
          atomic(COLLECTOR, '\n'.join(lines) + '\n')
          return 0 if up else 1


      def notify(message, test=False):
          event = 'REPAIR_TEST' if test else os.environ.get('NOTIFYTYPE', 'UNKNOWN')
          event = re.sub('[^A-Za-z0-9_]', '_', event)[:64]
          message = message[:4096]
          # Persist the event before any potentially failing external command.
          with (STATE / 'lock').open('a') as lock:
              fcntl.flock(lock, fcntl.LOCK_EX)
              try:
                  events = json.loads((STATE / 'events.json').read_text())
              except (OSError, ValueError):
                  events = {}
              events[event] = int(time.time())
              atomic(STATE / 'events.json', json.dumps(events) + '\n', mode=0o600)
              lines = ['# HELP nut_last_event_timestamp_seconds Last notification by event type.',
                       '# TYPE nut_last_event_timestamp_seconds gauge']
              for key, value in sorted(events.items()):
                  if re.fullmatch('[A-Za-z0-9_]{1,64}', key) and isinstance(value, int):
                      lines.append('nut_last_event_timestamp_seconds{type="%s"} %s' % (key, value))
              atomic(STATE / 'nut_events.prom', '\n'.join(lines) + '\n')
          if test:
              # Tests exercise real UID/permissions, but do not send mail or UPS commands.
              return 0
          command(['${pkgs.util-linux}/bin/logger', '-t', 'nut-notify', '-p', 'daemon.notice', '--',
                   '[' + event + '] ' + message], seconds=3)
          data = query()
          summary = '\n'.join(k + ': ' + data[k] for k in (
              'ups.status', 'battery.charge', 'battery.runtime', 'ups.load') if k in data)
          body = ('host: ' + os.uname().nodename + '\ntime: '
                  + datetime.datetime.now().astimezone().isoformat() + '\n\n'
                  + message + '\n\n' + (summary or 'UPS query unavailable or timed out.') + '\n')
          # Preserve existing local-root delivery. No new external recipient is introduced.
          result = command(['${pkgs.mailutils}/bin/mail', '-s', 'UPS ' + event + ' on ' + os.uname().nodename,
                            'root'], seconds=10, data=body)
          if result is None or result.returncode:
              command(['${pkgs.util-linux}/bin/logger', '-t', 'nut-notify', '-p', 'daemon.err', '--',
                       'Local mail delivery failed or timed out; event metric was saved.'], seconds=3)
          return 0


      if __name__ == '__main__':
          os.environ['PATH'] = '/run/wrappers/bin:/run/current-system/sw/bin'
          action = sys.argv[1] if len(sys.argv) > 1 else ""
          if action == 'collect':
              sys.exit(collect())
          if action in ('notify', 'test-notify'):
              sys.exit(notify(sys.argv[2] if len(sys.argv) > 2 else "", action == 'test-notify'))
          sys.exit('Expected collect, notify, or test-notify')
    '';
  };
  healthPy = "${nutHealth}/libexec/gir-nut-health.py";

  # The two shims Ubuntu keeps in /usr/local/sbin, so NOTIFYCMD and the timer
  # stay space-free and legible in the generated upsmon.conf.
  notifyCmd = pkgs.writeShellScript "nut-notify" ''
    exec ${healthPy} notify "$@"
  '';
  collectCmd = pkgs.writeShellScript "nut-prom" ''
    exec ${healthPy} collect "$@"
  '';

  ##############################################################################
  # Fail-closed preparation for the two shared state directories.
  #
  # `RequiresMountsFor` (below) makes each unit *require* its own mount unit.
  # This script is the second half: even if the directory exists but is not a
  # mountpoint -- the shape ticket 07 rule 9 exists to catch -- refuse, rather
  # than quietly accumulating state on the root filesystem that the next boot
  # will hide under the real dataset.
  ##############################################################################
  prepareDir =
    {
      dir,
      dataset,
      owner,
      mode,
      files,
      extra ? "",
    }:
    pkgs.writeShellScript "nut-prepare-${baseNameOf dir}" ''
      set -eu
      export PATH=${binPath}
      if ! mountpoint -q "${dir}"; then
        echo "${dir} is not a mountpoint (expected ${dataset})." >&2
        echo "Refusing to create NUT state on the root filesystem." >&2
        exit 1
      fi
      chown ${owner} "${dir}"
      chmod ${mode} "${dir}"
      for f in ${lib.concatStringsSep " " files}; do
        if [ -e "${dir}/$f" ]; then chown ${owner} "${dir}/$f"; fi
      done
      ${extra}
    '';

  ##############################################################################
  # Weekly quick battery self-test.
  #
  # Ubuntu's `/usr/local/sbin/nut-selftest`, unchanged except for how it gets
  # the upsd credentials. Ubuntu awk'd fields 4 and 5 out of the live
  # `/etc/nut/upsmon.conf`; on NixOS that file is `/run/nut/upsmon.conf`, mode
  # 0600, and the nixpkgs generator writes the password **in double quotes** --
  # `awk '{print $5}'` would hand `upscmd` a literal `"secret"` and every test
  # would fail authentication. So the password comes from the same credential
  # the daemons use, and the username is pinned here.
  ##############################################################################
  selftest = pkgs.writeShellScript "nut-selftest" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
        # `hostname` is neither in coreutils nor util-linux on NixOS; Ubuntu's
        # comes from the `hostname` package. Without this the two mail lines
        # below would silently send an empty host name.
        pkgs.nettools
        nut
        pkgs.mailutils
      ]
    }
    UPS=${upsName}
    PROM=${textfileDir}/nut_selftest.prom
    U=upsmon
    P=$(cat "$CREDENTIALS_DIRECTORY/upsd_password") || {
      logger -t nut-selftest "no upsd credential"; exit 1; }

    STATUS=$(upsc "$UPS" ups.status 2>/dev/null)
    CH=$(upsc "$UPS" battery.charge 2>/dev/null)
    case "$STATUS" in
      *OL*) ;;
      *) logger -t nut-selftest "skipped: not on line power (status=$STATUS)"; exit 0;;
    esac
    case "$CH" in
      ""|*[!0-9]*) logger -t nut-selftest "skipped: unreadable charge '$CH'"; exit 0;;
      *) [ "$CH" -ge 90 ] || { logger -t nut-selftest "skipped: charge $CH%"; exit 0; };;
    esac

    upscmd -u "$U" -p "$P" "$UPS" test.battery.start.quick >/dev/null 2>&1 \
      || { logger -t nut-selftest "upscmd failed to start test"; exit 1; }
    logger -t nut-selftest "quick test started (charge $CH%)"

    R=""; i=0
    while [ "$i" -lt 60 ]; do
      sleep 2; i=$((i+1))
      R=$(upsc "$UPS" ups.test.result 2>/dev/null)
      case "$R" in
        ""|*"No test initiated"*|*progress*|*Pending*) ;;
        *) break;;
      esac
    done
    logger -t nut-selftest "result: $R"

    case "$R" in
      *[Pp]assed*|*"Done and passed"*)          V=1;;
      ""|*"No test initiated"*|*progress*)      V=-1;;
      *)                                        V=0;;
    esac
    [ "$V" = 1 ] || printf 'host: %s\ntime: %s\nups.test.result: %s\n' \
      "$(hostname)" "$(date -Is)" "$R" \
      | mail -s "UPS self-test NOT passed on $(hostname): $R" root 2>/dev/null

    mkdir -p ${textfileDir}
    TMP=$(mktemp "$PROM.XXXXXX") || exit 0
    {
      echo "# HELP nut_selftest_passed 1 pass, 0 fail/warning, -1 inconclusive."
      echo "# TYPE nut_selftest_passed gauge"
      echo "nut_selftest_passed $V"
      echo "# HELP nut_selftest_timestamp_seconds Unix time of the last self-test."
      echo "# TYPE nut_selftest_timestamp_seconds gauge"
      echo "nut_selftest_timestamp_seconds $(date +%s)"
    } > "$TMP"
    chmod 0644 "$TMP"; mv -f "$TMP" "$PROM"
  '';

  ##############################################################################
  # CSV telemetry. Ubuntu's `/usr/local/sbin/nut-upslog-run`, verbatim; its
  # three comments are the reasons it exists and are kept.
  ##############################################################################
  upslogRun = pkgs.writeShellScript "nut-upslog-run" ''
    # upslog stays in the FOREGROUND with -l - (given a file it forks and the
    # parent exits, which Type=simple reads as the service completing -- that
    # caused the original restart loop). systemd appends our stdout to the CSV.
    #
    # Keeping the format string here rather than in the unit avoids systemd's %
    # specifier escaping entirely. NUT's strftime codes use @ rather than %.
    #
    # grep drops upslog's two-line startup banner, which would otherwise be
    # appended into the CSV on every restart and break any parser.
    set -u
    FMT='%TIME @Y-@m-@dT@H:@M:@S%,%VAR ups.status%,%VAR ups.load%,%VAR battery.charge%,%VAR battery.runtime%,%VAR battery.voltage%,%VAR input.voltage%,%VAR output.voltage%'
    ${nut}/bin/upslog -l - -s ${upsName}@localhost -i 30 -f "$FMT" \
      | ${pkgs.gnugrep}/bin/grep --line-buffered -vE '^(Network UPS Tools upslog|logging status of)'
  '';

  # upssched never runs on gir (see the header). This inert file replaces
  # nixpkgs' default of shipping the upstream *sample* as /etc/nut/upssched.conf,
  # where a later reader would mistake it for configuration. The CMDSCRIPT is a
  # tripwire: if anything ever does invoke upssched, it says so in the journal
  # instead of failing obscurely.
  upsschedCmd = pkgs.writeShellScript "upssched-cmd" ''
    ${pkgs.util-linux}/bin/logger -t upssched-cmd -p daemon.warning -- \
      "upssched fired unexpectedly on gir: $*"
    exit 0
  '';
  schedulerRules = pkgs.writeText "upssched.conf" ''
    # gir does not use upssched. upsmon's NOTIFYCMD calls gir-nut-health.py
    # directly (see modules/nut.nix). Ubuntu's /etc/nut/upssched.conf was the
    # untouched upstream sample with no AT rules, so there was nothing to port.
    #
    # CMDSCRIPT must precede any AT line. There are no AT lines.
    CMDSCRIPT ${upsschedCmd}
  '';

  # Lifts field 5 out of the MONITOR line of the Window A copy of upsmon.conf.
  # The secret never reaches a command line (`awk` reads the file) and the
  # result is 0400 root on a 0700 RuntimeDirectory.
  extractPassword = pkgs.writeShellScript "nut-extract-password" ''
    set -eu
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gawk
      ]
    }
    umask 077
    src=${upsmonSecret}
    out=${passwordFile}
    if [ ! -r "$src" ]; then
      echo "$src is unreadable; is rpool/srv/secrets mounted?" >&2
      exit 1
    fi
    pw=$(awk '$1 == "MONITOR" { p = $5; gsub(/^"|"$/, "", p); print p; exit }' "$src")
    if [ -z "$pw" ]; then
      echo "no MONITOR password found in $src" >&2
      exit 1
    fi
    printf '%s\n' "$pw" > "$out.tmp"
    chmod 0400 "$out.tmp"
    mv -f "$out.tmp" "$out"
  '';

in
{
  ##############################################################################
  # 1. The `nut` account: Ubuntu's 125:135, pinned.
  #
  # nixpkgs does not ship a `nut` account at all -- upstream runs `upsd` and
  # `upsdrvctl` as root and `upsmon` as a fresh `nutmon` system user. That is
  # wrong for gir in one specific, already-diagnosed way: NOTIFYCMD runs as the
  # upsmon user, and `/var/lib/nut-events-repair` on the shared dataset is owned
  # `nut:nut`. A dynamically-allocated `nutmon` could not write there, which is
  # exactly the permission bug `2026-09-12-nut-failure-analysis.md` found on
  # Ubuntu ("The `nut` account cannot update the event history or create the
  # event metric"). So upsmon runs as `nut`, with Ubuntu's numeric IDs.
  #
  # `ids.uids`/`ids.gids` is the postgresql.nix / plex.nix pattern (ticket 24,
  # module 2): users.nix §"Cross-module UID/GID parity" records nut 125:135 and
  # deliberately leaves it to this module. No `mkForce` is needed -- unlike
  # `postgres` and `plex`, `nut` has no entry in nixpkgs' `misc/ids.nix`, so
  # this adds a key rather than overriding one. If users.nix ever pins these
  # too, identical definitions merge (`types.int` uses `mergeEqualOption`).
  ##############################################################################
  ids.uids.nut = 125;
  ids.gids.nut = 135;

  users.groups.nut.gid = config.ids.gids.nut;

  # nixpkgs builds NUT with `--with-group=nutmon` and ships USB rules that set
  # GROUP="nutmon". This module runs everything as `nut` (or root), so nothing
  # needs the group to have members -- but udev resolves GROUP= at rule-parse
  # time and logs an error per line when it cannot. On the first NixOS boot
  # (2026-09-20) that was 3640 error-level lines from 62-nut-usbups.rules, which
  # buried every other failure in `journalctl -p err`. Declaring it empty costs
  # one gid and silences all of them. See the resolved TODO at the end of this file.
  users.groups.nutmon = { };
  users.users.nut = {
    uid = config.ids.uids.nut;
    group = "nut";
    isSystemUser = true;
    description = "Network UPS Tools";
    # Ubuntu: /var/lib/nut, /usr/sbin/nologin. `createHome` stays false -- the
    # module's own tmpfiles rule makes /var/lib/nut, and ticket 07 item 15 says
    # that directory is runtime-only and is NOT the shared dataset.
    home = "/var/lib/nut";
  };

  ##############################################################################
  # 2. power.ups -- ups.conf / upsd.conf / nut.conf, verbatim from Ubuntu
  ##############################################################################

  power.ups = {
    enable = true;

    # /etc/nut/nut.conf: `MODE=standalone`. One machine, its own UPS, no
    # netclients. (If misfit is ever put on this UPS this becomes `netserver`
    # and upsd.listen widens -- the Ubuntu file carries that same note.)
    mode = "standalone";

    ups.${upsName} = {
      # ups.conf `[cyberpower]`, as of the 2026-09-12 repair.
      driver = "usbhid-ups";
      port = "auto";
      description = "CyberPower CP1500PFCLCDa";

      # Everything the nixpkgs submodule has no named option for. These land
      # after the generated driver/port/desc/sdorder lines, inside the section.
      directives = [
        # Ubuntu sets `pollinterval = 5` as a *global* in ups.conf, above the
        # first section. The nixpkgs generator has no hook for globals other
        # than maxstartdelay, and NUT accepts pollinterval per-section, which
        # is equivalent for a single-UPS host.
        "pollinterval = 5"

        # The 2026-09-12 repair. `pollonly` avoids USB interrupt transfers --
        # the `usbhid-ups` stall that wedged the whole stack on 09-06 was a
        # blocked USBDEVFS_REAPURB. Upstream recommends it for CPS units.
        "pollonly"
        "pollfreq = 10"

        "vendorid = 0764"
        "productid = 0601"

        # Begin shutdown with 5 minutes of runtime left; carried over from
        # pwrstatd's runtime-threshold = 300 / lowbatt-threshold = 35.
        #
        # TODO(verify): these two overrides do NOT by themselves make upsmon
        # trigger on runtime/charge -- NUT wants `ignorelb` for that, and it is
        # deliberately absent here as it is on Ubuntu. The 09-12 analysis says
        # so explicitly and says the policy choice is still open. Carried
        # unchanged so the port is not the place that changes behaviour.
        "override.battery.runtime.low = 300"
        "override.battery.charge.low = 35"
      ];
    };

    # upsd.conf: `LISTEN 127.0.0.1 3493`. Loopback only -- widening this would
    # expose UPS control to the LAN. openFirewall therefore stays false, which
    # also keeps ticket 14 (firewall off) irrelevant here.
    upsd.listen = [
      {
        address = "127.0.0.1";
        port = 3493;
      }
    ];

    # upsd.users `[upsmon]`. NUT 2.8 renamed master/slave to primary/secondary
    # and the nixpkgs option only accepts the new spelling; the wire protocol
    # is unchanged. instcmds are the two the self-test needs (granted on
    # Ubuntu 2026-08-31).
    users.upsmon = {
      inherit passwordFile;
      upsmon = "primary";
      instcmds = [
        "test.battery.start.quick"
        "test.battery.stop"
      ];
    };

    upsmon = {
      # See §1: the notify helper writes to a dataset owned by nut:nut.
      user = "nut";
      group = "nut";

      monitor.${upsName} = {
        system = "${upsName}@localhost";
        powerValue = 1;
        user = "upsmon";
        type = "primary";
        # passwordFile defaults to power.ups.users.upsmon.passwordFile.
      };

      # The rest of upsmon.conf, line for line.
      settings = {
        MINSUPPLIES = 1;

        # Ubuntu: `/sbin/shutdown -h +0`.
        SHUTDOWNCMD = "${config.systemd.package}/bin/shutdown -h +0";

        # Ubuntu: `/etc/killpower`, consumed by the packaged
        # /lib/systemd/system-shutdown/nutshutdown hook. On NixOS the hook is
        # the module's ups-killpower.service and the flag belongs in /run --
        # see the header. This is nixpkgs' default; named explicitly because
        # the difference from Ubuntu matters when reading a post-outage log.
        POWERDOWNFLAG = "/run/killpower";

        POLLFREQ = 5;
        POLLFREQALERT = 5;
        HOSTSYNC = 15;
        DEADTIME = 15;

        # Time between the final warning and calling SHUTDOWNCMD.
        FINALDELAY = 5;

        # NOT upssched -- see the header. `+EXEC` on every flag is the
        # 2026-08-31 fix; without it NOTIFYCMD is never invoked.
        NOTIFYCMD = "${notifyCmd}";
        NOTIFYFLAG = [
          [
            "ONLINE"
            "SYSLOG+WALL+EXEC"
          ]
          [
            "ONBATT"
            "SYSLOG+WALL+EXEC"
          ]
          [
            "LOWBATT"
            "SYSLOG+WALL+EXEC"
          ]
          [
            "FSD"
            "SYSLOG+WALL+EXEC"
          ]
          [
            "COMMBAD"
            "SYSLOG+WALL+EXEC"
          ]
          [
            "COMMOK"
            "SYSLOG+WALL+EXEC"
          ]
          [
            "SHUTDOWN"
            "SYSLOG+WALL+EXEC"
          ]
        ];
      };
    };

    # upssched is not wired on gir (header). nixpkgs would otherwise drop the
    # upstream *sample* into /etc/nut/upssched.conf, which reads like config.
    schedulerRules = "${schedulerRules}";
  };

  ##############################################################################
  # 3. The password, off the secrets dataset
  #
  # Ordered before both daemons and *required by* them: without the credential
  # `LoadCredential=` fails and neither upsd nor upsmon can authenticate, so
  # hard-requiring costs no availability that was not already lost.
  ##############################################################################

  systemd.services.nut-secrets = {
    description = "Extract the upsd password from the host secrets dataset";
    before = [
      "upsd.service"
      "upsmon.service"
      "nut-selftest.service"
    ];
    requiredBy = [
      "upsd.service"
      "upsmon.service"
    ];
    # ticket 07 rule 9: refuse rather than invent a password file.
    unitConfig.RequiresMountsFor = [ secretsDir ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "nut-secrets";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
      UMask = "0077";
      ExecStart = extractPassword;
    };
  };

  ##############################################################################
  # 4. The two shared-state helper units
  #
  # *** These two unit names are what storage.nix's TODO(collect) asks for: ***
  #         nut-notify.service        owns /var/lib/nut-notify
  #         nut-events-repair.service owns /var/lib/nut-events-repair
  #
  # They are `Wants=`/`Before=` of upsmon, never `Requires=`. That asymmetry is
  # deliberate: if a state dataset is missing, the cost is a lost event history
  # (cosmetic), whereas blocking upsmon costs the power-fail shutdown itself.
  # A reliability service must not be taken down by its own telemetry. The
  # failure is still loud -- the unit fails, systemd goes degraded, and
  # node-exporter's systemd collector exports it.
  ##############################################################################

  systemd.services.nut-notify = {
    description = "NUT notify state directory (rpool/srv/nut-state/notify)";
    before = [ "upsmon.service" ];
    wantedBy = [
      "multi-user.target"
      "upsmon.service"
    ];
    # storage.nix may add the same guard via its `mountsFor` helper; unitConfig
    # list values concatenate, so both definitions are safe together.
    unitConfig.RequiresMountsFor = [ notifyDir ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = prepareDir {
        dir = notifyDir;
        dataset = "rpool/srv/nut-state/notify";
        # Live Ubuntu ownership, read 2026-09-19: the directory and its one
        # `events` file are root:root 0755 / 0644.
        owner = "root:root";
        mode = "0755";
        files = [ "events" ];
      };
    };
  };

  systemd.services.nut-events-repair = {
    description = "NUT event state directory (rpool/srv/nut-state/events-repair)";
    before = [ "upsmon.service" ];
    wantedBy = [
      "multi-user.target"
      "upsmon.service"
    ];
    unitConfig.RequiresMountsFor = [ stateDir ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = prepareDir {
        dir = stateDir;
        dataset = "rpool/srv/nut-state/events-repair";
        # Live Ubuntu ownership, read 2026-09-19: nut:nut 0755, holding
        # `lock`, `events.json` (0600) and `nut_events.prom` (0644).
        owner = "nut:nut";
        mode = "0755";
        files = [
          "lock"
          "events.json"
          "nut_events.prom"
        ];
        # node-exporter follows this one readable file into the dataset; its
        # own directory stays root-owned. `repair-nut.py` created exactly this
        # symlink on 2026-09-12 and it is how nut_last_event_timestamp_seconds
        # reaches the exporter at all. Recreated here rather than in a tmpfiles
        # rule so that monitoring.nix keeps sole ownership of that directory.
        extra = ''
          install -d -m 0755 ${textfileDir}
          ln -sfn ${stateDir}/nut_events.prom ${textfileDir}/nut_events.prom
        '';
      };
    };
  };

  ##############################################################################
  # 5. Telemetry, collector and self-test (ticket 05 keeps all three)
  #
  # Both `.prom` writers are kept. Ticket 18 drops the Prometheus *server*; the
  # node-exporter textfile collector survives, so nut-prom and nut-selftest keep
  # publishing and `nut_up == 0` stays the alertable signal for the class of
  # stall that took the stack out on 2026-09-06.
  ##############################################################################

  # Ubuntu nut-upslog.service -> here, with the unit names remapped
  # (nut-server -> upsd, nut-monitor -> upsmon).
  systemd.services.nut-upslog = {
    description = "NUT telemetry to CSV";
    after = [
      "upsd.service"
      "upsmon.service"
    ];
    requires = [ "upsd.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = upslogRun;
      StandardOutput = "append:${csv}";
      StandardError = "journal";
      Restart = "always";
      RestartSec = 15;
      Nice = 10;
    };
  };

  # Ubuntu nut-prom.service + its 20-bounded-query.conf drop-in, folded in.
  systemd.services.nut-prom = {
    description = "NUT state to Prometheus textfile collector";
    after = [ "upsd.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0755 ${textfileDir}";
      ExecStart = collectCmd;
      # The drop-in added on 2026-09-12: a stalled upsd must not hold a
      # oneshot open forever. The helper's own upsc timeout is 8s.
      TimeoutStartSec = 20;
      Nice = 10;
    };
  };

  systemd.timers.nut-prom = {
    description = "Publish NUT state every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
      AccuracySec = "10s";
    };
  };

  systemd.services.nut-selftest = {
    description = "NUT quick battery self-test";
    after = [
      "upsd.service"
      "nut-secrets.service"
    ];
    requires = [ "nut-secrets.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = selftest;
      TimeoutStartSec = 300;
      Nice = 10;
      LoadCredential = [ "upsd_password:${passwordFile}" ];
    };
  };

  systemd.timers.nut-selftest = {
    description = "Weekly NUT quick battery self-test";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 04:30";
      RandomizedDelaySec = "30min";
      Persistent = true;
    };
  };

  ##############################################################################
  # 6. upsmon supervision
  #
  # Ubuntu carries /etc/systemd/system/nut-monitor.service.d/restart.conf,
  # added because stock nut-monitor is Type=forking with a PIDFile that does not
  # match the process systemd tracks, so a dead upsmon could go unnoticed.
  # nixpkgs' upsmon.service is Type=forking with **no** PIDFile=, so systemd
  # tracks the forked child correctly and that specific bug cannot recur -- but
  # the restart policy was a deliberate reliability decision, so it is carried.
  # As the Ubuntu comment says: this covers the cases systemd sees;
  # `nut_collect_timestamp_seconds` going stale covers the rest.
  ##############################################################################
  systemd.services.upsmon.serviceConfig = {
    Restart = "always";
    RestartSec = 10;
  };

  ##############################################################################
  # 7. Log directory and rotation
  #
  # /var/log is rpool/nixos/log (ticket 07) -- per-OS, so the CSV history does
  # not cross over and starts fresh on NixOS. Rotation is Ubuntu's
  # /etc/logrotate.d/nut-telemetry verbatim; `copytruncate` is required because
  # upslog holds the fd open through systemd's `append:`.
  ##############################################################################
  systemd.tmpfiles.rules = [
    "d ${csvDir} 0755 root root -"
  ];

  services.logrotate.settings.nut-telemetry = {
    files = csv;
    frequency = "weekly";
    rotate = 26;
    compress = true;
    delaycompress = true;
    missingok = true;
    notifempty = true;
    copytruncate = true;
  };

  ##############################################################################
  # 8. Guards
  ##############################################################################
  assertions = [
    {
      assertion = config.power.ups.upsmon.user == "nut";
      message = ''
        power.ups.upsmon.user must be "nut": NOTIFYCMD runs as the upsmon user
        and ${stateDir} is owned nut:nut on the shared dataset.
      '';
    }
    {
      assertion = config.users.users.nut.uid == 125 && config.users.groups.nut.gid == 135;
      message = ''
        The nut account must keep Ubuntu's 125:135 -- ${stateDir} lives on a
        dataset shared with Ubuntu and is owned by those numeric IDs.
      '';
    }
  ];

  ##############################################################################
  # Open items carried out of this module
  #
  # TODO(verify): the shutdown path is wired but has never been exercised end
  # to end, on either OS. On the first NixOS boot, with the soak quiet:
  #   1. `touch /run/killpower && systemctl start ups-killpower.service` proves
  #      only the condition and the unit, NOT the UPS command -- do not run it
  #      on a live host, it cuts the load.
  #   2. The real test is `upsmon -c fsd` with everything else stopped. Ticket
  #      23 (Window B) should book it as a scheduled event, not improvise it.
  #   3. Time it: `override.battery.runtime.low = 300` assumes ZFS root + k3s +
  #      libvirt can stop inside five minutes, which has never been measured.
  #
  # TODO(verify): local mail. `2026-09-12-nut-failure-analysis.md` records that
  # delivery to a person was never demonstrated -- `/etc/aliases` has only
  # `postmaster: root`. The helper and the self-test both `mail root`, and
  # ticket 05 says the Postfix port must "fix the root alias". Until it does,
  # the `.prom` metrics are the only notification that actually arrives.
  #
  # RESOLVED 2026-09-20 (first NixOS boot): the unknown-group warning predicted
  # here did happen, and it was not quiet -- 3640 error-level lines from
  # 62-nut-usbups.rules, one per rule, enough to hide every other boot failure
  # behind it. Taking the first option offered above: `users.groups.nutmon` is
  # now declared empty near the `nut` account. Function was never affected --
  # `usbhid-ups` runs as root and `upsc` answered throughout.
  #
  # TODO(collect): NUT is 2.7.4 on Ubuntu and 2.8.4 here. The upgrade is
  # wanted -- the 09-12 analysis recommends "a maintained NUT build using
  # modern libusb" -- but it means the `pollonly`/`pollfreq` mitigation is being
  # re-tested against different driver code. Watch `nut_up` and the CSV for
  # missing-measurement rows through the soak before calling the USB stall
  # fixed.
}
