{ pkgs }:
let
  mkGhc = key: v@{ncursesVersion ? "6", ...}:
    pkgs.callPackage ./artifact.nix {} {
      bindistTarballs = (mkTarballs v);
      bindistVersion = v.bindistVersion or null;
      inherit ncursesVersion key;
    };
  hashes = import ./hashes.nix;
  mkTarballs = { src, ...}: builtins.mapAttrs (_plat: v: pkgs.fetchurl v) src;
in
  builtins.mapAttrs (key: v: mkGhc key v ) hashes // { inherit mkGhc; }
