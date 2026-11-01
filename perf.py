#!/usr/bin/env python3
"""Granite Rapids perf stat -ddd for an unpatched Linux 5.15 Intel PMU.

No third-party Python modules or runtime kernel source tree required.
"""
import argparse
import csv
import os
import platform
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Event:
    name: str
    config: int = None
    pmcs: str = ""
    reason: str = ""
    software: bool = False
    builtin: str = ""
    config1: int = None
    missing_kind: str = "no equivalent"

    @property
    def reliable(self):
        return self.software or (self.config is not None and self.pmcs == "0-7")

    @property
    def spec(self):
        if self.builtin:
            return self.builtin
        if self.software:
            return self.name
        if self.config is not None:
            extra = ",config1=0x%x" % self.config1 if self.config1 is not None else ""
            return "cpu/config=0x%x%s,name=%s/" % (self.config, extra, self.name)
        return None


# Linux core.c: Granite Rapids -> glc_common -> intel_pmu_init_glc().
# Audit: Linux 165768bb7026 core.c intel_glc_event_constraints and
# graniterapids/{pipeline,frontend,cache,virtual-memory,gnr-metrics}.json.
# v5.15 core.c unknown-model fallback: intel_gen_event_constraints; no GNR
# extra_regs or topdown update hooks. A bare offcore event cannot program
# MSR_OFFCORE_RSP_0: config1 requires a matching model-specific extra_regs entry.
# Rows without specs are wrapper decisions, not perf rejection results.
# Full local GNR audit: 16 JSON files, 398 core event records. No total L1I
# or ITLB access counter / matching L1D prefetch mapping was found. Related
# stall, STLB-hit, SW-prefetch and HW-prefetch counters are not equivalents.
# core.c defines pseudo topdown-heavy-ops=8400 and topdown-fetch-lat=8600.
# v5.15 intel_pmu_hw_config requires a fixed-slots leader for metric events;
# known model branches install num_topdown_events and update/read hooks.
# The generic unknown-model branch does not. These are not ordinary raw GP
# events; labeling them as absent hardware events would be misleading.
# Use architectural perf names wherever available; raw encodings are only
# needed for model-specific events. Configs below retain audit provenance.
EVENTS = [
    *(Event(n, software=True, reason="software counter; PMC rule not applicable")
      for n in ("task-clock", "context-switches", "cpu-migrations", "page-faults")),
    Event("cycles", 0x003c, "0-7", "architectural; fixed counter 1 also supported by 5.15", builtin="cpu-cycles"),
    Event("instructions", 0x00c0, "0-7", "architectural; fixed counter 0 also supported by 5.15", builtin="instructions"),
    Event("branches", 0x00c4, "0-7", builtin="branch-instructions"),
    Event("branch-misses", 0x00c5, "0-7", builtin="branch-misses"),
    Event("slots", 0x01a4, "0-7", "TOPDOWN.SLOTS_P; programmable equivalent of slots"),
    Event("topdown-retiring", 0x02c2, "0-7", "UOPS_RETIRED.SLOTS; programmable retiring numerator"),
    Event("topdown-bad-spec", 0x04a4, "0", "TOPDOWN.BAD_SPEC_SLOTS"),
    Event("topdown-fe-bound", 0x019c, "0-7", "IDQ_BUBBLES.CORE; programmable frontend-bound numerator"),
    Event("topdown-be-bound", 0x02a4, "0-7", "TOPDOWN.BACKEND_BOUND_SLOTS"),
    Event("topdown-heavy-ops",
          reason="pseudo r8400 exists; needs model-specific PERF_METRICS hooks; r01c2 is extra retired uops",
          missing_kind="kernel needed"),
    Event("topdown-br-mispredict", 0x08a4, "0", "TOPDOWN.BR_MISPREDICT_SLOTS"),
    Event("topdown-fetch-lat",
          reason="pseudo r8600 exists; needs model-specific PERF_METRICS hooks; r600019c is zero-delivery cycles",
          missing_kind="kernel needed"),
    Event("topdown-mem-bound", 0x10a4, "0-7", "TOPDOWN.MEMORY_BOUND_SLOTS"),
    Event("resource-stalls-sb", 0x8a2, "0-7", "RESOURCE_STALLS.SB"),
    Event("mem-load-retired-l1-miss", 0x8d1, "0-3", "MEM_LOAD_RETIRED.L1_MISS"),
    Event("mem-load-retired-l2-miss", 0x10d1, "0-3", "MEM_LOAD_RETIRED.L2_MISS"),
    Event("mem-load-retired-l3-miss", 0x20d1, "0-3", "MEM_LOAD_RETIRED.L3_MISS"),
    Event("L1-dcache-loads", 0x81d0, "0-3", "MEM_INST_RETIRED.ALL_LOADS"),
    Event("memory-stalls-l1-miss", 0x3000347, "0-3", "MEMORY_ACTIVITY.STALLS_L1D_MISS; cmask=3"),
    Event("memory-stalls-l2-miss", 0x5000547, "0-3", "MEMORY_ACTIVITY.STALLS_L2_MISS; cmask=5"),
    Event("memory-stalls-l3-miss", 0x9000947, "0-3",
          "MEMORY_ACTIVITY.STALLS_L3_MISS; cmask=9; demand cacheable loads"),
    Event("L1-dcache-load-misses", 0xe124, "0-3", "L2_RQSTS.ALL_DEMAND_DATA_RD (kernel cache mapping)"),
    Event("LLC-loads", 0x012a, "0-3",
          "experimental; requires MSR_OFFCORE_RSP_0; generic 5.15 may ignore config1",
          config1=0x10001),
    Event("LLC-load-misses", 0x012b, "0-3",
          "experimental; requires MSR_OFFCORE_RSP_1; generic 5.15 may ignore config1",
          config1=0x3fbfc00001),
    Event("L1-icache-loads", reason="no total L1I-access event in GNR table; ICACHE_* stalls are cycles, not loads"),
    Event("L1-icache-load-misses", 0xe424, "0-3", "L2_RQSTS.ALL_CODE_RD (kernel cache mapping)"),
    Event("dTLB-loads", 0x81d0, "0-3", "MEM_INST_RETIRED.ALL_LOADS; same mapping as L1-dcache-loads"),
    Event("dtlb-load-walk-active", 0x1001012, "0-3", "DTLB_LOAD_MISSES.WALK_ACTIVE; cmask=1"),
    Event("dtlb-store-walk-active", 0x1001013, "0-3", "DTLB_STORE_MISSES.WALK_ACTIVE; cmask=1"),
    Event("itlb-walk-active", 0x1001011, "0-3", "ITLB_MISSES.WALK_ACTIVE; cmask=1"),
    Event("uops-retired-stalls", 0x18002c2, "0-7", "UOPS_RETIRED.STALLS; invert=1, cmask=1"),
    Event("dtlb-load-misses", 0x0e12, "0-3", "DTLB_LOAD_MISSES.WALK_COMPLETED"),
    Event("iTLB-loads", reason="no total ITLB-access event; STLB hits and walks count misses only"),
    Event("iTLB-load-misses", 0x0e11, "0-3", "ITLB_MISSES.WALK_COMPLETED"),
    Event("L1-dcache-prefetches", reason="no matching mapping; r0f40 counts software prefetch instructions only"),
    Event("L1-dcache-prefetch-misses", reason="no matching mapping; r2051 counts hardware-prefetch misses only"),
]


