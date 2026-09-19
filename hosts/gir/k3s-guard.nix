# Ticket 13: refuse to build a configuration that would upgrade, re-key or
# convert gir's live single-node k3s cluster. The upstream module ships none of
# these checks. Each hazard is from ticket 03.
{ config, lib, pkgs, nixpkgs-k3s-1344, ... }:

let
  cfg = config.services.k3s;
  pinned = nixpkgs-k3s-1344.legacyPackages.${pkgs.stdenv.hostPlatform.system}.k3s_1_34;
in
{
  assertions = lib.optionals cfg.enable [
    {
      # The module default is pkgs.k3s (1.35.7); 26.05's k3s_1_34 is 1.34.10.
      assertion = cfg.package.version == "1.34.4+k3s1" && cfg.package.outPath == pinned.outPath;
      message = "k3s-guard: services.k3s.package must be the pinned 1.34.4+k3s1 from nixpkgs dc68ac73 (pkgs.k3s_1_34_4), got ${cfg.package.name}.";
    }
    {
      # On a SQLite (kine) single node this requests an irreversible etcd conversion.
      assertion = !cfg.clusterInit;
      message = "k3s-guard: services.k3s.clusterInit must stay false; gir's datastore is SQLite.";
    }
    {
      assertion = cfg.role == "server" && !cfg.disableAgent && cfg.serverAddr == "";
      message = "k3s-guard: gir is a standalone server with its agent; role, disableAgent and serverAddr must stay at their defaults.";
    }
    {
      # The cluster token already lives in /var/lib/rancher/k3s/server/token; a
      # different one rewrites bootstrap encryption, and `token` lands in the store.
      assertion = cfg.token == "" && cfg.tokenFile == null
        && cfg.agentToken == "" && cfg.agentTokenFile == null;
      message = "k3s-guard: do not set token, tokenFile, agentToken or agentTokenFile.";
    }
    {
      # These emit tmpfiles L+ rules, which replace files in a live, Flux-managed cluster.
      assertion = cfg.manifests == { } && cfg.autoDeployCharts == { }
        && cfg.charts == { } && cfg.images == [ ];
      message = "k3s-guard: manifests, autoDeployCharts, charts and images must stay empty; Flux owns cluster state.";
    }
    {
      assertion = cfg.disable == [ ];
      message = "k3s-guard: services.k3s.disable must stay empty; /etc/rancher/k3s/config.yaml is the single source of truth.";
    }
  ];
}
