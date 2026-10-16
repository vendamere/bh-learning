{
  description = "Bluespec Haskell (BH / Classic) dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    devshell.url = "github:numtide/devshell";

    # Kept so `nix (develop|shell)` works on older Nix without the flakes UX,
    # and so tooling that expects `default.nix` can `flake-compat` into this flake.
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs =
    { flake-utils
    , devshell
    , nixpkgs
    , ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        # ── CHANGE ME ─────────────────────────────────────────────────────
        # Only used for the MOTD banner. The testbench/RTL tops, and every
        # build command, live in the justfile.
        projectName = "bh-learning";
        font = "stampatello";
        color = "34";
        style = "bold";
        # ──────────────────────────────────────────────────────────────────

        pkgs = import nixpkgs {
          inherit system;
          # claude-code is unfree; the toolchain below is not.
          config.allowUnfree = true;
          overlays = [
            devshell.overlays.default
          ];
        };
        lib = pkgs.lib;

        packages = [
          pkgs.just # every build/test command lives in ./justfile
          pkgs.watchexec # `just dev`
          # bsc, plus bluetcl (library introspection), bsv2bsc/bsc2bsv
          # (translate between the Classic and SystemVerilog syntaxes), and
          # dumpbo/dumpba (inspect compiled packages and elaborated modules).
          pkgs.bluespec

          pkgs.iverilog # bsc's default `-vsim` backend, used by `just vsim`
          # An independent opinion on the generated RTL, for ad-hoc use:
          #   just verilog && verilator --lint-only --top-module mkGCD \
          #     -I$BLUESPEC_VERILOG build/rtl/out/*.v
          pkgs.verilator
          pkgs.surfer # VCD/FST waveform viewer, used by `just wave`
          pkgs.graphviz # render bsc's -sched-dot schedule graphs
          pkgs.gh

          # Not optional. `bsc -sim -e` shells out to `c++` to build the
          # Bluesim model, and the simulator bsc emits is a /bin/sh script
          # that calls `basename` and `bluetcl`. devshell.mkShell builds a
          # hermetic PATH from this list alone, so without these the link
          # step dies with `c++: command not found` and the simulator
          # mis-parses its own arguments into a usage dump.
          pkgs.stdenv.cc
          pkgs.coreutils
          # The justfile runs its recipes (and `#!/usr/bin/env bash` ones)
          # under bash, which has to come from this list too.
          pkgs.bashInteractive
          # $BLUESPECDIR/exec/bsc_build_vsim_* (the `-vsim` link helpers)
          # also reach for grep/find/which.
          pkgs.gnugrep
          pkgs.gnused
          pkgs.findutils
          pkgs.which

          # Synthesis, if the project grows into it — note that yosys is not
          # in the aarch64-darwin binary cache, so adding it means a build.
          # pkgs.yosys
          # pkgs.yosys-bluespec
        ];

        motd = ''
          {${color}}{${style}}$(${pkgs.figlet}/bin/figlet -c -n -f ${font} "${projectName}"){reset}
            Bluespec Haskell (BH) — src/ · test/ · build/

            $(type -p menu &>/dev/null && menu)

            Just:
            $(just --list --unsorted 2>/dev/null)
        '';
      in
      {
        devShells.default = pkgs.devshell.mkShell {
          # The justfile holds the build/test commands, devshell.toml any
          # project-local tools/env (claude-code lives there); this flake
          # holds only the bsc toolchain and cross-machine bits.
          imports = [ (pkgs.devshell.importTOML ./devshell.toml) ];
          inherit packages;
          # bsc's Verilog primitives (FIFO2.v, RegFile.v, …), for `just
          # verilog` to point at and for feeding the RTL to other tools.
          env = [
            {
              name = "BLUESPEC_VERILOG";
              value = "${pkgs.bluespec}/lib/Verilog";
            }
          ];
          devshell.motd = lib.mkForce motd;
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