# Strong scheduling groups, deliberately without :W (weak-group fallback).
# Sources:
# https://man7.org/linux/man-pages/man2/perf_event_open.2.html (group_fd)
# Linux v5.15 tools/perf/Documentation/perf-list.txt, EVENT GROUPS:
# events used in ratios must run together; groups must fit counter constraints.
# v5.15 arch/x86/events/core.c validate_group and kernel/events/core.c
# group_sched_in implement validation and all-or-none scheduling.
#
# Raw topdown events are ordinary GP counters, NOT PERF_METRICS pseudo-events:
# no special fixed-slots leader requirement applies. The L1 group needs five
# GP counters; memory breakdown needs three. BAD_SPEC_SLOTS and
# BR_MISPREDICT_SLOTS both need PMC0,
# so they MUST NOT share a group. Duplicate the denominator in the latter group
# with a distinct alias so CSV parsing never overwrites another slots count.
AUX_EVENTS = [
    Event("cycles-for-l3-stalls", 0x003c, "0-7",
          "CPU_CLK_UNHALTED.THREAD; denominator for L3-miss stall percentage"),
    Event("slots-for-memory", 0x01a4, "0-7",
          "TOPDOWN.SLOTS_P; denominator measured with memory/backend breakdown"),
    Event("be-bound-for-memory", 0x02a4, "0-7",
          "TOPDOWN.BACKEND_BOUND_SLOTS; parent measured with topdown-mem-bound"),
    Event("slots-for-br-mispredict", 0x01a4, "0-7",
          "TOPDOWN.SLOTS_P; denominator measured with topdown-br-mispredict"),
]
ALL_EVENTS = EVENTS + AUX_EVENTS
BY_NAME = {event.name: event for event in ALL_EVENTS}
GROUPS = (
    ("basic", ("cycles", "instructions", "branches", "branch-misses")),
    ("topdown-l1", ("slots", "topdown-retiring", "topdown-bad-spec",
                     "topdown-fe-bound", "topdown-be-bound")),
    ("topdown-memory", ("slots-for-memory", "be-bound-for-memory", "topdown-mem-bound")),
    ("resource", ("resource-stalls-sb",)),
    ("retired-cache-misses", ("mem-load-retired-l1-miss", "mem-load-retired-l2-miss", "mem-load-retired-l3-miss")),
    ("memory-stalls", ("memory-stalls-l1-miss", "memory-stalls-l2-miss")),
    ("topdown-branch", ("slots-for-br-mispredict", "topdown-br-mispredict")),
    ("l3-stall", ("cycles-for-l3-stalls", "memory-stalls-l3-miss")),
    ("l1d", ("L1-dcache-loads", "L1-dcache-load-misses")),
    # Different filters must use different offcore MSRs simultaneously.
    # Use 012a/RSP_0 and 012b/RSP_1 explicitly: generic 5.15 cannot perform
    # model-aware alternate-register assignment for two 012a events.
    ("llc", ("LLC-loads", "LLC-load-misses")),
    ("l1i", ("L1-icache-load-misses",)),
    ("dtlb", ("dTLB-loads", "dtlb-load-misses")),
    ("tlb-active", ("dtlb-load-walk-active", "dtlb-store-walk-active", "itlb-walk-active")),
    ("uops-stalls", ("uops-retired-stalls",)),
    ("itlb", ("iTLB-load-misses",)),
)
GROUP_FOR = {name: label for label, names in GROUPS for name in names}

