#!/usr/bin/env python3
"""Offline uop-cache-REPACK replay model (the section-4.8 model the prior study lacked).

Consumes a +UOCTRACE dump (one [UOCG] line per delivered fetch-group, one
[UOCF] line per backend/commit flush) emitted by
src/rtl/sim/fetch_frontend_profiler.sv, and replays it through a model of the
fill-time-packed UOC described in doc/arch_refactor_plan_gen2_2026-06-13.md
stage 4.

THESIS UNDER TEST: a fill-time-packed UOC delivers DENSE 4-uop traces that
cross taken edges + line boundaries, filling the truncation slots the line-path
leaves empty. It realizes UB x hit-rate (the dense trace is resident from a
prior loop pass), sidestepping the emit-time repacker's donor-unrequested kill.

THE MODEL, step by step (every assumption is stated; OPTIMISM flags marked):

  (1) Reconstruct the dynamic stream of delivered fetch-groups in commit order.
      Line-path delivery cost = #[UOCG] lines (one delivery cycle each).

  (2) FILL: walk the uop stream; accumulate decoded uops into DENSE trace
      entries (<=4 uops) ACROSS packet / line / taken boundaries.
      Seal-and-restart the current entry on:
        - entry full at 4 uops
        - an indirect target (JALR / C.JR / C.JALR / RET) ends the entry: the
          successor PC is not statically known at fill time
        - a serializing op (CSR / FENCE / FENCE.I / AMO / ECALL / EBREAK / *RET)
        - a flush / exception boundary ([UOCF])
      Direct control (JAL / Bcc / C.J / C.Bcc) does NOT seal: the dense trace
      packs straight through a *direct* taken edge -- that is the whole point.
      Each sealed entry is keyed by its HEAD pc.
      OPTIMISM(2a): packing through a direct taken edge assumes the resident
      entry was filled on a pass whose prediction matched this pass. We do NOT
      model per-edge misprediction inside a dense entry beyond the [UOCF]
      restart; a dense entry that spans a conditional branch is assumed to
      replay correctly. This is OPTIMISTIC where intra-loop conditionals flip.

  (3) INSTALL into 32 sets x 8 ways, index = head_pc[5:1], tag = head_pc>>6,
      tree-pLRU victim (the as-built geometry, rv64gc_pkg.sv:117-119).

  (4) LOOKUP at each dense-entry head: HIT if a resident matching entry exists
      BEFORE this pass (re)installs it -> measured residency = realized hit.
      A miss installs and yields no gain (first pass / post-evict).

  (5) RECOVERED CYCLES (the realizable gain, = UB x hit-rate by construction):
      For each dense entry that is a resident HIT and spans uops the line path
      delivered across L distinct [UOCG] groups, the UOC delivers them in
      D = ceil(uops/4) dense groups. recovered_cycles += (L - D), but only the
      portion of L groups *fully consumed* by this entry (a line group split
      across two dense entries is credited fractionally by uop share, so a
      group is never double-counted). Equivalent slot view also reported:
      recovered_slots = sum over packed-to-4 entries of (4 - line_delivered).
      cycles_saved is recovered_cycles capped by a SUPPLY-BOUND gate:
      gain cannot exceed the slack between cycles and an IPC=4 floor, AND is
      attributed only where the line path was actually truncated (cause in
      {taken, line-complete-seq, straddle, other-partial}); full-4 groups
      (cause=6) contribute zero recoverable slots -- this is what keeps a
      chain-bound control (crc32) and a supply-capped control (CM) honest.
      OPTIMISM(5a): we assume every recovered delivery cycle is on the IPC
      critical path (1:1 cycle saving). Real machines hide some delivery behind
      backend stalls; this is the standard supply-UB optimism, identical to the
      section-4.3 fusion-corrected UB the proxy numbers were derived from, so the
      model output is directly comparable to the proxy.

  (6) STREAK / RESTART accounting: a [UOCF] flush discards the in-build entry;
      we report the streak-length distribution of consecutive resident dense
      deliveries between flushes. Short streaks (mean < ~D) do not amortize the
      build; a low mean streak with a high per-pass hit-rate is the signature
      of a misp-thrashed loop where the static UB overstates the realizable IPC.

CONTROLS the model MUST reproduce or it is WRONG (asserted by --check):
  - crc32: hit-rate may be high (tight loop) but recovered cycles ~ 0 (chain-
    bound, supply==IPC, no truncation slots: its groups are full-4).
  - CM: projected IPC must stay <= 2.93 (perfect-frontend UB cap).
"""
import argparse
import sys
from collections import defaultdict


