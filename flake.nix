{
  description = "gir: NixOS host configuration (Ubuntu → NixOS migration)";

  inputs = {
    # nixos-26.05 channel head, 2026-09-14 (ticket 02). Pin the channel branch,
    # not release-26.05, which is not necessarily built.
    nixpkgs.url = "github:NixOS/nixpkgs/c3eea5b2156db11c7eeeada3dc737711255b253e";
    # The only nixpkgs revisions where k3s_1_34 is exactly 1.34.4+k3s1 (ticket 03).
    # How k3s is pinned for real is ticket 13's decision.
    nixpkgs-k3s-1344.url = "github:NixOS/nixpkgs/dc68ac73f0fe99323cd0905a685f99ea8a073b48";
  };

  outputs = { self, nixpkgs, nixpkgs-k3s-1344, ... }: {
    nixosConfigurations.gir = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit nixpkgs-k3s-1344; };
      modules = [ ./hosts/gir/configuration.nix ];
    };
  };
}
