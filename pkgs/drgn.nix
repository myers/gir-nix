# drgn: programmable debugger. On gir it reads a vmcore and answers "who holds
# this lock?" (see logs/vmcore-hashlock-owners-20260918-101911.sh for the crash
# version of that question). Not in nixpkgs, and neither is crash.
# Upstream: https://github.com/osandov/drgn (v0.2.0, 2026-04-29, same on PyPI).
#
# Needs DWARF for the kernel (linux-<ver>-dev/vmlinux carries it) and, for ZFS
# types, the debug output of modules/zfs-debuginfo.nix.
{ lib, python3Packages, fetchPypi, autoconf, automake, libtool, pkg-config
, elfutils, libkdumpfile, zlib, bzip2, xz, zstd, bison, flex, gettext }:

python3Packages.buildPythonApplication rec {
  pname = "drgn";
  version = "0.2.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-aUDM0G9DW0Sg0nhkNZ7anIw+TFzq+PQ8+ZQoB5bzKWw=";
  };

  build-system = [ python3Packages.setuptools ];
  nativeBuildInputs = [ autoconf automake libtool pkg-config bison flex gettext ];
  buildInputs = [ elfutils libkdumpfile zlib bzip2 xz zstd ];

  # Tests need a live kernel or dump fixtures.
  doCheck = false;

  meta = {
    description = "Programmable debugger for the Linux kernel and userspace";
    homepage = "https://github.com/osandov/drgn";
    license = lib.licenses.lgpl21Plus;
    platforms = lib.platforms.linux;
    mainProgram = "drgn";
  };
}