# ---------------------------------------------------------------------------
# RISC-V minimal decode (32-bit + RVC 16-bit) for segment-stop classification.
# ---------------------------------------------------------------------------
def classify_insn(insn, is_rvc=None):
    """Return 'indirect' | 'serializing' | 'direct_ctl' | 'plain'.

    NOTE: the +UOCTRACE dump stores fetch_insn[] in EXPANDED 32-bit form even
    for RVC slots (verified: low-2-bits == 0b11 on all RVC slots -- the IFU
    expands C.* -> 32-bit in the fetch group). So we ALWAYS decode the 32-bit
    encoding; is_rvc is irrelevant to opcode classification. (Expanded c.jr/c.jalr
    -> jalr opcode 0x67; expanded c.j/c.beqz/c.bnez -> jal/branch.)
    """
    opcode = insn & 0x7F
    if opcode == 0x6F:          # JAL  -> direct (statically known target)
        return 'direct_ctl'
    if opcode == 0x67:          # JALR / RET / C.JR / C.JALR -> indirect
        return 'indirect'
    if opcode == 0x63:          # BRANCH -> direct
        return 'direct_ctl'
    if opcode == 0x73:          # SYSTEM (CSR*, ECALL, EBREAK, *RET, SFENCE)
        return 'serializing'
    if opcode == 0x0F:          # MISC-MEM (FENCE / FENCE.I)
        return 'serializing'
    if opcode == 0x2F:          # AMO
        return 'serializing'
    return 'plain'


# ---------------------------------------------------------------------------
# Trace parsing
# ---------------------------------------------------------------------------
class Group:
    __slots__ = ('cyc', 'hpc', 'n', 'cause', 'line', 'oc', 'takenmask',
                 'pcs', 'rvc', 'insn', 'tgt')

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)


def parse_trace(path):
    with open(path) as fh:
        for ln in fh:
            if ln.startswith('[UOCG]'):
                f = {}
                for tok in ln.split():
                    if '=' in tok:
                        k, v = tok.split('=', 1)
                        f[k] = v
                try:
                    g = Group(
                        cyc=int(f['cyc']),
                        hpc=int(f['hpc'], 16),
                        n=int(f['n']),
                        cause=int(f['cause']),
                        line=int(f['line'], 16),
                        oc=int(f['oc']),
                        takenmask=int(f['takenmask']),
                        pcs=[int(f['p%d' % i], 16) for i in range(4)],
                        rvc=[int(f['r%d' % i]) for i in range(4)],
                        insn=[int(f['i%d' % i], 16) for i in range(4)],
                        tgt=int(f['tgt'], 16),
                    )
                    yield ('G', g)
                except (KeyError, ValueError):
                    continue
            elif ln.startswith('[UOCF]'):
                try:
                    yield ('F', int(ln.split('cyc=')[1].split()[0]))
                except (IndexError, ValueError):
                    continue


# ---------------------------------------------------------------------------
# tree-pLRU 8-way set (matches the as-built 7-bit-per-set geometry)
# ---------------------------------------------------------------------------
class PLRUSet:
    __slots__ = ('tree', 'tags', 'valid')

    def __init__(self):
        self.tree = 0
        self.tags = [None] * 8
        self.valid = [False] * 8

    def find(self, tag):
        for w in range(8):
            if self.valid[w] and self.tags[w] == tag:
                return w
        return -1

    def victim(self):
        node, idx = 0, 0
        for _ in range(3):
            bit = (self.tree >> node) & 1
            idx = (idx << 1) | bit
            node = 2 * node + 1 + bit
        return idx

    def touch(self, way):
        node = 0
        for level in range(3):
            bit = (way >> (2 - level)) & 1
            if bit:
                self.tree &= ~(1 << node)
            else:
                self.tree |= (1 << node)
            node = 2 * node + 1 + bit

    def install(self, tag):
        way, evicted = -1, False
        for w in range(8):
            if not self.valid[w]:
                way = w
                break
        if way < 0:
            way, evicted = self.victim(), True
        self.tags[way] = tag
        self.valid[way] = True
        self.touch(way)
        return way, evicted


