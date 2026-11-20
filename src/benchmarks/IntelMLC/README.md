# Intel Memory Latency Checker (MLC)

`mlc.sh` wraps Intel(R) Memory Latency Checker (`mlc`) to characterize DRAM
and CXL Type 3 memory expansion on a single platform: idle latency, peak
bandwidth, bandwidth-vs-core-count ramps, and DRAM+CXL interleaved traffic.
`utils/gen_plot.py` and `utils/gen_excel.py` turn the resulting CSVs into
charts and a spreadsheet.

## How it works

A run operates over one or more **CPU sockets** (`-s`, default: the first
node you pass to `-d`/`-c`) and one or more **memory NUMA nodes** (`-c` for
CXL-backed nodes, `-d` for DRAM-backed nodes). For every socket × every node
you give it, `mlc.sh` runs:

| Phase | Function | What it measures |
|---|---|---|
| Idle latency | `idle_latency()` | Sequential + random idle latency to that node |
| Peak bandwidth | `bandwidth()` | 10 fixed traffic patterns (R, W2, W5, W6, W7 × seq/rand) using every core on the socket |
| Bandwidth ramp | `bandwidth_ramp()` | Latency + bandwidth vs. core count (0..cores-per-socket), seq and rand |

If you give it **both** `-c` and `-d`, it additionally runs, for every
DRAM×CXL node pair:

| Phase | Function | What it measures |
|---|---|---|
| Interleave ramp | `bandwidth_ramp_interleave()` | Latency + bandwidth vs. core count, for W21/W23/W27 traffic mixed across the DRAM+CXL pair at 90:10, 75:25, and (W21 only) 50:50 ratios, seq only (MLC's interleave path doesn't support random access for any of these traffic types) |

`-s`, `-c`, and `-d` each accept **either a single value or a
comma-separated list** (e.g. `-s 0,1`, `-c 2,3`, `-d 0,1`). A list on any of
them is a "sweep": every listed socket runs the full test sequence, every
listed node gets its own idle-latency/bandwidth/ramp run on each of those
sockets, and — if both `-c` and `-d` are given — every DRAM×CXL combination
gets its own interleave run, on every socket. A single value behaves
exactly like specifying one socket/node always has. Sweeping sockets is
deliberately explicit rather than automatic: local-vs-remote access from
each socket's point of view is usually exactly what you want to compare,
not collapsed away.

Because every output filename and CSV row is tagged with which socket and
node(s) it came from (see [Output files](#output-files-and-naming) below —
this tagging is always present, even for a single socket/node), a sweep's
results all land safely in one flat output directory: nothing gets
overwritten, and charts overlay every socket/node combination with distinct
labels.

`mlc.sh` cannot tell which NUMA node is backed by DRAM vs. CXL on its own —
you must know your platform's topology (e.g. from `numactl -H`, `lscpu -e`,
or `cxl list`) and pass the right node IDs to `-d`/`-c` yourself.

Before starting tests, if `-s`, `-c`, or `-d` was given more than one value,
`mlc.sh` prints a short "Sweep plan" summary (socket/node counts and
interleave pair counts, per-socket and total) so you know the scope before
it runs — **runtime scales with the product of sockets × DRAM nodes × CXL
nodes**: a 2×2×2 sweep runs roughly 8× a single-socket/single-node run (each
single node's bandwidth+ramp phase alone is several minutes, and can be
substantially longer now that buffer sizes are tuned to defeat modern
multi-hundred-MB LLCs - see below).

## Buffer sizing

`mlc.sh` allocates one memory buffer per MLC thread for every bandwidth test
(`bandwidth()`, `bandwidth_ramp()`, `bandwidth_ramp_interleave()`). Older
generations of this script hardcoded that buffer to a small, fixed size
(40 MiB/thread). Server L3 caches have grown enormously since - hundreds of
MB, shared across every core on a socket - so a small fixed buffer means the
*aggregate* footprint (buffer × active threads) can fit entirely inside the
LLC at low core counts. When that happens, the "bandwidth" MLC reports is
cache bandwidth (several × faster than a single DRAM/CXL channel), not real
memory-tier bandwidth - the low-core-count region of the ramp silently stops
measuring what it claims to measure.

To fix this, `mlc.sh` now auto-detects, at the start of each test:

1. **The target socket's last-level cache size** - via `lscpu -C` (util-linux
   ≥ 2.37) with a `/sys/devices/system/cpu/cpuN/cache/` fallback for older
   systems. The buffer is sized to `CACHE_DEFEAT_MARGIN` (default `3`) ×
   that LLC size, so even a *single* active thread's own buffer already
   exceeds the LLC - the whole ramp is memory-bound, not just the tail.
2. **The target NUMA node's free memory** - via
   `/sys/devices/system/node/nodeN/meminfo` (`numactl -H` fallback). The
   buffer is capped so that (buffer size × max threads tested) never exceeds
   `NODE_CAPACITY_SAFE_FRACTION_PCT` (default `75`) of the node's free
   memory - critical for small pools (e.g. a single DIMM's worth of DRAM or
   CXL capacity), where a fully cache-defeating buffer simply won't fit. For
   the DRAM+CXL interleave test, both nodes in the pair are checked (a
   single per-thread buffer is split across both by ratio, and the ratio
   varies per test), and the buffer size stays fixed across every ratio
   tested against that pair, so results stay comparable.

Every test run prints the buffer size it computed and why. If the capacity
cap engaged, it prints a `WARNING: Buffer size capped ...` line explaining
by how much, and `summary_report.md`/`summary_report.json` surface the same
warning under **Observations**. When that happens, some low-core-count
ramp points may still carry partial cache residency - trust the report's
**Sustained BW** columns (tail-of-ramp, at the highest core count tested)
over **Peak BW** in that case; see [Output files](#output-files-and-naming)
below.

Both knobs are overridable via environment variables if you need to
reproduce a specific prior configuration or tune for your own risk
tolerance: `MLC_SH_CACHE_MARGIN` (default `3`) and
`MLC_SH_CAPACITY_FRACTION_PCT` (default `75`). To bypass auto-detection
entirely and force a specific buffer size, use `-b <KiB>` (applies to every
test in the run).

## Requirements

- Root privilege (MLC needs it; `mlc.sh` will refuse to run otherwise). Run
  it via `sudo ./mlc.sh ...` rather than as a logged-in root shell — at the
  end of the run (or on Ctrl-C), `mlc.sh` hands ownership of the output
  directory back to the invoking user (via `$SUDO_UID`/`$SUDO_USER`) so the
  non-root post-processing steps below can read and write into it. If run
  as literal root (no `sudo`, e.g. an `su -` shell) there's no non-root user
  to hand ownership to, so it falls back to making the directory
  world-readable/writable instead.
- The `mlc` binary (see `get_mlc.sh`, or pass its path with `-m`)
- At least 2 NUMA nodes on the system, and at least one CXL device present
  if you pass `-c`
- `numactl`, `lscpu`, `lspci`, `grep`, `cut`, `bc`, `awk`
- To generate charts afterward: Python 3 with the venv under `utils/.venv`
  (see [Processing the results](#processing-the-results))

## Usage

```
# ./mlc.sh -?

Usage: ./mlc.sh -c <CXL NUMA Node ID(s)> -d <DRAM NUMA Node ID(s)> [optional args]

Runs bandwidth and latency tests on DRAM and CXL Type 3 Memory using Intel MLC
Run with root privilege (MLC needs it)

Optional args:

   -b <KiB>
      Force the MLC per-thread buffer size (KiB) instead of auto-detecting
      it from the target CPU's LLC size and the target NUMA node's free
      memory. Use this to override the auto-tuned value, e.g. to reproduce
      a prior run's exact buffer size, or if auto-detection is wrong for
      your platform. By default the buffer is sized to 3x the
      detected last-level cache so results are DRAM/CXL-bound rather than
      cache-resident, capped to 75% of the target node's free memory.

   -c <CXL NUMA Node(s)>
      Specify the NUMA Node(s) backed by CXL for testing.
      Accepts a single node or a comma-separated list, e.g. -c 2,3

   -d <DRAM NUMA Node(s)>
      Specify the NUMA Node(s) backed by DRAM for testing.
      Accepts a single node or a comma-separated list, e.g. -d 0,1

      Providing both -c and -d sweeps every DRAM x CXL node pair
      for the interleave tests, in addition to per-node tests.

   -m <Path to MLC executable>
      Specify the path to the MLC executable

   -s <Socket(s)>
      Specify which CPU socket(s) should be used for running mlc.
      Accepts a single socket or a comma-separated list, e.g. -s 0,1
      Each socket runs the full test sequence; output files are tagged with .socket_<n>.
      By default, the first DRAM (or CXL) node id is used.

   -v
      Print verbose output. Use -v, -vv, and -vvv to increase verbosity.

   -X
      For bandwidth tests, mlc will use all cpu threads on each Hyperthread enabled core.
      Use this option to use only one thread on the core

   -Z <Specify whether to enable or disable the AVX_512 option>
      Values:
        0: AVX_512 Option Disabled
        1: AVX_512 Option Enabled - Default
      By default, the AVX_512 option is enabled. If the non-AVX512
      version of MLC is being used, this option shall be set to 0

Compare mode:

   ./mlc.sh --compare <run_A_dir_or_json> <run_B_dir_or_json> [-o <output.md>] [-t <threshold_pct>]
      Compare two prior mlc.sh output directories (or their
      summary_report.json files directly) and write a Markdown
      report highlighting which metrics got better or worse -
      useful for regression testing (run1 vs run2) or comparing
      one system to another. Needs neither root nor MLC itself.
      See utils/gen_compare.py --help for all options.
```

You must provide at least one of `-c` or `-d`.

### Examples

**Example 1:** DRAM only — NUMA node 0

```bash
$ sudo ./mlc.sh -d 0 -m ./mlc
```

**Example 2:** CXL only — NUMA node 2

```bash
$ sudo ./mlc.sh -c 2 -m ./mlc
```

**Example 3:** One DRAM node + one CXL node (adds the interleave test for that pair)

```bash
$ sudo ./mlc.sh -d 0 -c 2 -m ./mlc
```

**Example 4:** Sweep multiple nodes on one socket — 2 DRAM nodes and 2 CXL nodes,
all from socket 0's cores. This runs idle/bandwidth/ramp for all 4 nodes,
plus all 2×2=4 DRAM×CXL interleave pairs, into a single output directory.

```bash
$ sudo ./mlc.sh -s 0 -d 0,1 -c 2,3 -m ./mlc
```

**Example 5:** Two-socket server, two DRAM nodes, two CXL nodes — full local +
remote characterization from both sockets' perspective, in one invocation.

Say `numactl -H` shows: NUMA node 0 = socket 0's local DRAM, node 1 =
socket 1's local DRAM, node 2 = a CXL device attached near socket 0, node 3
= a CXL device attached near socket 1. `-s` accepts a list too, so one
invocation sweeps both sockets — local and remote DRAM/CXL access from
each, plus every DRAM×CXL interleave pair on each socket — all into a
single output directory:

```bash
$ sudo ./mlc.sh -s 0,1 -d 0,1 -c 2,3 -m ./mlc
```

That's a 2 sockets × 2 DRAM × 2 CXL sweep: 4 node tests + 4 interleave pairs
per socket, run twice (once per socket) — 8× the work of a single-node,
single-socket run, all disambiguated by the `.socket_<n>` tag on every file
and the `Socket` column in every CSV (see [Output files](#output-files-and-naming)),
so nothing from socket 0's run collides with socket 1's. `gen_plot.py` then
overlays both sockets' curves for the same node on one chart, each with its
own label (e.g. `socket0_node0` vs `socket1_node0`), making the local-vs-remote
comparison visible directly in the chart.

If you'd rather keep each socket's results in a separate directory (e.g. for
organizing/archiving runs individually), run it once per socket instead —
each invocation still gets its own timestamped output directory:

```bash
$ sudo ./mlc.sh -s 0 -d 0,1 -c 2,3 -m ./mlc
$ sudo ./mlc.sh -s 1 -d 0,1 -c 2,3 -m ./mlc
```

**Example 6:** Compare two runs — regression testing (run1 vs run2 on the same
box) or system-to-system. Neither root nor `mlc` is needed for this mode:

```bash
$ ./mlc.sh --compare ./mlc.sh.myhost.0723-1500 ./mlc.sh.myhost.0724-0900
$ ./mlc.sh --compare ./mlc.sh.systemA.0723-1500 ./mlc.sh.systemB.0723-1500 -t 5
```

See [Comparing two runs](#comparing-two-runs) below for what the output looks
like and how to interpret it.

## Output files and naming

Each run creates `./mlc.sh.<hostname>.<MMDD-HHMM>/`, containing a flat set of
files. Every filename embeds the specific socket and node(s) it covers —
`.socket_<S>` is always appended as the last segment before the file
extension, regardless of whether you swept multiple sockets or just used
the default — which is how `gen_plot.py`/`gen_excel.py` group and
disambiguate results without needing a directory structure:

| File pattern | Produced by | Meaning |
|---|---|---|
| `mlc.sh.log` | — | Captured STDOUT/STDERR of the whole run |
| `idle_latency_{seq,rand}_numa_node_<N>.socket_<S>.txt` | `idle_latency` | Idle latency to node `<N>`, generated from socket `<S>` |
| `bw_node<N>_{seq,rand}_<PATTERN>.socket_<S>.txt` | `bandwidth` | Peak bandwidth to node `<N>` from socket `<S>` for one of the 10 fixed traffic patterns |
| `bw_ramp.results.node_<N>.R.{seq,rand}.<ratio>.socket_<S>.csv` | `bandwidth_ramp` | Bandwidth/latency vs. core count for node `<N>` from socket `<S>` (`<ratio>` is `100:0` if `<N>` was given via `-d`, `0:100` if via `-c`) |
| `bw_ramp_interleave.results.node_<D>.node_<C>.<W>.seq.<ratio>.socket_<S>.csv` | `bandwidth_ramp_interleave` | Bandwidth/latency vs. core count for the DRAM node `<D>` + CXL node `<C>` pair from socket `<S>`, traffic type `<W>` (W21/W23/W27), at the given DRAM:CXL ratio. Seq only — MLC's interleave path rejects random access for W21/W23/W27 |
| `summary_report.md` | `utils/gen_report.sh` | Auto-generated Markdown summary — system info, which tests ran/succeeded, peak *and sustained (tail-of-ramp)* latency/bandwidth tables by Socket→Node and by DRAM+CXL interleave pair, and auto-detected anomalies (including cache-residency artifacts and buffer-size-capped tests) |
| `summary_report.json` | `utils/gen_report.sh` | Machine-readable version of `summary_report.md` — same system info, topology, tests-run, and peak/sustained-results data, for scripting (e.g. `utils/gen_compare.py`, see [Comparing two runs](#comparing-two-runs)) |

The two CSV-producing functions (`bandwidth_ramp`, `bandwidth_ramp_interleave`)
also write a `Socket` column (first column) into every row, so a CSV opened
on its own is still self-describing without needing to parse the filename.

Because a sweep's files are disambiguated by socket + node ID in the
filename itself, you never need per-socket or per-node subdirectories —
point `gen_plot.py`/`gen_excel.py` at the one output directory and they'll
find everything.

At the end of a successful run, `mlc.sh` automatically generates
`summary_report.md` **and** `summary_report.json` (via `utils/gen_report.sh`,
pure bash/awk — no Python venv needed, so unlike charts this one *does* run
automatically) and prints both paths, then prints the exact command to
generate charts, e.g.:

```
Report written to: ./mlc.sh.myhost.0723-1500/summary_report.md
JSON report written to: ./mlc.sh.myhost.0723-1500/summary_report.json

To generate charts from the CSV results, run:
  /path/to/IntelMLC/utils/.venv/bin/python /path/to/IntelMLC/utils/gen_plot.py -d "./mlc.sh.myhost.0723-1500"
```

Charts aren't generated automatically, to avoid requiring a Python venv
inside a root-privileged bash tool — see
[Processing the results](#processing-the-results). `gen_report.sh` can also
be re-run standalone at any time (e.g. after generating charts separately,
to pick up the new PNGs into the report's Charts section), regenerating both
the `.md` and `.json` files:

```bash
$ utils/gen_report.sh ./mlc.sh.myhost.0723-1500
```

## Comparing two runs

`utils/gen_compare.py` diffs two runs' `summary_report.json` files and
highlights which metrics got better or worse — useful for regression testing
(run1 vs run2 on the same box) or comparing one system to another. It's
plain Python 3 using only the standard library (`json`, `argparse`), so
unlike `gen_plot.py`/`gen_excel.py` below, **it needs no venv** — the Markdown
report is a stable, structured format specifically so a second script can
consume it without re-parsing prose.

```bash
$ ./mlc.sh --compare ./mlc.sh.myhost.0723-1500 ./mlc.sh.myhost.0724-0900
# or directly, with options:
$ ./utils/gen_compare.py ./mlc.sh.systemA.0723-1500 ./mlc.sh.systemB.0723-1500 -t 5 -o comparison.md
```

Each positional argument accepts either an `mlc.sh` output directory (it
looks for `summary_report.json` inside) or a path to a `.json` file directly.
`-t/--threshold` (default `3`, in percent) sets how large a change has to be
before it's flagged — smaller changes are treated as noise. `--label-a`/
`--label-b` override the display names (default: each run's hostname).

The output, `comparison_report.md` by default, matches `summary_report.md`'s
table layout — one row per Socket→Node (and per DRAM+CXL interleave pair) —
but each metric cell shows `A → B (Δ% marker)`, where the marker is `▲`
(better), `▼` (worse), or `~` (within the threshold). Bandwidth is
higher-is-better, latency is lower-is-better; both Peak BW and Sustained BW
are compared, since Peak BW can still reflect a low-core-count
cache-residency artifact (see [Buffer sizing](#buffer-sizing)) - Sustained
BW is the one to trust for a genuine regression. A **Regressions** section at
the top lists every metric that crossed the threshold worse, worst first, so
the "what changed" answer doesn't require reading every table row. Nodes
present in only one of the two runs (e.g. comparing systems with different
NUMA layouts) are listed separately as "Only in A"/"Only in B" rather than
guessed at.

## Processing the results

```bash
# One-time setup: create the venv and install dependencies (never installed globally)
$ cd utils
$ python3 -m venv .venv
$ source .venv/bin/activate
$ pip install -r requirements.txt
```

**Charts** — `gen_plot.py -d <directory>` plots bandwidth and latency vs.
core count. `-r {w21,w23,w27}` and `-t {seq,rand}` are optional: omit either
(or both) and it loops every applicable combination for you, printing a
short "no data" note and skipping cleanly for any combination the directory
doesn't have data for (e.g. `w23`/`w27` require a run that swept both `-c`
and `-d`).

```bash
# Recommended: generate every chart this directory's data supports
$ ./utils/.venv/bin/python ./utils/gen_plot.py -d ./mlc.sh.myhost.0723-1500

# Or target one specific ratio/type combination
$ ./utils/.venv/bin/python ./utils/gen_plot.py -d ./mlc.sh.myhost.0723-1500 -r w21 -t seq
```

If a directory's data covers multiple sockets and/or nodes (from a sweep),
every combination's curve is overlaid on the same chart, each labeled by
its socket/node (e.g. `socket0_node0`, `socket1_node0`).

**Spreadsheet** — `gen_excel.py <Directory> <ExcelFile>` puts every CSV in
the directory onto its own worksheet, named after the socket/node(s) in its
filename (truncated and disambiguated with a short hash if a name would
exceed Excel's 31-character sheet-name limit or collide with another):

```bash
$ ./utils/.venv/bin/python ./utils/gen_excel.py ./mlc.sh.myhost.0723-1500 mlc.results.xlsx
```

## Troubleshooting

If you encounter the following error:

```
alloc_mem_onnode(): unable to mbind: : Invalid argument
Buffer allocation failed!
```

Verify the DRAM and CXL memory NUMA node memory is ONLINE

```
# lsmem -o+ZONES,NODE
RANGE                                  SIZE   STATE REMOVABLE   BLOCK          ZONES NODE
0x0000000000000000-0x000000007fffffff    2G  online       yes       0           None    0
0x0000000100000000-0x000000107fffffff   62G  online       yes    2-32         Normal    0
0x0000001080000000-0x000000307fffffff  128G  online       yes   33-96         Normal    1
0x0000003080000000-0x000000407fffffff   64G  online       yes  97-128         Normal    3
0x0000004080000000-0x000000607fffffff  128G offline           129-192 Normal/Movable    2
0x0000006080000000-0x000000707fffffff   64G offline           193-224 Normal/Movable    4


Memory block size:         2G
Total online memory:     256G
Total offline memory:    192G
```

To resolve this, online the memory blocks

```
$ cd /sys/bus/node/devices/node2
$ for m in `find . -name "memory*[0-9]"`
do
  sudo echo online > $m/state
done

# lsmem
lsmem -o+ZONES,NODE
RANGE                                  SIZE   STATE REMOVABLE   BLOCK          ZONES NODE
0x0000000000000000-0x000000007fffffff    2G  online       yes       0           None    0
0x0000000100000000-0x000000107fffffff   62G  online       yes    2-32         Normal    0
0x0000001080000000-0x000000307fffffff  128G  online       yes   33-96         Normal    1
0x0000003080000000-0x000000407fffffff   64G  online       yes  97-128         Normal    3
0x0000004080000000-0x000000607fffffff  128G  online       yes 129-192         Normal    2
0x0000006080000000-0x000000707fffffff   64G offline           193-224 Normal/Movable    4

Memory block size:         2G
Total online memory:     384G
Total offline memory:     64G
```
