{ stdenv, lib, patchelfUnstable
, perl, gcc, llvm_39
, ncurses6, ncurses5, gmp, glibc, libiconv
}: { bindistTarballs, ncursesVersion }:

# Prebuilt only does native
assert stdenv.targetPlatform == stdenv.hostPlatform;

let
  libPath = stdenv.lib.makeLibraryPath ([
    selectedNcurses gmp
  ] ++ stdenv.lib.optional (stdenv.hostPlatform.isDarwin) libiconv);

  selectedNcurses = {
    "5" = ncurses5;
    "6" = ncurses6;
  }."${ncursesVersion}";

  libEnvVar = stdenv.lib.optionalString stdenv.hostPlatform.isDarwin "DY"
    + "LD_LIBRARY_PATH";

  glibcDynLinker = assert stdenv.isLinux;
    if stdenv.hostPlatform.libc == "glibc" then
       # Could be stdenv.cc.bintools.dynamicLinker, keeping as-is to avoid rebuild.
       ''"$(cat $NIX_CC/nix-support/dynamic-linker)"''
    else
      "${stdenv.lib.getLib glibc}/lib/ld-linux*";

  # Figure out version of bindist
  version =
    let
      helper = stdenv.mkDerivation {
        name = "bindist-version";
        src = bindistTarballs.${stdenv.targetPlatform.system};
        nativeBuildInputs = [ gcc perl ];
        postUnpack = ''
          patchShebangs ghc*/utils/
          patchShebangs ghc*/configure
          sed -i 's@utils/ghc-pwd/dist-install/build/tmp/ghc-pwd-bindist@pwd@g' ghc*/configure
        '';
        buildPhase = ''
          make show VALUE=ProjectVersion > version
        '';
        installPhase = ''
          source version
          echo -n "$ProjectVersion" > $out
        '';
      };
    in lib.readFile helper;
in

