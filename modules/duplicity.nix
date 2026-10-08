# Offsite duplicity archives to r2d2 -- gir iss `offsite-duplicity-units`
# (af03d68), the duplicity half of `restore-offsite-replication` (8933937,
# decisions 3 and 6-10), map `5c80d58` (Offsite backup). ADR 0002 in ~/p/gir
# (docs/adr/0002-host-secrets-offsite-encrypted-to-escrowed-key.md) records
# why host secrets now leave the box.
#
# Two archives, each a root oneshot on its own timer:
#
#   duplicity-lh            /stuff/pr0n/local-homemade -> r2d2 /mmm/backups/gir/lh
#                           The 2017 chain, carried on: incremental only,
#                           encrypted to D65ECDFD. Was the last line of
#                           myers' ~/.local/bin/remotebackup cron until the
#                           NixOS cutover dropped the crontab (last increment
#                           20260920T040818Z).
#   duplicity-host-secrets  /etc/gir-secrets, /srv/vaultwarden and a dump of
#                           every k8s Secret -> r2d2 /mmm/backups/gir/host-secrets
#                           New. Encrypted to the dedicated host-secrets key
#                           1396F8FE, whose private half is only in 1Password.
#                           Weekly full, daily incrementals, keep 3 fulls.
#
# Schedule: 02:30 nightly, an hour after syncoid's 01:30. Neither overlaps
# syncoid-vital: that unit is Type=simple, so After= can't order against it,
# and each script instead waits while it is active (an incremental takes
# minutes; the 2026-10-07 resend took 22 h). host-secrets is ordered After=
# lh, so the two never share the uplink either. Each unit mails root through
# notify-failure@ (offsite-alarm.nix) the moment it fails, and each archive's
# newest manifest on r2d2 is in the 48 h staleness alarm and the Monday
# heartbeat (the `gir.offsite.duplicityTargets` set below, ADR 0004).
#
# Secrets (ticket 01 decision 3, ticket af03d68's prerequisites comment): set
# up by hand with ~/p/gir/setup-duplicity-secrets.sh, never in git or the
# store.
#   GNUPGHOME=/etc/gir-secrets/gnupg (root 0700): D65ECDFD secret+public, and
#     the host-secrets PUBLIC key; both ultimately trusted.
#   /etc/gir-secrets/duplicity-lh-passphrase (root 0600): unlocks D65ECDFD.
#     Loaded with LoadCredential= and exported as PASSPHRASE inside the
#     script, so it never appears in a unit file, the environment of the unit
#     or the store.
#
# ssh: duplicity's default sftp backend is paramiko. It reads the key named
# by -oIdentityFile in --ssh-options and the pinned r2d2 host key in
# /etc/ssh/ssh_known_hosts (syncoid.nix); an unknown host key would prompt on
# a closed stdin and fail. The key is syncoid's /var/lib/syncoid/remotebackup,
# reused read-only: root reads it through the 0600 mode, and these units
# don't run in the syncoid module's sandbox, so a copy would only be a second
# key file to keep in step. Checked 2026-10-08 as myers: duplicity 3.0.7 over
# paramiko with that known_hosts lists the lh chain on r2d2.
#
# Cache: duplicity keeps decrypted manifests and signatures in --archive-dir,
# /var/cache/duplicity/<name> (CacheDirectory=, on rpool/nixos/root). It must
# persist. host-secrets cannot rebuild it from r2d2 (gir has no private key
# for that archive); losing it forces the next run to fail until the cache is
# rebuilt with the escrowed key, or the archive is restarted with a full. lh
# can rebuild its cache (D65ECDFD is on gir) at the cost of fetching ~1600
# manifests; the hand-over seeds it from myers' ~/.cache/duplicity instead.
#
# Manual runs:
#   systemctl start duplicity-lh
#   systemctl start duplicity-host-secrets
#   journalctl -u duplicity-lh -u duplicity-host-secrets -e
{ config, lib, pkgs, ... }:

