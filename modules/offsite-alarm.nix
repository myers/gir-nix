# Offsite staleness alarm and freshness heartbeat -- gir iss
# `offsite-staleness-alarm` (410862f), specified by `design-staleness-alarm`
# (5a5db6f) and ADR 0004 in ~/p/gir
# (docs/adr/0004-offsite-alarm-on-sender-reading-receiver.md), map `5c80d58`
# (Offsite backup).
#
# Why this exists: from the 2026-09-20 NixOS cutover until 2026-10-07 nothing
# replicated to r2d2, and nothing noticed. The job had been a line in myers'
# Ubuntu crontab; the 2022-era check that should have caught it judged
# syncoid's exit status, which is fine right up until the job stops running.
# So this check judges what *landed*: the `creation` of the newest snapshot on
# each receiving dataset (a received snapshot keeps the time gir took it).
#
# ADR 0004: the check runs here, on the sender, and reads r2d2 over ssh as
# `remotebackup` -- nothing is installed on r2d2. "gir can't report gir
# stopping" doesn't bite: what died was the crontab, not gir, and a check
# declared next to `services.syncoid` can't be dropped that way.
#
# What runs:
#
#   offsite-staleness            daily 09:00. Mails root when any target's
#                                newest snapshot is over 48 h old (two missed
#                                nights), has no snapshots, or can't be read
#                                (ssh or zfs error), or when a remote pool is
#                                at 90% or more. Mails again every morning it
#                                stays that way; silent when all is fine.
#   offsite-freshness-heartbeat  Mondays 07:30. Always mails the table, so a
#                                Monday without it means the check or gir's
#                                mail is broken (NixOS ran with no MTA from
#                                09-20 to 09-22; postfix.nix).
#   notify-failure@<unit>        OnFailure= of every syncoid-* unit (and of the
#                                two above): mails `systemctl status` plus a
#                                journal tail immediately. Decision 7: the
#                                faster, noisier signal on top of the 48 h one.
#
# Targets are generated at eval time from `services.syncoid.commands`
# (decision 3), so a dataset added to syncoid.nix joins the check by itself.
# A target containing `:` is `user@host:dataset`, read over ssh; anything else
# is a local dataset (today only the music pull, bank7/music/r2d2), read here.
# Remote pools to watch for capacity are the first component of each remote
# target, per host -- today just r2d2's `mmm`, which reached 96% unnoticed in
# September 2026.
#
# Duplicity (not built yet, map ticket af03d68) must add each archive's newest
# manifest mtime on r2d2 to this same list, at the same threshold.
#
# Credentials and sandbox: runs as the syncoid module's `syncoid` user with its
# key /var/lib/syncoid/remotebackup and r2d2's host key pinned in
# /etc/ssh/ssh_known_hosts (syncoid.nix). It deliberately does not reuse that
# module's RootDirectory sandbox; the set below is simpler and still reaches
# the key, /dev/zfs, /etc/ssh and sendmail. /dev/zfs is 0666 and `zfs list` /
# `zpool list` work unprivileged (checked as myers on gir and as remotebackup
# on r2d2, 2026-10-08). sendmail is a setgid-postdrop wrapper that drops into
# /var/lib/postfix/queue/maildrop, so NoNewPrivileges stays off and that
# directory is writable.
#
# Manual runs (the env overrides exist for testing; the timers set none):
#
#   systemctl start offsite-staleness
#   systemctl start offsite-freshness-heartbeat
#   systemd-run -p User=syncoid -p Group=syncoid --pipe --wait \
#     -E OFFSITE_STALE_HOURS=1 /run/current-system/sw/bin/offsite-check alarm
#
#   OFFSITE_STALE_HOURS   threshold in hours (default 48)
#   OFFSITE_CAP_PERCENT   pool capacity alarm, percent (default 90)
#   OFFSITE_SSH_KEY       identity file (default the syncoid key)
#   OFFSITE_SSH_HOST      replaces every remote user@host (e.g. an ssh alias)
#   OFFSITE_DRY_RUN=1     print the mail to stdout instead of sending it
{ config, lib, pkgs, ... }:

let
  staleHours = 48;
  capPercent = 90;
  sshKey = config.services.syncoid.sshKey;

  ##########################################################################
  ## Targets, from services.syncoid.commands
  ##########################################################################
  parse =
    name: cmd:
    let
      parts = lib.splitString ":" cmd.target;
      remote = lib.length parts == 2;
    in
    {
      inherit name;
      host = if remote then lib.head parts else "";
      dataset = if remote then lib.last parts else cmd.target;
    };

  targets = lib.mapAttrsToList parse config.services.syncoid.commands;
  remoteTargets = lib.filter (t: t.host != "") targets;

  # One line per target: name <TAB> host <TAB> dataset, host `-` when local
  # (an empty field would collapse: tab is IFS whitespace to `read`).
  targetsFile = pkgs.writeText "offsite-targets.tsv" (
    lib.concatMapStrings (
      t: "${t.name}\t${if t.host == "" then "-" else t.host}\t${t.dataset}\n"
    ) targets
  );

  # One line per remote pool: host <TAB> pool.
  poolsFile = pkgs.writeText "offsite-pools.tsv" (
    lib.concatMapStrings (p: "${p}\n") (
      lib.unique (map (t: "${t.host}\t${lib.head (lib.splitString "/" t.dataset)}") remoteTargets)
    )
  );

  ##########################################################################
  ## The check. `alarm` mails only when something is wrong; `heartbeat`
  ## always mails. Exits 0 once it has mailed (or had nothing to say), so a
  ## stale target is reported by mail, not by a failed unit; a failure to
  ## mail fails the unit, and OnFailure= reports that.
  ##########################################################################
  offsiteCheck = pkgs.writeShellApplication {
    name = "offsite-check";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
      pkgs.gawk
      config.boot.zfs.package
    ];
    text = ''
      mode=''${1:?usage: offsite-check alarm|heartbeat}
      stale_hours=''${OFFSITE_STALE_HOURS:-${toString staleHours}}
      cap_percent=''${OFFSITE_CAP_PERCENT:-${toString capPercent}}
      key=''${OFFSITE_SSH_KEY:-${sshKey}}
      now=$(date +%s)
      limit=$((stale_hours * 3600))

      remote() {
        local host=$1
        shift
        ssh -n -i "$key" \
          -o BatchMode=yes -o ConnectTimeout=20 \
          -o StrictHostKeyChecking=yes -o UpdateHostKeys=no \
          "''${OFFSITE_SSH_HOST:-$host}" "$@"
      }

      newest() {
        local cmd=(zfs list -H -p -t snapshot -o creation -s creation -d 1 "$2")
        if [ "$1" != - ]; then remote "$1" "''${cmd[*]}"; else "''${cmd[@]}"; fi
      }

      fmt_age() { printf '%dd %02dh' $(($1 / 86400)) $(($1 % 86400 / 3600)); }

      problems=0
      worst=-1
      worst_name=
      table=$(printf '%-12s %-45s %-17s %-9s %s' TARGET DATASET NEWEST AGE STATUS)

      while IFS=$'\t' read -r name host dataset; do
        where=$dataset
        [ "$host" != - ] && where="''${host#*@}:$dataset"
        if ! out=$(newest "$host" "$dataset" 2>&1); then
          status="ERROR: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
          newest_s=- age_s=-
          problems=$((problems + 1))
          worst=-2 worst_name=$name
        else
          created=$(printf '%s\n' "$out" | tail -n 1)
          if [ -z "$created" ]; then
            status="STALE: no snapshots"
            newest_s=- age_s=-
            problems=$((problems + 1))
            worst=-2 worst_name=$name
          else
            age=$((now - created))
            newest_s=$(date -d "@$created" '+%Y-%m-%d %H:%M')
            age_s=$(fmt_age "$age")
            if [ "$age" -gt "$limit" ]; then
              status="STALE: over ''${stale_hours}h"
              problems=$((problems + 1))
            else
              status=ok
            fi
            if [ "$worst" -ge -1 ] && [ "$age" -gt "$worst" ]; then
              worst=$age worst_name=$name
            fi
          fi
        fi
        table+=$'\n'$(printf '%-12s %-45s %-17s %-9s %s' "$name" "$where" "$newest_s" "$age_s" "$status")
      done < ${targetsFile}

      pools=
      while IFS=$'\t' read -r host pool; do
        if ! cap=$(remote "$host" zpool list -H -p -o capacity "$pool" 2>&1); then
          line="ERROR: $(printf '%s' "$cap" | tr '\n' ' ' | cut -c1-120)"
          problems=$((problems + 1))
        elif [ "$cap" -ge "$cap_percent" ]; then
          line="''${cap}% FULL: at or over ''${cap_percent}%"
          problems=$((problems + 1))
        else
          line="''${cap}% ok"
        fi
        pools+=$(printf '%-12s %s' "''${host#*@}:$pool" "$line")$'\n'
      done < ${poolsFile}

      if [ "$worst" -eq -2 ]; then
        worst_s="$worst_name unreadable or empty"
      elif [ "$worst" -ge 0 ]; then
        worst_s="worst $(fmt_age "$worst") ($worst_name)"
      else
        worst_s="no readable targets"
      fi

      case $mode in
        alarm)
          [ "$problems" -eq 0 ] && { echo "offsite: all fresh, $worst_s"; exit 0; }
          subject="gir offsite STALE: $worst_s, $problems problem(s)"
          ;;
        heartbeat)
          if [ "$problems" -eq 0 ]; then
            subject="gir offsite freshness: all fresh, $worst_s"
          else
            subject="gir offsite freshness: $problems problem(s), $worst_s"
          fi
          ;;
        *) echo "unknown mode: $mode" >&2; exit 2 ;;
      esac

      body=$(
        echo "Offsite copies as of $(date '+%Y-%m-%d %H:%M %Z'), threshold ''${stale_hours}h."
        echo
        echo "$table"
        echo
        echo "Pool capacity (alarm at ''${cap_percent}%):"
        printf '%s' "$pools"
        echo
        echo "From offsite-check ($mode) on $(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)."
        echo "See gir-nix modules/offsite-alarm.nix and ~/p/gir docs/adr/0004."
      )

      mail=$(printf 'To: root\nSubject: %s\n\n%s\n' "$subject" "$body")
      if [ -n "''${OFFSITE_DRY_RUN:-}" ]; then
        printf '%s\n' "$mail"
      else
        printf '%s\n' "$mail" | /run/wrappers/bin/sendmail -t -oi
        echo "offsite: mailed root: $subject"
      fi
    '';
  };

  # Shared by both units: the syncoid user, a plain hardening set that still
  # reaches the key, /dev/zfs, /etc/ssh and the postfix maildrop.
  checkService = mode: description: {
    inherit description;
    after = [ "network-online.target" "zfs.target" ];
    wants = [ "network-online.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "syncoid";
      Group = "syncoid";
      ExecStart = "${offsiteCheck}/bin/offsite-check ${mode}";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ "/var/lib/postfix/queue/maildrop" ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictRealtime = true;
      LockPersonality = true;
      # Not NoNewPrivileges: sendmail is a setgid wrapper (see header).
    };
  };
  ##########################################################################
  ## notify-failure@<unit>: mail root the status and journal tail of a unit
  ## that failed. Runs as root so it can read any unit's journal.
  ##########################################################################
  notifyFailure = {
    description = "Mail root that %i failed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "notify-failure" ''
        unit=$1
        {
          printf 'To: root\nSubject: gir: %s failed\n\n' "$unit"
          ${pkgs.systemd}/bin/systemctl status --no-pager --full "$unit" 2>&1
          printf '\n--- journal, last 80 lines ---\n'
          ${pkgs.systemd}/bin/journalctl --no-pager -n 80 -u "$unit" 2>&1
        } | /run/wrappers/bin/sendmail -t -oi
      ''} %i";
    };
  };

