{
  description = "gir: NixOS host configuration (Ubuntu → NixOS migration)";

  inputs = {
    # nixos-26.05 channel head, 2026-09-14 (ticket 02). Pin the channel branch,
    # not release-26.05, which is not necessarily built.
    nixpkgs.url = "github:NixOS/nixpkgs/c3eea5b2156db11c7eeeada3dc737711255b253e";
    # The only nixpkgs revisions where k3s_1_34 is exactly 1.34.4+k3s1 (ticket 03).
    # Ticket 13: k3s is pinned from this input until a deliberate, separate k3s
    # upgrade after the soak, which also deletes this input.
    nixpkgs-k3s-1344.url = "github:NixOS/nixpkgs/dc68ac73f0fe99323cd0905a685f99ea8a073b48";
  };

  outputs = { self, nixpkgs, nixpkgs-k3s-1344, ... }:
    let
      system = "x86_64-linux";
      # Same overlay for the system and the VM tests, so they cannot diverge.
      testPkgs = import nixpkgs {
        inherit system;
        overlays = [ self.overlays.k3s-pin ];
      };
    in
    {
      # Ticket 13: upstream's derivation, cached, with its runtime deps (runc
      # 1.4.0, matching Ubuntu's bundled runc). The name matches
      # nixos/tests/rancher's ^k3s(_[[:digit:]]+)+$, so nixosTests.k3s covers it.
      overlays.k3s-pin = final: prev: {
        k3s_1_34_4 = nixpkgs-k3s-1344.legacyPackages.${prev.stdenv.hostPlatform.system}.k3s_1_34;
      };

      nixosConfigurations.gir = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit nixpkgs-k3s-1344; };
        modules = [
          { nixpkgs.overlays = [ self.overlays.k3s-pin ]; }
          ./hosts/gir/configuration.nix
          ./hosts/gir/k3s-guard.nix
        ];
      };

      # Ticket 13: these gate Window B. etcd is skipped on purpose: it exercises
      # clusterInit, which gir must never set.
      checks.${system} = {
        k3s-single-node = testPkgs.nixosTests.k3s.single-node.k3s_1_34_4;
        k3s-configuration = testPkgs.nixosTests.k3s.configuration.k3s_1_34_4;
      };
    };
}