let
  r2d2 = {
    user = "remotebackup";
    host = "r2d2.monoloco.net";
  };
  baseDir = "/mmm/backups/gir";
  url = name: "sftp://${r2d2.user}@${r2d2.host}/${baseDir}/${name}";
  sshKey = config.services.syncoid.sshKey;
  cacheDir = "/var/cache/duplicity";
  gnupgHome = "/etc/gir-secrets/gnupg";

  # D65ECDFD, the lh archive's key since 2017.
  lhKey = "FDCF88A44E8A0EC673D6D3F863794C94D65ECDFD";
  # The host-secrets key (~/p/gir/keys/gir-host-secrets.fpr), public only.
  hostSecretsKey = "1396F8FE6EA81C412D15070E85C5B281181BA1CB";

  zfs = config.boot.zfs.package;
  k3s = config.services.k3s.package;

  commonArgs = [
    "--archive-dir"
    cacheDir
    "--ssh-options=-oIdentityFile=${sshKey}"
    "--verbosity"
    "notice"
  ];

  # Shared by both scripts: don't share the uplink with vital's push.
  waitForVital = ''
    if systemctl is-active --quiet syncoid-vital.service; then
      echo "syncoid-vital is running; waiting for it to finish"
      while systemctl is-active --quiet syncoid-vital.service; do sleep 300; done
      echo "syncoid-vital finished"
    fi
  '';

  ##########################################################################
  ## lh: the 2017 chain, incremental only.
  ##########################################################################
  lhScript = pkgs.writeShellApplication {
    name = "duplicity-lh";
    runtimeInputs = [ pkgs.duplicity pkgs.coreutils pkgs.systemd ];
    text = ''
      ${waitForVital}
      PASSPHRASE=$(cat "$CREDENTIALS_DIRECTORY/passphrase")
      export PASSPHRASE

      # `incremental`, not the implied action: if the cache has lost the
      # chain, this fails instead of starting a new full of the whole tree.
      # Whether to start a fresh full is ticket verify-duplicity-lh-chain
      # (5cdf4a7), not this unit's call.
      #
      # --allow-source-mismatch, as the cron had it: gir has been rebuilt
      # under this chain before. The 2017 full records Hostname
      # gir.motherbrain.local, the increments since record gir, and the NixOS
      # rebuild is the newest host change. Without the flag duplicity refuses
      # a chain whose recorded host differs from this one.
      duplicity incremental \
        --name lh \
        ${lib.escapeShellArgs commonArgs} \
        --encrypt-key ${lhKey} \
        --allow-source-mismatch \
        /stuff/pr0n/local-homemade \
        ${url "lh"}
    '';
  };

  ##########################################################################
  ## host-secrets: a staged tree of snapshot mounts plus a k8s Secret dump.
  ##
  ## Several roots, one archive: duplicity backs up one source directory, so
  ## the choice was an --include list over / or a staged directory. Staged,
  ## because the staged tree can be read from ZFS snapshots: each dataset's
  ## newest sanoid snapshot is mounted read-only under the stage. Vaultwarden
  ## runs in k8s with its SQLite database live in /srv/vaultwarden, and a
  ## file-level read of a live WAL database can tear; the 00:00 snapshot is
  ## crash-consistent. An --include list over / would read the live files.
  ## The archive's paths are also short and stable (etc-gir-secrets/...,
  ## srv-vaultwarden/..., k8s-secrets.yaml) whatever the host's layout.
  ##
  ## The stage is in RuntimeDirectory= (tmpfs, root 0700), the mounts live in
  ## the unit's own mount namespace (PrivateMounts=), and the k8s dump never
  ## touches disk outside the archive (ticket af03d68, k3s scope decision:
  ## dump Secrets, don't archive rpool/srv/k3s-nixos).
  ##########################################################################
  snapshotSources = {
    "etc-gir-secrets" = "rpool/srv/secrets";
    "srv-vaultwarden" = "rpool/srv/vaultwarden";
  };
  # Fail rather than archive stale content when sanoid has stopped.
  maxSnapshotAgeHours = 48;

  hostSecretsScript = pkgs.writeShellApplication {
    name = "duplicity-host-secrets";
    runtimeInputs = [
      pkgs.duplicity
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.util-linux
      pkgs.systemd
      zfs
      k3s
    ];
    text = ''
      ${waitForVital}
      stage=$RUNTIME_DIRECTORY/stage
      mounted=()
      cleanup() {
        for m in "''${mounted[@]}"; do umount "$m" || true; done
        rm -f "$stage/k8s-secrets.yaml"
      }
      trap cleanup EXIT
      umask 077
      mkdir -p "$stage"
      now=$(date +%s)

      mount_newest() {
        local dir=$1 dataset=$2 line snap created
        line=$(zfs list -H -p -t snapshot -o name,creation -s creation -d 1 "$dataset" | tail -n 1)
        if [ -z "$line" ]; then
          echo "no snapshots of $dataset" >&2
          return 1
        fi
        snap=''${line%%$'\t'*}
        created=''${line##*$'\t'}
        if [ $((now - created)) -gt $((${toString maxSnapshotAgeHours} * 3600)) ]; then
          echo "newest snapshot of $dataset is over ${toString maxSnapshotAgeHours} h old ($snap); is sanoid running?" >&2
          return 1
        fi
        mkdir -p "$stage/$dir"
        mount.zfs -o ro "$snap" "$stage/$dir"
        mounted+=("$stage/$dir")
        echo "$dir <- $snap"
      }

      ${lib.concatStrings (
        lib.mapAttrsToList (dir: ds: "mount_newest ${dir} ${ds}\n") snapshotSources
      )}
      # Every Secret in the cluster: the sealed-secrets private keys and the
      # Secrets created outside git. Logged by count only.
      k3s kubectl get secret -A -o yaml > "$stage/k8s-secrets.yaml"
      echo "k8s-secrets.yaml: $(grep -c '^  kind: Secret$' "$stage/k8s-secrets.yaml" || true) Secrets"

      # Encrypt-only, no --sign-key: gir has no private key for this archive.
      # An empty PASSPHRASE tells duplicity none is needed, rather than
      # leaving it to probe the agent for one.
      export PASSPHRASE=

      duplicity backup \
        --name host-secrets \
        ${lib.escapeShellArgs commonArgs} \
        --encrypt-key ${hostSecretsKey} \
        --full-if-older-than 7D \
        "$stage" \
        ${url "host-secrets"}

      duplicity remove-all-but-n-full \
        --name host-secrets \
        ${lib.escapeShellArgs commonArgs} \
        --force \
        3 ${url "host-secrets"}
    '';
  };

  ##########################################################################
  ## The units.
  ##########################################################################
  service = description: script: {
    inherit description;
    after = [ "network-online.target" "zfs.target" ];
    wants = [ "network-online.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    environment.GNUPGHOME = gnupgHome;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${script}/bin/${script.name}";
      CacheDirectory = "duplicity";
      CacheDirectoryMode = "0700";
      # Hides /root and /run/user too, so gpg puts its agent socket in
      # GNUPGHOME rather than wherever an interactive root session left one.
      ProtectHome = true;
      PrivateTmp = true;
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  timer = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      Persistent = true;
    };
  };
in
{
  systemd.services.duplicity-lh = lib.mkMerge [
    (service "Duplicity: lh archive to r2d2 (incremental)" lhScript)
    {
      serviceConfig = {
      LoadCredential = [ "passphrase:/etc/gir-secrets/duplicity-lh-passphrase" ];
      # The cron raised it (`ulimit -n 4096`): the chain is ~1600 sets long.
      LimitNOFILE = 4096;
      };
    }
  ];

  systemd.services.duplicity-host-secrets = lib.mkMerge [
    (service "Duplicity: host-secrets archive to r2d2 (weekly full)" hostSecretsScript)
    {
      after = [ "duplicity-lh.service" ];
      serviceConfig = {
        RuntimeDirectory = "duplicity-host-secrets";
        RuntimeDirectoryMode = "0700";
        PrivateMounts = true;
      };
    }
  ];

  systemd.timers.duplicity-lh = timer;
  systemd.timers.duplicity-host-secrets = timer;

  # ADR 0004: each archive's newest manifest joins the staleness alarm.
  gir.offsite.duplicityTargets = {
    lh = { host = "${r2d2.user}@${r2d2.host}"; dir = "${baseDir}/lh"; };
    host-secrets = { host = "${r2d2.user}@${r2d2.host}"; dir = "${baseDir}/host-secrets"; };
  };
}
