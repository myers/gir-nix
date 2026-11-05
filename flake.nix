{
  description = "gir: NixOS host configuration (Ubuntu → NixOS migration)";

  inputs = {
    # nixos-26.05 channel head, 2026-09-14 (ticket 02). Pin the channel branch,
    # not release-26.05, which is not necessarily built.
    nixpkgs.url = "github:NixOS/nixpkgs/7dcdd87373d72e7a2173e4db02e20d3d7f495cfd";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      testPkgs = import nixpkgs { inherit system; };
    in
    {
      nixosConfigurations.gir = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/gir/configuration.nix
          ./hosts/gir/k3s-guard.nix
        ];
      };

      # Ticket 13: these gate Window B. etcd is skipped on purpose: it exercises
      # clusterInit, which gir must never set.
      checks.${system} = {
        k3s-single-node = testPkgs.nixosTests.k3s.single-node.k3s_1_35;
        k3s-configuration = testPkgs.nixosTests.k3s.configuration.k3s_1_35;
      };
    };
}