# Explicit dependencies prevent using the similarly named event from another
# group. Instances of the same hardware event are never summed across groups.
# perf v5.15 util/stat-shadow.c uses these instruction/branch/cache denominators.
# Raw topdown numerators use local SLOTS_P, not a PERF_METRICS pseudo-event.
RATIOS = {
    "instructions": ("cycles", 1.0, "insn/cycle"),
    "branch-misses": ("branches", 100.0, "% of branches"),
    "L1-dcache-load-misses": ("L1-dcache-loads", 100.0, "% of all L1-dcache accesses"),
    "memory-stalls-l3-miss": ("cycles-for-l3-stalls", 100.0, "% cycles stalled on L3 miss"),
    "dtlb-load-misses": ("dTLB-loads", 100.0, "% of all dTLB cache accesses"),
    "LLC-load-misses": ("LLC-loads", 100.0, "% of all LL-cache accesses (experimental)"),
    **{name: ("slots", 100.0, "% of slots") for name in
       ("topdown-retiring", "topdown-bad-spec", "topdown-fe-bound", "topdown-be-bound")},
    "topdown-mem-bound": ("slots-for-memory", 100.0, "% memory bound"),
    "be-bound-for-memory": ("slots-for-memory", 100.0, "% backend bound (memory group)"),
    "topdown-br-mispredict": ("slots-for-br-mispredict", 100.0, "% branch mispredict"),
}


