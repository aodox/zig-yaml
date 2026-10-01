# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "A YAML 1.2.2 parser and emitter for Zig, shaped like std.json";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
    zon2nix = {
      url = "github:jcollie/zon2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      zon2nix,
      ...
    }:

    let
      inherit (nixpkgs) lib;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      # The devshell's Zig, with one line of its own standard library put
      # right, because without it `zig build fuzz --fuzz` cannot compile.
      #
      # Zig 0.16.0's `compiler/test_runner.zig` reports a failing fuzz input by
      # asking `std.debug.writeStackTrace` to print what `@errorReturnTrace()`
      # gave it. Those are two different types: an error return trace is a
      # `builtin.StackTrace`, a ring buffer with a write index, and that
      # function takes a `debug.StackTrace`, which is a plain slice and a count
      # of what was skipped. It is a type error, it is on the path taken only
      # under `-ffuzz`, and it stops *any* project with a fuzz test in it from
      # building one. The fix is the function next door: `writeErrorReturnTrace`
      # takes exactly the type in hand and is what the other three places in
      # the same file use.
      #
      # `--replace-fail` is the whole safety of this: the day Zig ships the fix
      # the pattern will not be found, the build will fail here rather than
      # patch something else, and this can go.
      #
      # It buys the fuzzer and not its coverage. Nothing in this release
      # populates the table of program counters, so a bounded run ends with
      # "corrupted coverage file: pcs_len was zero" and an unbounded one
      # panics in the build runner's coverage thread; neither is a finding,
      # and a finding says "input saved to" above the report. That is why
      # `tools/fuzz.zig` exists.
      fuzzableZig =
        pkgs:
        let
          # A farm of symlinks rather than a copy: the library is 217 MB, and
          # exactly one file of it is being changed.
          library = pkgs.runCommand "zig-0.16.0-lib-fuzz-fix" { } ''
            cp -rs --no-preserve=mode ${pkgs.zig_0_16}/lib/zig $out
            chmod -R u+w $out
            rm $out/compiler/test_runner.zig
            cp --no-preserve=mode \
              ${pkgs.zig_0_16}/lib/zig/compiler/test_runner.zig \
              $out/compiler/test_runner.zig
            substituteInPlace $out/compiler/test_runner.zig \
              --replace-fail \
                'std.debug.writeStackTrace(trace, stderr)' \
                'std.debug.writeErrorReturnTrace(trace, stderr)'
          '';
        in
        pkgs.symlinkJoin {
          name = "zig-0.16.0-fuzzable";
          paths = [ pkgs.zig_0_16 ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/zig --set ZIG_LIB_DIR ${library}
          '';
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          # The Zig dependencies -- only the yaml-test-suite data, which the
          # library itself never needs -- as the farm `zig build --system`
          # expects, so that CI fetches them through Nix and its cache.
          zig-deps = pkgs.callPackage ./build.zig.zon.nix { };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          default = pkgs.mkShell {
            name = "zig-yaml";
            nativeBuildInputs = [
              (fuzzableZig pkgs)
              pkgs.git-pages-cli
              pkgs.reuse

              # zon2nix shells out to `zig env`, so it is wrapped to find the
              # Zig this project builds with rather than whatever is on the
              # caller's PATH.
              (pkgs.symlinkJoin {
                name = "zon2nix";
                paths = [ zon2nix.packages.${system}.zon2nix ];
                nativeBuildInputs = [ pkgs.makeWrapper ];
                postBuild = ''
                  wrapProgram $out/bin/zon2nix \
                    --prefix PATH : ${lib.makeBinPath [ pkgs.zig_0_16 ]}
                '';
              })
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.kcov
              pkgs.perf
            ];
          };
        }
      );
    };
}