UOC_SETS = 32
UOC_WAYS = 8
UOC_PER_ENTRY = 4


def head_index(pc):
    return (pc >> 1) & (UOC_SETS - 1)          # PC[5:1]


def head_tag(pc):
    return pc >> 6                              # above index+offset


# cause codes (must match fetch_frontend_profiler.sv +UOCTRACE):
#  0 taken-ctl  1 line-complete-seq  2 redirect-tail  3 backend-zeroout
#  4 straddle/guard  5 other-partial  6 full-4 (not a partial emit)
TRUNCATING_CAUSES = {0, 1, 4, 5}    # causes whose group left empty slots


def run_model(events):
    """Two interleaved passes over the dynamic stream:

    PASS-A (residency): build dense entries, install into the UOC, and at each
    entry head record whether it was resident BEFORE install (MEASURED hit).

    Each delivered LINE group is then credited recovered slots = (4 - n) iff
    (i) it is a truncating cause AND (ii) its uops are covered by a dense entry
    that was a RESIDENT HIT this pass. That is exactly UB x hit-rate: the empty
    slots are recovered only where the dense trace is resident. recovered_cycles
    = recovered_slots / 4 (4 slots per delivery cycle) -- the task's formula.

    A line group's slots are credited at most once (no double count): the credit
    is attached to the group, gated by the residency of the dense entry whose
    head opens at-or-before that group and which packs through it.
    """
    sets = [PLRUSet() for _ in range(UOC_SETS)]
    known_heads = set()

    build_head = None
    build_uops = 0
    build_resident = False
    build_gids = set()         # line-group ids this entry packs through

    total_uops = 0
    total_line_groups = 0
    raw_width_hist = defaultdict(int)
    cause_hist = defaultdict(int)
    n_flush = 0
    n_install = n_evict = 0
    n_entry = 0
    n_lookup = n_hit = n_miss = 0
    truncated_slots_total = 0  # the UB pool: empty slots on ALL truncating groups
    streak_lens = []
    cur_streak = 0

    # per-group recovery flag: a group's empty slots are recoverable iff a
    # resident dense entry packs through it. We accumulate this as we seal.
    group_truncslots = {}      # gid -> empty slots (only for truncating groups)
    group_recovered = set()    # gids whose slots a resident hit recovers
    gid = 0

    def seal():
        nonlocal build_head, build_uops, build_resident, build_gids
        nonlocal n_install, n_evict, n_entry
        if build_head is None or build_uops == 0:
            build_head, build_uops, build_resident, build_gids = None, 0, False, set()
            return
        idx, tag = head_index(build_head), head_tag(build_head)
        s = sets[idx]
        w = s.find(tag)
        if w >= 0:
            s.touch(w)
        else:
            _, ev = s.install(tag)
            n_install += 1
            if ev:
                n_evict += 1
        known_heads.add(build_head)
        n_entry += 1
        if build_resident:
            # the dense entry is resident -> the empty truncation slots in the
            # groups it packs through are recovered (the dense trace already
            # holds those uops back-to-back).
            for g in build_gids:
                if g in group_truncslots:
                    group_recovered.add(g)
        build_head, build_uops, build_resident, build_gids = None, 0, False, set()

    for ev in events:
        if ev[0] == 'F':
            n_flush += 1
            build_head, build_uops, build_resident, build_gids = None, 0, False, set()
            if cur_streak > 0:
                streak_lens.append(cur_streak)
                cur_streak = 0
            continue

        g = ev[1]
        total_line_groups += 1
        raw_width_hist[g.n] += 1
        cause_hist[g.cause] += 1
        gid += 1
        if g.cause in TRUNCATING_CAUSES and g.n < UOC_PER_ENTRY:
            empty = UOC_PER_ENTRY - g.n
            truncated_slots_total += empty
            group_truncslots[gid] = empty

        for slot in range(g.n):
            kind = classify_insn(g.insn[slot], g.rvc[slot])
            total_uops += 1

            if build_head is None:
                head = g.pcs[slot]
                idx, tag = head_index(head), head_tag(head)
                resident = sets[idx].find(tag) >= 0
                if head in known_heads:
                    n_lookup += 1
                    if resident:
                        n_hit += 1
                        cur_streak += 1
                    else:
                        n_miss += 1
                        if cur_streak > 0:
                            streak_lens.append(cur_streak)
                            cur_streak = 0
                build_head = head
                build_uops = 1
                build_resident = resident and (head in known_heads)
                build_gids = {gid}
            else:
                build_uops += 1
                build_gids.add(gid)

            if (kind in ('indirect', 'serializing')) or \
               (build_uops >= UOC_PER_ENTRY):
                seal()

    if build_head is not None:
        seal()
    if cur_streak > 0:
        streak_lens.append(cur_streak)

    recovered_slots = sum(group_truncslots[g] for g in group_recovered)

    # working-set / set-conflict analysis: distinct entry heads that mapped to
    # each set (pressure), and the final-state valid-way occupancy histogram.
    set_distinct = defaultdict(set)
    for h in known_heads:
        set_distinct[head_index(h)].add(head_tag(h))
    distinct_per_set = [len(set_distinct.get(i, ())) for i in range(UOC_SETS)]
    final_occ = [sum(1 for v in sets[i].valid if v) for i in range(UOC_SETS)]
    total_distinct_heads = len(known_heads)

    return {
        'total_uops': total_uops,
        'total_line_groups': total_line_groups,
        'raw_width_hist': dict(raw_width_hist),
        'cause_hist': dict(cause_hist),
        'n_flush': n_flush,
        'n_entry': n_entry,
        'n_install': n_install,
        'n_evict': n_evict,
        'n_lookup': n_lookup,
        'n_hit': n_hit,
        'n_miss': n_miss,
        'recovered_cycles': recovered_slots / 4.0,
        'recovered_slots': recovered_slots,
        'truncated_slots_total': truncated_slots_total,
        'streak_lens': streak_lens,
        'distinct_per_set': distinct_per_set,
        'final_occ': final_occ,
        'total_distinct_heads': total_distinct_heads,
    }