def metric_text(name, counts):
    if name not in RATIOS:
        return ""
    denominator, scale, label = RATIOS[name]
    # Treat a dependency/group mismatch as a programming error, not a result.
    assert GROUP_FOR[name] == GROUP_FOR[denominator]
    try:
        numerator = float(counts[name][0])
        divisor = float(counts[denominator][0])
        if divisor <= 0:
            return ""
        return "; %.2f %s" % (scale * numerator / divisor, label)
    except (KeyError, ValueError):
        return ""


def event_arguments():
    """Software events stay independent; hardware groups multiplex as units.

    Grouping preserves observation windows, not undocumented PMC assignments.
    A generic 5.15 kernel can still misassign a restricted raw event. Keep its
    UNRELIABLE label even when every member reports the same running time.
    """
    args = []
    for event in EVENTS:
        if event.software:
            args += ["-e", event.spec]
    for label, names in GROUPS:
        specs = [BY_NAME[name].spec for name in names]
        # Singleton groups need no braces; multi-event groups are mandatory.
        spec = "{" + ",".join(specs) + "}" if len(specs) > 1 else specs[0]
        args += ["-e", spec]
    return args


def annotation(event):
    label = "RELIABLE" if event.reliable else "UNRELIABLE"
    where = "software" if event.software else "PMC" + event.pmcs if event.pmcs else event.missing_kind
    group = "; group=" + GROUP_FOR[event.name] if event.name in GROUP_FOR else ""
    return "%s; %s%s%s" % (label, where, group, "; " + event.reason if event.reason else "")


def read_counts(text):
    """perf 5.15 -x: value;unit;event;runtime;percent-running;..."""
    result = {}
    names = {e.name for e in ALL_EVENTS}
    aliases = {e.builtin: e.name for e in ALL_EVENTS if e.builtin}
    for row in csv.reader(text.splitlines(), delimiter=";"):
        if len(row) < 3:
            continue
        name = row[2].strip()
        base = name.rsplit(":", 1)[0]
        name = aliases.get(name, aliases.get(base, name))
        # Some perf versions append privilege modifiers.
        if name not in names and name.rsplit(":", 1)[0] in names:
            name = name.rsplit(":", 1)[0]
        if name in names:
            result[name] = (row[0].strip(), row[1].strip(), row[4].strip() if len(row) > 4 else "")
    return result