in
{
  systemd.timers.offsite-staleness = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 09:00:00";
      Persistent = true;
    };
  };

  systemd.timers.offsite-freshness-heartbeat = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon *-*-* 07:30:00";
      Persistent = true;
    };
  };

  # Decision 7: every syncoid-* unit mails as soon as it fails. The names are
  # the module's: "syncoid-" + escapeUnitName of the commands attribute,
  # which is the identity for our names (asserted below).
  systemd.services = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "syncoid-${name}" { onFailure = [ "notify-failure@%n.service" ]; }
  ) config.services.syncoid.commands // {
    "notify-failure@" = notifyFailure;
    offsite-staleness = checkService "alarm" "Offsite staleness alarm: mail if any r2d2 copy is over ${toString staleHours} h old";
    offsite-freshness-heartbeat = checkService "heartbeat" "Offsite freshness heartbeat: weekly table of every offsite copy's age";
  };

  # On PATH for manual and forced-stale runs (header).
  environment.systemPackages = [ offsiteCheck ];

  assertions = [
    {
      assertion = lib.all (n: builtins.match "[a-zA-Z0-9_.-]+" n != null) (
        lib.attrNames config.services.syncoid.commands
      );
      message = "offsite-alarm.nix: a syncoid command name needs unit-name escaping; the OnFailure= wiring assumes it does not.";
    }
  ];
}