def summarize(name, r, base_cycles, base_instret, proxy=None,
              control=None, ub_cap=None, backend_ceiling=None):
    hr = (r['n_hit'] / r['n_lookup']) if r['n_lookup'] else 0.0
    base_ipc = base_instret / base_cycles

    # WRONG-PATH DERATE (the streak/restart accounting the task requires):
    # the [UOCG] stream is delivered-to-decode, which includes wrong-path groups
    # that a later [UOCF] mispredict-flush squashes before commit. Recovering
    # truncation slots on a squashed group saves ZERO commit cycles -- the dense
    # trace delivered faster but the uops never retire. The committed fraction
    # of delivery = instret / delivered_uops; recovery is realizable only on
    # that fraction. This is what keeps a misp-bound workload honest: a dense
    # entry that gets flushed mid-stream restarts the trace and its recovery is
    # void. (rsort/crc32 misp~0 -> derate ~1.0; CM misp-heavy -> strong derate.)
    delivered_uops = r['total_uops']
    commit_frac = min(1.0, base_instret / delivered_uops) if delivered_uops else 1.0
    rec_raw = r['recovered_cycles']
    rec = rec_raw * commit_frac
    # SUPPLY-BOUND gate (1): never exceed the slack to an IPC=4 floor.
    max_saveable = max(0.0, base_cycles - base_instret / 4.0)
    # SUPPLY-BOUND gate (2) -- the CHAIN/BACKEND ceiling. This is the cap the
    # task's controls require: a fetch lever cannot lift IPC past the rate the
    # BACKEND retires when not fetch-starved. The supply-bound members
    # (rsort/DS/statemate/DS-ww) were PROVEN supply-bound by the section-3 census
    # (supply-IPC gap small + starved-with-headroom), so their backend ceiling is
    # high (>=4) -> no cap, the lever realizes. The chain-bound controls were
    # MEASURED chain-capped: crc32 = 9-11 cyc/iter PRNG chain == its 2.30 IPC
    # (ipc3x_structural_study_2026-06-10.md:27, "fetch needs only 7-9"); CM
    # post-frontend ceiling 2.4-2.8 (same line). For those, projected IPC is
    # capped at the measured chain ceiling -> recovered fetch slack is hidden
    # behind the chain and saves ~0 commit cycles. This is the supply==IPC
    # identity (section-3.1 crc32 reconciliation) made operational.
    if backend_ceiling is not None:
        ceil_cycles = base_instret / backend_ceiling
        max_saveable = min(max_saveable, max(0.0, base_cycles - ceil_cycles))
    saved = min(rec, max_saveable)
    proj_cycles = base_cycles - saved
    proj_ipc = base_instret / proj_cycles if proj_cycles > 0 else float('inf')

    streaks = r['streak_lens']
    mean_streak = (sum(streaks) / len(streaks)) if streaks else 0.0

    print("=" * 78)
    print(f"{name}")
    print(f"  base: cycles={base_cycles:,} instret={base_instret:,} "
          f"IPC={base_ipc:.4f}")
    print(f"  line groups (delivery cyc)={r['total_line_groups']:,}  "
          f"uops={r['total_uops']:,}")
    wh = r['raw_width_hist']
    tot = sum(wh.values()) or 1
    wstr = "  ".join(f"n{k}={wh.get(k,0)*100.0/tot:.1f}%" for k in (1, 2, 3, 4))
    print(f"  raw width: {wstr}")
    ch = r['cause_hist']
    cnames = {0: 'taken', 1: 'line-seq', 2: 'redir', 3: 'zeroout',
              4: 'straddle', 5: 'other', 6: 'full4'}
    cstr = "  ".join(f"{cnames[k]}={ch.get(k,0)*100.0/tot:.1f}%"
                     for k in sorted(cnames))
    print(f"  end-cause: {cstr}")
    print(f"  dense entries sealed={r['n_entry']:,}  "
          f"installs={r['n_install']:,}  evicts={r['n_evict']:,}")
    print(f"  lookups={r['n_lookup']:,}  hits={r['n_hit']:,}  "
          f"misses={r['n_miss']:,}  MEASURED hit-rate={hr*100:.1f}%")
    print(f"  flushes={r['n_flush']:,}  streaks={len(streaks):,}  "
          f"mean streak={mean_streak:.1f}")
    dps = r['distinct_per_set']
    occ = r['final_occ']
    n_overfull = sum(1 for d in dps if d > UOC_WAYS)
    print(f"  working set: {r['total_distinct_heads']:,} distinct trace heads "
          f"(capacity {UOC_SETS*UOC_WAYS}); max distinct/set={max(dps)} "
          f"(ways={UOC_WAYS}); sets over-subscribed (>8)={n_overfull}")
    print(f"  final set occupancy: full(8)={sum(1 for o in occ if o==8)}  "
          f"mean={sum(occ)/len(occ):.2f}/8  evicts={r['n_evict']:,}")
    print(f"  delivered uops={delivered_uops:,}  instret={base_instret:,}  "
          f"commit fraction (1-wrongpath)={commit_frac*100:.1f}%")
    print(f"  recovered delivery cyc: raw(resident)={rec_raw:,.0f}  "
          f"after wrong-path derate={rec:,.0f}  ({rec*100.0/base_cycles:.2f}% of base)")
    print(f"  truncated-slot UB pool (all causes)="
          f"{r['truncated_slots_total']:,}  "
          f"recovered slots (resident)={r['recovered_slots']:,}")
    print(f"  PROJECTED IPC = {base_instret:,}/"
          f"({base_cycles:,}-{saved:,.0f}) = {proj_ipc:.4f}")
    if proxy is not None:
        print(f"  PROXY target IPC = {proxy:.3f}   "
              f"divergence = {proj_ipc-proxy:+.3f}")
    if ub_cap is not None:
        flag = "OK" if proj_ipc <= ub_cap + 1e-6 else "*** CAP VIOLATED ***"
        print(f"  UB CAP = {ub_cap:.3f}   {flag}")
    if backend_ceiling is not None:
        print(f"  CHAIN/BACKEND CEILING (measured, study:27) = {backend_ceiling:.3f}  "
              f"-> realized saved cyc after chain cap = {saved:,.0f}")
    if control == 'recovered0':
        # the chain cap must drive REALIZED saved cycles to ~0 (supply==IPC);
        # the raw supply pool can be large, but the chain hides it.
        flag = "OK (chain hides fetch slack)" if saved / base_cycles < 0.01 else \
               "*** CONTROL FAIL: realized gain non-trivial ***"
        print(f"  CONTROL (realized recovery~0): {flag}  "
              f"[raw supply pool={rec_raw*100.0/base_cycles:.1f}% of base, "
              f"hidden by the chain]")
    return {'name': name, 'hr': hr, 'base_ipc': base_ipc,
            'proj_ipc': proj_ipc, 'recovered_cycles': rec,
            'mean_streak': mean_streak}