def print_report(counts, elapsed, target, selected):
    print("\n Performance counter stats for %s:\n" % target)
    for event in ALL_EVENTS:
        if event.name in counts:
            value, unit, running = counts[event.name]
            if value and not value.startswith("<"):
                try:
                    value = format(float(value), ",.2f") if "." in value else format(int(value), ",d")
                except ValueError:
                    pass
            suffix = " (%s%% running)" % running.rstrip("%") if running else ""
        else:
            value = "<not counted>" if event in selected else "<%s>" % event.missing_kind if event.spec is None else "<skipped>"
            unit, suffix = "", ""
        print("%20s %-5s %-29s # %s%s" % (value, unit, event.name, annotation(event) + metric_text(event.name, counts), suffix))
    print("\n%20.9f seconds time elapsed" % elapsed)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-p", "--pid", help="attach to PID or comma-separated PIDs (all existing threads, as perf -p)")
    parser.add_argument("--duration", type=float, help="stop after this many seconds (attached mode)")
    parser.add_argument("--perf", default="perf", help="perf binary (default: perf)")
    parser.add_argument("--dry-run", action="store_true", help="print command and event audit without measuring")
    parser.add_argument("--force", action="store_true", help="allow a CPU other than Intel family 6 model AD/AE")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="optional workload after --")
    args = parser.parse_args(argv)
    workload = args.command[1:] if args.command[:1] == ["--"] else args.command
    if bool(args.pid) == bool(workload):
        parser.error("supply either -p PID or -- command [args ...]")
    if args.pid and any(not p.isdigit() or int(p) <= 0 for p in args.pid.split(",")):
        parser.error("PIDs must be positive integers")
    if args.duration is not None and (not args.pid or not 0 < args.duration < float("inf")):
        parser.error("--duration must be positive and finite, and requires -p")
    selected = [e for e in ALL_EVENTS if e.spec]
    cmd = [args.perf, "stat", "--no-big-num", "-x", ";"] + event_arguments()
    if args.pid:
        cmd += ["-p", args.pid]
        if args.duration is not None:
            # perf --timeout is not available in all old perf builds.
            cmd += ["--", "sleep", str(args.duration)]
    else:
        cmd += ["--"] + workload
    if args.dry_run:
        print(shlex.join(cmd))
        for event in ALL_EVENTS:
            print("%-29s %-48s %s" % (event.name, event.spec or "-", annotation(event)))
        print("Repeated hardware events have distinct aliases and group-local counts; "
              "do not sum them or use a denominator from another group.")
        for name, (denominator, scale, label) in RATIOS.items():
            print("metric: %s / %s * %g (%s); group=%s" %
                  (name, denominator, scale, label, GROUP_FOR[name]))
        return 0
    if platform.system() != "Linux":
        parser.error("measurement requires Linux; use --dry-run to inspect elsewhere")
    cpuinfo = Path("/proc/cpuinfo").read_text()
    cpus = [dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
            for block in cpuinfo.split("\n\n") if block.strip()]
    cpus = [{k.strip(): v.strip() for k, v in cpu.items()} for cpu in cpus]
    if not args.force and any(cpu.get("vendor_id") != "GenuineIntel" or
                              cpu.get("cpu family") != "6" or
                              cpu.get("model") not in ("173", "174") for cpu in cpus):
        parser.error("raw events target Granite Rapids (family 6 models 0xAD/0xAE); --force overrides")
    if not Path("/sys/bus/event_source/devices/cpu/type").exists():
        parser.error("cpu PMU is unavailable")
    env = dict(os.environ, LC_ALL="C")
    start = time.monotonic()
    # Keep workload stdout/stderr separate from perf's machine-readable report.
    with tempfile.TemporaryDirectory(prefix="granite-perf-") as temp:
        report = Path(temp) / "stat.csv"
        cmd[2:2] = ["-o", str(report)]
        try:
            child = subprocess.Popen(cmd, env=env)
        except OSError as exc:
            print("Cannot run perf: %s" % exc, file=sys.stderr)
            return 1
        def interrupt(signum, frame):
            # Terminal SIGINT also reaches perf; forwarding handles kill -INT
            # sent only to this wrapper. Repeated SIGINT is harmless to perf.
            if child.poll() is None:
                child.send_signal(signum)
        old = signal.signal(signal.SIGINT, interrupt)
        oldterm = signal.signal(signal.SIGTERM, interrupt)
        try:
            code = child.wait()
        finally:
            signal.signal(signal.SIGINT, old)
            signal.signal(signal.SIGTERM, oldterm)
        data = report.read_text() if report.exists() else ""
    counts = read_counts(data)
    print_report(counts, time.monotonic() - start, "PID " + args.pid if args.pid else shlex.join(workload), selected)
    if not counts:
        print(data, file=sys.stderr)
        print("No counters returned; check perf diagnostics, permissions and perf_event_paranoid.", file=sys.stderr)
    if not counts and code == 0:
        return 1
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    sys.exit(main())
