# gir: PostgreSQL 18, bare metal.
#
# Ticket 05 ("keep natively, bare metal"), ticket 24 module 5, ticket 07 (the
# state dataset). Parity target is the *live* Ubuntu cluster as read on
# 2026-09-19:
#
#   /usr/lib/postgresql/18/bin/postgres -D /var/lib/postgresql/18/main \
#       -c config_file=/etc/postgresql/18/main/postgresql.conf
#   psql (PostgreSQL) 18.6 (Ubuntu 18.6-1.pgdg22.04+2)   <- PGDG, not Ubuntu's
#   listen_addresses = 'localhost,192.168.69.1'   (ss: 127.0.0.1:5432, 192.168.69.1:5432)
#
# Verified against the pinned nixpkgs (flake input `nixpkgs`,
# c3eea5b2156db11c7eeeada3dc737711255b253e) on 2026-09-19:
#
#   postgresql_18.version                       = 18.6   (matches the host)
#   postgresql18Packages.pgvector.version       = 0.8.2  (matches immich_v2's installed 0.8.2)
#   postgresql18Packages.vectorchord.version    = 1.1.1  (matches immich_v2's installed vchord 1.1.1)
#
# The attribute is `vectorchord`; the SQL extension it installs is named
# `vchord` and its shared library is `vchord` (ticket 05, finding 1).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # The ZFS dataset `rpool/srv/postgresql`, mounted here and *shared with the
  # Ubuntu install* (ticket 07 manifest). Fail-closed wiring hangs off this.
  stateDir = "/var/lib/postgresql";

  # PGDATA.
  #
  # NOTE, and please read before "correcting" this to `${stateDir}/18`:
  # ticket 05 records that on NixOS the data directory is
  # `/var/lib/postgresql/18` "with no /main". That is the NixOS *default*
  # (`/var/lib/postgresql/${package.psqlSchema}`), and it is not where gir's
  # data lives. The dataset is shared with Ubuntu, whose PGDATA is
  # `/var/lib/postgresql/18/main` (Debian layout, confirmed live in the
  # postmaster's own argv and in `data_directory` in
  # /etc/postgresql/18/main/postgresql.conf). `/var/lib/postgresql/18` contains
  # exactly one entry: `main/`.
  #
  # Pointing NixOS at `/var/lib/postgresql/18` would find no PG_VERSION there
  # and the module's preStart would silently run `initdb`, standing up an empty
  # cluster next to the real one -- immich would come up with no data. So the
  # data directory is set to the live path. If the intent is instead to *move*
  # PGDATA during Window A, this line changes and the move becomes a step in
  # ticket 22 -- but then Ubuntu can no longer start the cluster, so the
  # fallback is lost. Keeping the Debian path is what makes the fallback work.
  dataDir = "${stateDir}/18/main";