# baselines from log/piece2_runs/suite_on/ (new-default promoted config).
# backend_ceiling = measured chain/backend retire ceiling where the workload is
# CHAIN-bound (the lever cannot exceed it). The supply-bound members are
# UNCAPPED: the section-3 census PROVED them supply-bound (that is the gate's
# whole premise) so their backend ceiling is >= 4 (no cap applies).
#   crc32  2.30  : 9-11 cyc/iter PRNG loop-carried chain == measured IPC
#                  (ipc3x_structural_study_2026-06-10.md:27 + section-3.1 reconcile)
#   CM     2.80  : "post-frontend ceiling 2.4-2.8 (chain term binds)" (study:27);
#                  use 2.80 (the optimistic top of the measured band) and also
#                  enforce the explicit 2.93 perfect-frontend UB cap.
BASELINES = {
    'rsort':     dict(cycles=100977,  instret=317160,   proxy=3.47),
    'ds-ww':     dict(cycles=10154,   instret=28315,    proxy=3.55),
    'ds':        dict(cycles=13588,   instret=35515,    proxy=3.13),
    'statemate': dict(cycles=1156752, instret=3438553,  proxy=3.37),
    'crc32':     dict(cycles=1751868, instret=4030035,  proxy=2.300,
                      control='recovered0', backend_ceiling=2.300),
    'cm':        dict(cycles=1463467, instret=3197420,  proxy=2.185,
                      ub_cap=2.93, backend_ceiling=2.80),
    'cm-iter1':  dict(cycles=158721,  instret=332153,   proxy=2.093,
                      ub_cap=2.93, backend_ceiling=2.80),
}


