# libkdumpfile: reads kdump-compressed / makedumpfile vmcores. drgn links it so
# it can open /var/crash/<stamp>/dump.<stamp> directly. Not in nixpkgs.
# Upstream: https://github.com/ptesarik/libkdumpfile (Petr Tesarik, SUSE kdump).
{ lib, stdenv, fetchurl, pkg-config, zlib, lzo, snappy, zstd, libbfd, libopcodes }:

stdenv.mkDerivation rec {
  pname = "libkdumpfile";
  version = "0.5.5";

  src = fetchurl {
    url = "https://github.com/ptesarik/libkdumpfile/releases/download/v${version}/libkdumpfile-${version}.tar.gz";
    hash = "sha256-FkFVKOhweRrI05JCLwmGtMP4Pmy0JntNr/5pgvxfSjo=";
  };

  nativeBuildInputs = [ pkg-config ];
  # libbfd + libopcodes only for configure's dis-asm.h check (test tooling).
  buildInputs = [ zlib lzo snappy zstd libbfd libopcodes ];

  # Library only. configure insists on dis-asm.h (for tools/kdumpid), and that
  # tool does not compile against binutils 2.46 (bfd.h wants config.h first).
  # drgn needs only libkdumpfile.so and its headers, so skip tools/tests/examples.
  postPatch = ''
    sed -i 's/^SUBDIRS = include src tests tools examples/SUBDIRS = include src/' Makefile.in
  '';

  # The test suite needs kernel dump fixtures this sandbox does not have.
  doCheck = false;

  meta = {
    description = "Library for reading kernel dump files (kdump-compressed, ELF, diskdump)";
    homepage = "https://github.com/ptesarik/libkdumpfile";
    license = [ lib.licenses.lgpl3Plus lib.licenses.gpl2Plus ];
    platforms = lib.platforms.linux;
  };
}