in
{
  services.postgresql = {
    enable = true;

    # Explicit, and it must be. `services.postgresql.package` defaults from
    # `system.stateVersion`: at 26.05 (>= 25.11) the default is
    # **postgresql_17**, which would refuse to start on an 18 data directory.
    package = pkgs.postgresql_18;

    inherit dataDir;

    # `extraPlugins` was renamed to `extensions` in this nixpkgs
    # (mkRenamedOptionModule in nixos/modules/services/databases/postgresql.nix);
    # the old name still works but warns. These feed
    # `package.withPackages`, so the .so/.control/.sql files land in the
    # postgres package's own extension dir.
    #
    # immich_v2 is the only database that needs them: vector 0.8.2 +
    # vchord 1.1.1 (ticket 01 -- "the one real parity risk"). bitmagnet's
    # btree_gin/pg_trgm and the cube/earthdistance/unaccent/uuid-ossp set are
    # all contrib, shipped with postgresql_18 itself.
    extensions = ps: with ps; [
      pgvector
      vectorchord
    ];

    settings = {
      # mkForce: the module sets `listen_addresses` unconditionally to "*" (if
      # enableTCPIP) or "localhost", with no mkDefault, so a plain definition
      # here is a merge conflict. `enableTCPIP = true` would widen the bind to
      # every interface, which is not what the host does -- postgres listens on
      # loopback and the 192.168.69.1 secondary only (ticket 05: this is also
      # why the unit must be ordered after network-online.target).
      listen_addresses = lib.mkForce "localhost,192.168.69.1";

      port = 5432;
      max_connections = 200;

      # VectorChord must be preloaded; nixpkgs' own vectorchord test uses
      # exactly `shared_preload_libraries = 'vchord'`.
      #
      # Checked 2026-09-20, closing the TODO that stood here since the port:
      # /var/lib/postgresql/18/main/postgresql.auto.conf contains exactly one
      # line, `shared_preload_libraries = 'vchord'` -- the same value set here.
      # So ALTER SYSTEM is NOT overriding anything in this file. Worth rechecking
      # if a future setting mysteriously fails to take: auto.conf is read AFTER
      # postgresql.conf, it travels with the data dataset, and it is 0700 root so
      # only a sudo read will show it.
      shared_preload_libraries = "vchord";

      # Verbatim from /etc/postgresql/18/main/postgresql.conf.
      log_line_prefix = "%m [%p] %q%u@%d ";
      log_timezone = "America/New_York";
      timezone = "America/New_York";
      datestyle = "iso, mdy";
      # Ubuntu sets these four to en_US.UTF-8. They are NOT carried, deliberately:
      # nixpkgs' postgresql-configfile-check runs postgres in a sandbox with no locale
      # archive, so any non-C locale fails the build; and at runtime a missing archive
      # would be a FATAL at first boot, which there is no soak to catch. For en_US the
      # difference is cosmetic (same '.' decimal separator, same '$', English messages).
      # lc_collate/lc_ctype are NOT settable here — they are baked into the cluster by
      # initdb and travel with the shared dataset, which is what index correctness rides on.
      lc_messages = "C";
      lc_monetary = "C";
      lc_numeric = "C";
      lc_time = "C";
      default_text_search_config = "pg_catalog.english";

      # ssl: CARRIED after all. The survey behind the note below looked for clients
      # setting DB_SSL or an explicit sslmode and found none -- but it could not have
      # found ext-postgres-operator, which is Go and uses lib/pq, whose default
      # sslmode is `require` (libpq's is `prefer`, which silently falls back). It
      # demands TLS while configuring nothing, so on the first NixOS boot it
      # crash-looped with `pq: SSL is not enabled on the server` (118 restarts,
      # 2026-09-20). Debian's snakeoil pair had been covering for it invisibly.
      #
      # postgresql-ssl-cert.service below generates the equivalent self-signed pair.
      # NOT into /etc/gir-secrets, although ticket 07 suggested it: that directory is
      # 0700 root because it holds the password hashes and the SSH host keys, and the
      # postgres user cannot traverse it -- postgres died with `could not load server
      # certificate file: Permission denied` on 2026-09-20 14:13 for exactly that
      # reason, whatever the mode on the subdirectory. It lives on the postgres data
      # dataset instead, which postgres owns outright. This is
      # encryption without authentication, exactly as the snakeoil cert was on
      # Ubuntu -- no client verifies it, and restoring parity is the point.
      ssl = true;
      ssl_cert_file = "/var/lib/postgresql/ssl/server.crt";
      ssl_key_file = "/var/lib/postgresql/ssl/server.key";

      ## Memory ------------------------------------------------------------
      # Nothing memory-related was set here or on Ubuntu, so a 123 GiB host serving
      # a 176 GB and a 139 GB database ran on stock defaults: shared_buffers 128 MB,
      # work_mem 4 MB, maintenance_work_mem 64 MB, effective_cache_size 4 GB. The
      # 2026-09-20 collation rebuild made the cost visible -- every sort spilled.
      #
      # All four below are reloadable; none needs a restart.

      # Allocates NOTHING. It is only what the planner BELIEVES is cached, and at
      # the 4 GB default on a box with a 24 GiB ARC plus page cache the planner
      # systematically underestimates caching and tips toward sequential scans.
      # This is the highest-value line here and the only one with no downside.
      effective_cache_size = "48GB";

      # Index builds, VACUUM, REINDEX. Per maintenance operation, not per backend.
      maintenance_work_mem = "2GB";

      # MUST be set explicitly. It defaults to -1, meaning "use maintenance_work_mem",
      # and there are 3 autovacuum workers -- so the line above would otherwise
      # silently authorise 6 GB of autovacuum. This caps it at 768 MB.
      autovacuum_work_mem = "256MB";

      # The dangerous one: per sort/hash NODE per CONNECTION, not per query. With
      # max_connections = 200 and several such nodes in a plan, a large value is
      # multiplied by both. 32 MB is 8x the default and still bounded at a few GB
      # in the worst case.
      work_mem = "32MB";

      # shared_buffers is deliberately LEFT AT THE DEFAULT. On this host every page
      # it caches is also cached in ARC, so raising it pays for the same data twice
      # against a deliberately capped 24 GiB ARC -- and unlike the four above it
      # needs a restart. Let ARC do the caching.

      # Deltas from the Ubuntu config, deliberately not carried:
      #
      #   cluster_name = '18/main', external_pid_file, hba_file, ident_file
      #     Debian multi-cluster plumbing; NixOS owns these paths itself.
      #   shared_buffers/max_wal_size/min_wal_size/dynamic_shared_memory_type
      #     all at PostgreSQL's own defaults on the host; left to the defaults.
    };

    # false is the NixOS default and is set explicitly here because it is a
    # *delta from the host*, not an oversight: PGDG's build ships LLVM JIT and
    # the host leaves `jit` at PostgreSQL's default (on), while this module sets
    # `jit = off`. Flipping this to true restores host behaviour at the cost of
    # building/downloading the JIT-enabled postgres and rebuilding both
    # extensions against it -- weigh that against the Window B budget.
    enableJIT = false;

    # Exact parity with /etc/postgresql/18/main/pg_hba.conf (read from
    # logs/privileged-audit-20260916-072444.txt; the file itself is 0640
    # postgres:postgres). mkForce replaces the module's default block rather
    # than prepending to it -- the default is a near-subset of these lines and
    # keeping both would leave a duplicate `local all all peer`.
    #
    # The 10.0.0.1/8 line is verbatim from the host (an odd but harmless way of
    # writing 10.0.0.0/8); it is carried rather than "fixed" so the cutover
    # changes nothing a client can observe.
    authentication = lib.mkForce ''
      # Generated by modules/postgresql.nix -- verbatim parity with Ubuntu's
      # /etc/postgresql/18/main/pg_hba.conf as of 2026-09-16.
      local   all             postgres                                peer
      local   all             all                                     peer
      host    all             all             127.0.0.1/32            md5
      host    all             all             10.0.0.1/8              md5
      host    all             all             192.168.69.0/24         md5
      host    all             all             ::1/128                 md5
      local   replication     all                                     peer
      host    replication     all             127.0.0.1/32            md5
      host    replication     all             ::1/128                 md5
    '';
  };

  # UID/GID parity. The dataset is shared and every file under it is owned by
  # 110:119; NixOS' static ids are postgres=71/71, which would make PGDATA
  # unreadable. Overriding `ids.uids` rather than `users.users.postgres.uid`
  # keeps this compatible with users.nix (ticket 24 module 2): the postgresql
  # module derives the uid from `config.ids.uids.postgres`, so an equal
  # definition there merges instead of conflicting. If users.nix pins these,
  # this block can simply be deleted.
  ids.uids.postgres = lib.mkForce 110;
  ids.gids.postgres = lib.mkForce 119;

  systemd.services.postgresql = {
    # Ticket 05: postgres binds 192.168.69.1 explicitly, so it cannot start
    # before that address exists. (The module only orders after network.target;
    # list-valued definitions concatenate.)
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Fail-closed on the shared dataset (ticket 07, rule 9): refuse to start
    # rather than write into an empty directory if rpool/srv/postgresql is not
    # mounted. The module already emits RequiresMountsFor=<dataDir>; a list
    # value here concatenates with it, so both paths are required. Naming the
    # dataset mountpoint explicitly keeps the guard correct even if dataDir
    # moves.
    unitConfig.RequiresMountsFor = [ stateDir ];
  };

  # A version skew here fails at *query* time, not at startup (ticket 01), so
  # catch it at evaluation time instead.
  assertions = [
    {
      assertion = lib.versions.major config.services.postgresql.package.version == "18";
      message = "gir: services.postgresql.package must be postgresql_18; the module default is 17 at stateVersion 26.05.";
    }
    {
      assertion = pkgs.postgresql18Packages.pgvector.version == "0.8.2";
      message = "gir: pgvector must be 0.8.2 to match immich_v2's installed extension (got ${pkgs.postgresql18Packages.pgvector.version}).";
    }
    {
      assertion = pkgs.postgresql18Packages.vectorchord.version == "1.1.1";
      message = "gir: vectorchord must be 1.1.1 to match immich_v2's installed vchord (got ${pkgs.postgresql18Packages.vectorchord.version}).";
    }
  ];

  # Post-cutover check, from ticket 05 finding 1 -- run it after the first
  # NixOS boot and after any channel bump:
  #   SELECT name, default_version, installed_version
  #     FROM pg_available_extensions
  #    WHERE installed_version IS DISTINCT FROM default_version;

  ############################################################################
  ## The snakeoil equivalent
  ##
  ## Debian's ssl-cert package ships /etc/ssl/certs/ssl-cert-snakeoil.pem and
  ## regenerates it on install; NixOS has no such package, so the pair is made
  ## here. It lives under /var/lib/postgresql (rpool/srv/postgresql), which the
  ## postgres user owns and can traverse -- see the note by ssl_cert_file above
  ## for why /etc/gir-secrets does not work. Generated once rather than on every
  ## activation: a new key on each switch would break every pooled connection.
  ############################################################################
  systemd.services.postgresql-ssl-cert = {
    description = "Generate PostgreSQL's self-signed certificate if absent";
    wantedBy = [ "multi-user.target" ];
    before = [ "postgresql.service" ];
    requiredBy = [ "postgresql.service" ];
    # The pair lives on the postgres data dataset, so it must be mounted first.
    unitConfig.RequiresMountsFor = [ "/var/lib/postgresql" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.openssl pkgs.coreutils ];
    script = ''
      set -euo pipefail
      dir=/var/lib/postgresql/ssl
      install -d -o postgres -g postgres -m 0700 "$dir"

      if [ -f "$dir/server.crt" ] && [ -f "$dir/server.key" ] \
         && openssl x509 -in "$dir/server.crt" -noout -checkend 2592000 >/dev/null 2>&1; then
        echo "certificate present and valid for at least 30 more days"
        exit 0
      fi

      echo "generating a self-signed certificate for postgres"
      openssl req -new -x509 -days 3650 -nodes -text \
        -subj "/CN=gir" \
        -addext "subjectAltName=DNS:gir,DNS:localhost,IP:127.0.0.1,IP:192.168.42.8" \
        -out "$dir/server.crt.new" \
        -keyout "$dir/server.key.new"

      # postgres refuses to start if the key is group- or world-readable.
      chown postgres:postgres "$dir/server.crt.new" "$dir/server.key.new"
      chmod 0644 "$dir/server.crt.new"
      chmod 0600 "$dir/server.key.new"
      mv "$dir/server.crt.new" "$dir/server.crt"
      mv "$dir/server.key.new" "$dir/server.key"
      echo "wrote $dir/server.crt and $dir/server.key"

      # Writing the files is not the same as postgres being able to READ them:
      # every directory on the path needs +x for the postgres user, which is how
      # /etc/gir-secrets (0700 root) broke this on 2026-09-20. Prove it here, so a
      # bad path fails in this unit instead of in postgres three restarts later.
      for f in "$dir/server.crt" "$dir/server.key"; do
        if ! ${pkgs.sudo}/bin/sudo -u postgres test -r "$f"; then
          echo "FATAL: postgres cannot read $f -- check +x on every parent directory" >&2
          exit 1
        fi
      done
      echo "verified: the postgres user can read both files"
    '';
  };

}
