# gir: Plex Media Server, bare metal, pinned to the host's exact build.
#
# Ticket 05 ("keep natively, overlay-pinned to 1.43.4.10903"), ticket 24
# module 6, ticket 07 (the state dataset).
#
# Why the overlay exists (ticket 05, finding 2): nixpkgs at the pinned revision
# ships plexRaw 1.43.3.10861-07dfddaeb, while gir runs
# 1.43.4.10903-e5521bd8c (`dpkg -l plexmediaserver`, 2026-09-19). Taking the
# nixpkgs default is a **downgrade**, and Plex's database does not go that
# direction. `pkgs.plex.override { version = ...; }` does not exist: plexRaw is
# a `stdenv.mkDerivation rec` whose `src` interpolates its own `version`, so
# overriding only one of them silently fetches the old .deb. Both are set here
# via overrideAttrs, on plexRaw -- the `plex` FHS userenv and the NixOS module
# pick the change up automatically (`inherit (plexRaw) version meta;`).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Exactly what dpkg reports on the host today:
  #   ii  plexmediaserver  1.43.4.10903-e5521bd8c  amd64
  version = "1.43.4.10903-e5521bd8c";

  # Fetched and verified on 2026-09-19 with
  #   nix store prefetch-file --hash-type sha256 \
  #     https://downloads.plex.tv/plex-media-server-new/1.43.4.10903-e5521bd8c/debian/plexmediaserver_1.43.4.10903-e5521bd8c_amd64.deb
  # and cross-checked with `dpkg-deb -f <store path> Package Version Architecture`
  # -> plexmediaserver / 1.43.4.10903-e5521bd8c / amd64.
  hash = "sha256-b2ocgzbXeeHyAVGmk0NJiEutb2pmsYorGJuW5Vw7Pts=";

  # The ZFS dataset `rpool/srv/plexmediaserver`, mounted here and shared with
  # the Ubuntu install unchanged (ticket 07 manifest). Fail-closed wiring hangs
  # off this path, not off dataDir.
  stateDir = "/var/lib/plexmediaserver";

  # NOT `stateDir` itself. nixpkgs' FHS wrapper exports
  #   PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR="$PLEX_DATADIR"
  # i.e. dataDir *is* the Application Support directory, whereas Ubuntu's unit
  # sets
  #   PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR=/var/lib/plexmediaserver/Library/Application Support
  # and the live tree confirms it: /var/lib/plexmediaserver/Library/ holds
  # "Application Support/", "Logs/" and "Plex Media Server/", with the real
  # server directory at
  #   /var/lib/plexmediaserver/Library/Application Support/Plex Media Server/
  # Setting dataDir to /var/lib/plexmediaserver would make Plex create a second,
  # empty "Plex Media Server/" one level up and come up as a brand-new server.
  dataDir = "${stateDir}/Library/Application Support";
in
{
  nixpkgs.overlays = [
    (final: prev: {
      plexRaw = prev.plexRaw.overrideAttrs (_: {
        inherit version;
        # gir is x86_64-linux (asserted below); the aarch64 branch of the
        # upstream `src` is intentionally not reproduced.
        src = prev.fetchurl {
          url = "https://downloads.plex.tv/plex-media-server-new/${version}/debian/plexmediaserver_${version}_amd64.deb";
          inherit hash;
        };
      });
    })
  ];

  # Plex is unfree (`lib.licenses.unfree`), so evaluation fails outright without
  # this -- verified: `error: Refusing to evaluate package
  # 'plexmediaserver-1.43.4.10903-e5521bd8c' ... because it has an unfree
  # license`. Scoped to Plex rather than a blanket `allowUnfree = true`. If
  # another module ever needs an unfree package, this predicate has to grow a
  # name rather than being defined twice -- two definitions of a function-valued
  # option do not merge.
  nixpkgs.config.allowUnfreePredicate = pkg: lib.elem (lib.getName pkg) [ "plexmediaserver" ];

  services.plex = {
    enable = true;
    inherit dataDir;

    # Ticket 14: the host firewall is off entirely, so there is nothing to
    # open. Explicit so that a later firewall decision has to revisit this.
    openFirewall = false;

    user = "plex";
    group = "plex";

    # Default is [ "*" ]; kept so hardware transcoding keeps working (the plex
    # account is in `video` on the host). Narrow to [ "/dev/dri/renderD128" ]
    # only with transcode testing.
    accelerationDevices = [ "*" ];
  };

  # UID/GID parity (ticket 05 §7 / ticket 24 module 2): the host's plex account
  # is 998:998 and every file on the shared dataset is owned by it, while
  # NixOS' static id is 193 and 997/998 sit inside the range NixOS hands out
  # dynamically -- the highest collision risk in the audit.
  #
  # Overriding `ids.uids` rather than `users.users.plex.uid` is deliberate: the
  # plex module defines `users.users.plex.uid = config.ids.uids.plex`, so an
  # equal definition in users.nix merges rather than conflicting. If users.nix
  # pins plex to 998 itself, this block can simply be deleted.
  ids.uids.plex = lib.mkForce 998;
  ids.gids.plex = lib.mkForce 998;

  # Host group membership to reproduce: video = plex,ollama (ollama is dropped).
  # listOf str, so this concatenates with whatever users.nix declares.
  users.users.plex.extraGroups = [ "video" ];

  systemd.services.plex = {
    # Ubuntu's unit is `After=network.target network-online.target`; the NixOS
    # module only orders after network.target. List values concatenate.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Fail-closed on the shared dataset (ticket 07, rule 9). Without this the
    # module's ExecStartPre happily `install -d`s a fresh, empty data directory
    # on top of an unmounted rpool/srv/plexmediaserver and Plex registers itself
    # as a new server -- the exact failure the mount guard exists to prevent.
    unitConfig.RequiresMountsFor = [ stateDir ];
  };

  assertions = [
    {
      assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
      message = "gir: modules/plex.nix pins the amd64 .deb; add the aarch64 branch before building elsewhere.";
    }
    {
      # Catches the overlay silently not applying -- e.g. if a future
      # `nixpkgs.pkgs` assignment in flake.nix bypasses nixpkgs.overlays. The
      # plex FHS userenv inherits its version from plexRaw.
      assertion = config.services.plex.package.version == version;
      message = "gir: plex must be pinned to ${version} (got ${config.services.plex.package.version}); nixpkgs' default is a downgrade from the running server.";
    }
  ];
}
