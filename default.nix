{ pkgs }:
let
  mkGhc = key: v:
    pkgs.callPackage ./artifact.nix {} {
      bindistTarballs = builtins.mapAttrs mkTarball v.hosts;
      bindistVersion = v.bindistVersion or null;
      hosts = v.hosts;
      inherit key;
    };
  hashes = import ./hashes.nix;
  mkTarball = _plat: { src, ...}: pkgs.fetchurl src;
in
  builtins.mapAttrs (key: v: mkGhc key v ) hashes // { inherit mkGhc; }