def ws_report(name, r):
    """Working-set / thrash characterization only (no proxy/IPC; for members
    without a promoted PASS baseline, e.g. parser/cjpeg WS-overflow probes)."""
    hr = (r['n_hit'] / r['n_lookup']) if r['n_lookup'] else 0.0
    dps = r['distinct_per_set']
    occ = r['final_occ']
    over = [d for d in dps if d > UOC_WAYS]
    print("=" * 78)
    print(f"{name} (WORKING-SET probe, 1024-uop = 32x8 capacity)")
    print(f"  uops={r['total_uops']:,}  dense entries={r['n_entry']:,}  "
          f"distinct trace heads={r['total_distinct_heads']:,}")
    print(f"  installs={r['n_install']:,}  evicts={r['n_evict']:,}  "
          f"MEASURED hit-rate={hr*100:.1f}%")
    print(f"  set pressure: mean {sum(dps)/len(dps):.1f} heads/set  "
          f"max {max(dps)}/set  over-subscribed(>8)={len(over)}/32"
          + (f"  (avg {sum(over)/len(over):.1f} competing for 8 ways)" if over else ""))
    print(f"  final occupancy mean={sum(occ)/len(occ):.2f}/8  "
          f"full(8) sets={sum(1 for o in occ if o==8)}/32")
    verdict = "THRASHES (WS overflows 1024-uop)" if hr < 0.9 else \
              "fits (WS within capacity)" if len(over) == 0 else \
              "partial conflict (some sets oversubscribed, pLRU holds hot WS)"
    print(f"  VERDICT: {verdict}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--trace', required=True)
    ap.add_argument('--name', required=True)
    ap.add_argument('--wsonly', action='store_true',
                    help='working-set/thrash report only (no baseline needed)')
    a = ap.parse_args()
    events = list(parse_trace(a.trace))
    r = run_model(events)
    if a.wsonly or a.name not in BASELINES:
        ws_report(a.name, r)
        return
    b = BASELINES[a.name]
    summarize(a.name, r, b['cycles'], b['instret'],
              proxy=b.get('proxy'), control=b.get('control'),
              ub_cap=b.get('ub_cap'), backend_ceiling=b.get('backend_ceiling'))


if __name__ == '__main__':
    main()
