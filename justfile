# Build/test recipes — https://just.systems. `just` (or `just --list`)
# shows them all. flake.nix only provides the toolchain; everything you run
# lives here.

set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

# ── CHANGE ME ─────────────────────────────────────────────────────────────
project := "bh-learning"

# bsc always needs two things: the module to elaborate and the file that
# defines it. The Bluesim testbench:
sim_top := "testBench"
sim_top_file := "test/TestBench.bs"

# The synthesizable top for the Verilog backend. It (and every other module
# you want to survive as its own Verilog module) needs a
# `{-# synthesize mkFoo #-}` pragma in the source.
rtl_top := "mkGCD"
rtl_top_file := "src/GCD.bs"
# ──────────────────────────────────────────────────────────────────────────

build := "build"

# `+` keeps bsc's own library path ($BLUESPECDIR/Libraries: Prelude, StmtFSM,
# FIFO, Vector, …) on the search path after we prepend ours.
src_path := "src:test:+"

# -check-assert arms the Assert library (without it dynamicAssert compiles to
# noAction and your checks silently vanish); -keep-fires keeps the
# CAN_FIRE/WILL_FIRE signals that make a waveform readable;
# -show-range-conflict prints the offending predicates on a
# parallel-composability error. All three are for simulation only — the RTL
# `verilog` emits is meant for synthesis, so it gets none.
debug_flags := "-check-assert -keep-fires -show-range-conflict"

just := just_executable()

# List the recipes
default:
    @{{just}} --list --unsorted

# Elaborate + link the Bluesim testbench and run it (extra args reach the simulator, e.g. -m 5000)
sim *args:
    @{{just}} _bsc sim sim -sim {{debug_flags}} -g {{sim_top}} -u {{sim_top_file}}
    @{{just}} _bsc sim sim -sim -e {{sim_top}} -o {{build}}/sim/{{sim_top}}
    exec {{build}}/sim/{{sim_top}} "$@"

# Re-run the testbench on every .bs change
dev *args:
    exec watchexec --exts bs --restart -- {{just}} sim "$@"

# Run the testbench and fail if a runtime assertion fired (Bluesim itself always exits 0)
check *args:
    #!/usr/bin/env bash
    set -euo pipefail
    log=$(mktemp)
    trap 'rm -f "$log"' EXIT
    {{just}} sim "$@" 2>&1 | tee "$log"
    # dynamicAssert/continuousAssert report with $display + $finish 0, so the
    # exit status tells you nothing — the output is the signal.
    if grep -q "assertion failed" "$log"; then
      echo "check: FAILED — a runtime assertion fired" >&2
      exit 1
    fi
    echo "check: no assertion failures"

# Run the testbench with VCD dumping and open the trace in surfer
wave:
    @{{just}} sim -V {{build}}/{{project}}.vcd
    exec surfer {{build}}/{{project}}.vcd

# Generate synthesis-ready RTL for every {-# synthesize #-} module reachable from the RTL top
verilog:
    @{{just}} _bsc rtl verilog -verilog -g {{rtl_top}} -u {{rtl_top_file}}
    @echo
    @echo "RTL in {{build}}/rtl/out:"
    @ls {{build}}/rtl/out
    @echo "(bsc's primitives — FIFO2.v, RegFile.v, … — live in $BLUESPEC_VERILOG)"

# Run the same testbench through the Verilog backend + iverilog, to cross-check the RTL against Bluesim
vsim *args:
    @{{just}} _bsc vsim verilog -verilog {{debug_flags}} -g {{sim_top}} -u {{sim_top_file}}
    @{{just}} _bsc vsim verilog -verilog -e {{sim_top}} -o {{build}}/vsim/{{sim_top}} -vsim iverilog
    exec {{build}}/vsim/{{sim_top}} "$@"

# Show the rule schedule and method conflicts bsc derived for a module
schedule module=rtl_top file=rtl_top_file:
    #!/usr/bin/env bash
    set -euo pipefail
    # Wiped every run on purpose: bsc only reports the schedule while it is
    # generating code, and there is no flag to force that — so a warm build
    # tree would just say "All packages are up to date".
    rm -rf {{build}}/sched
    {{just}} _bsc sched verilog -verilog -show-schedule -show-method-conf -sched-dot \
      -g "$1" -u "$2" >/dev/null
    # -show-schedule writes a .sched file rather than printing it; the rule
    # predicates, the blocking rules and the logical execution order in there
    # are what you actually want to read.
    cat {{build}}/sched/info/*.sched
    echo "Graphviz conflict/urgency/execution graphs alongside it:"
    ls -1 {{build}}/sched/info/*.dot
    echo "Render one with: dot -Tsvg <file>.dot -o schedule.svg"

# Remove every generated artifact (build/)
clean:
    rm -rf {{build}}
    @echo "removed {{build}}/"

# Create a git worktree at ../<project>-<name> and wire up direnv/.env
worktree name:
    #!/usr/bin/env bash
    set -euo pipefail
    dir=../{{project}}-"$1"
    git worktree add "$dir"
    mkdir -p "$dir/.claude"
    [ -f .claude/settings.local.json ] && cp .claude/settings.local.json "$dir/.claude/" || true
    [ -f .env ] && cp .env "$dir/.env" || true
    direnv allow "$dir"

# bsc against one build tree: `_bsc <tree> <sim|verilog> <bsc args…>`.
#
# One build tree per purpose, because bsc keys its up-to-date check on the
# .bo/.ba files in -bdir and those carry both the backend and the flags they
# were built with. Two consequences if trees are shared: a Verilog build
# silently overwrites the elaborated Bluesim module (and the next Bluesim link
# happily reuses the stale objects left in -simdir), and a build that wants
# different flags gets told "All packages are up to date" instead.
#
#   sim/   Bluesim, debug flags          rtl/   Verilog for synthesis
#   vsim/  Verilog, debug flags          sched/ scratch for `schedule`
[private]
_bsc tree backend *args:
    #!/usr/bin/env bash
    set -euo pipefail
    tree={{build}}/$1
    case $2 in
      sim) outflag=-simdir ;;
      verilog) outflag=-vdir ;;
      *) echo "_bsc: backend must be sim or verilog, not '$2'" >&2; exit 2 ;;
    esac
    shift 2
    # bsc refuses to create its own output directories.
    mkdir -p "$tree/bdir" "$tree/out" "$tree/info"
    cmd=(bsc -p {{src_path}} -bdir "$tree/bdir" -info-dir "$tree/info" "$outflag" "$tree/out" "$@")
    echo "${cmd[*]}" >&2
    exec "${cmd[@]}"