stdenv.mkDerivation rec {
  inherit version;

  name = "ghc-${version}";

  src = bindistTarballs.${stdenv.targetPlatform.system};

  nativeBuildInputs = [ perl ];
  propagatedBuildInputs = [ stdenv.cc ];
  buildInputs = stdenv.lib.optionals (stdenv.targetPlatform.isAarch32 || stdenv.targetPlatform.isAarch64) [ llvm_39 ];

  # Cannot patchelf beforehand due to relative RPATHs that anticipate
  # the final install location/
  ${libEnvVar} = libPath;

  postUnpack =
    # GHC has dtrace probes, which causes ld to try to open /usr/lib/libdtrace.dylib
    # during linking
    stdenv.lib.optionalString stdenv.isDarwin ''
      export NIX_LDFLAGS+=" -no_dtrace_dof"
      # not enough room in the object files for the full path to libiconv :(
      for exe in $(find . -type f -executable); do
        isScript $exe && continue
        ln -fs ${libiconv}/lib/libiconv.dylib $(dirname $exe)/libiconv.dylib
        install_name_tool -change /usr/lib/libiconv.2.dylib @executable_path/libiconv.dylib -change /usr/local/lib/gcc/6/libgcc_s.1.dylib ${gcc.cc.lib}/lib/libgcc_s.1.dylib $exe
      done
    '' +

    # Some scripts used during the build need to have their shebangs patched
    ''
      patchShebangs ghc*/utils/
      patchShebangs ghc*/configure
    '' +

    # Strip is harmful, see also below. It's important that this happens
    # first. The GHC Cabal build system makes use of strip by default and
    # has hardcoded paths to /usr/bin/strip in many places. We replace
    # those below, making them point to our dummy script.
    ''
      mkdir "$TMP/bin"
      for i in strip; do
        echo '#! ${stdenv.shell}' > "$TMP/bin/$i"
        chmod +x "$TMP/bin/$i"
      done
      PATH="$TMP/bin:$PATH"
    '' +
    # We have to patch the GMP paths for the integer-gmp package.
    ''
      find . -name integer-gmp.buildinfo \
          -exec sed -i "s@extra-lib-dirs: @extra-lib-dirs: ${gmp.out}/lib@" {} \;
    '' + stdenv.lib.optionalString stdenv.isDarwin ''
      find . -name base.buildinfo \
          -exec sed -i "s@extra-lib-dirs: @extra-lib-dirs: ${libiconv}/lib@" {} \;
    '' +
    # Rename needed libraries and binaries, fix interpreter
    # N.B. Use patchelfUnstable due to https://github.com/NixOS/patchelf/pull/85
    stdenv.lib.optionalString stdenv.isLinux ''
      find . -type f -perm -0100 -exec ${patchelfUnstable}/bin/patchelf \
          --replace-needed libncurses${stdenv.lib.optionalString stdenv.is64bit "w"}.so.${ncursesVersion} libncurses.so \
          --replace-needed libtinfo.so.${ncursesVersion} libncurses.so.${ncursesVersion} \
          --interpreter ${glibcDynLinker} {} \;

      sed -i "s|/usr/bin/perl|perl\x00        |" ghc*/ghc/stage2/build/tmp/ghc-stage2
      sed -i "s|/usr/bin/gcc|gcc\x00        |" ghc*/ghc/stage2/build/tmp/ghc-stage2
    '';

  configurePlatforms = [ ];
  configureFlags = [
    "--with-gmp-libraries=${stdenv.lib.getLib gmp}/lib"
    "--with-gmp-includes=${stdenv.lib.getDev gmp}/include"
  ] ++ stdenv.lib.optional stdenv.isDarwin "--with-gcc=${./gcc-clang-wrapper.sh}"
    ++ stdenv.lib.optional stdenv.hostPlatform.isMusl "--disable-ld-override";

  # Stripping combined with patchelf breaks the executables (they die
  # with a segfault or the kernel even refuses the execve). (NIXPKGS-85)
  dontStrip = true;

  # No building is necessary, but calling make without flags ironically
  # calls install-strip ...
  dontBuild = true;

  # On Linux, use patchelf to modify the executables so that they can
  # find editline/gmp.
  preFixup = stdenv.lib.optionalString stdenv.isLinux ''
    for p in $(find "$out" -type f -executable); do
      if isELF "$p"; then
        echo "Patchelfing $p"
        patchelf --set-rpath "${libPath}:$(patchelf --print-rpath $p)" $p
      fi
    done
    for file in $(find "$out" -name settings); do
      substituteInPlace $file --replace '("ranlib command", "")' '("ranlib command", "ranlib")'
    done
  '' + stdenv.lib.optionalString stdenv.isDarwin ''
    # not enough room in the object files for the full path to libiconv :(
    for exe in $(find "$out" -type f -executable); do
      isScript $exe && continue
      ln -fs ${libiconv}/lib/libiconv.dylib $(dirname $exe)/libiconv.dylib
      install_name_tool -change /usr/lib/libiconv.2.dylib @executable_path/libiconv.dylib -change /usr/local/lib/gcc/6/libgcc_s.1.dylib ${gcc.cc.lib}/lib/libgcc_s.1.dylib $exe
    done

    for file in $(find "$out" -name setup-config); do
      substituteInPlace $file --replace /usr/bin/ranlib "$(type -P ranlib)"
    done
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    unset ${libEnvVar}
    # Sanity check, can ghc create executables?
    cd $TMP
    mkdir test-ghc; cd test-ghc
    cat > main.hs << EOF
      {-# LANGUAGE TemplateHaskell #-}
      module Main where
      main = putStrLn \$([|"yes"|])
    EOF
    $out/bin/ghc --make main.hs || exit 1
    echo compilation ok
    [ $(./main) == "yes" ]
  '';

  passthru = {
    targetPrefix = "";
    enableShared = true;
    haskellCompilerName = "ghc-${version}";
  };

  meta.license = stdenv.lib.licenses.bsd3;
  meta.platforms = [ "x86_64-linux" "x86_64-darwin" ];
}
