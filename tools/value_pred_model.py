#!/usr/bin/env python3
"""value_pred_model.py -- OFFLINE value-prediction feasibility model.

Replays a captured (or analytically-generated) value stream for a binding
loop-carried recurrence PC through a suite of practical value predictors and
reports, per predictor:

  accuracy  = correct_predictions / confident_predictions
  coverage  = confident_predictions / total_dynamic_instances
  payoff    = accuracy * coverage  (fraction of instances correctly + confidently predicted)

Predictors modelled (industry-standard VP literature, Perais/Seznec VTAGE,
Sazeides/Smith FCM, Gabbay/Mendelson last-value, Eickemeyer/Vassiliadis stride):

  last-value   : predict v[i] == v[i-1]
  stride       : predict v[i] == v[i-1] + (v[i-1]-v[i-2])     (2-delta-confident)
  2delta       : same, with a confidence requiring the stride to repeat 2x
  fcm1         : finite-context order-1 -- table keyed by last value -> next value
  fcm2         : finite-context order-2 -- table keyed by (v[i-2],v[i-1]) -> next
  vtage        : context = hash of a sliding window of recent values (order-k),
                 PER-CONTEXT confidence counter (the realistic VP design)

Confidence model: each predictor entry carries a saturating up/down counter
(0..CONF_MAX). A prediction is "confident" (issued speculatively) only when
counter >= CONF_THRESH. Correct -> +1 (sat), wrong -> reset to 0 (the standard
VP forward-probabilistic confidence: a single miss kills confidence, because a
misprediction costs a selective replay).

Usage:
  value_pred_model.py --stream crc32_seed [--n 174080] [--conf-max 7] [--conf-thresh 7]
  value_pred_model.py --file <valtrace.log> --pc 0x.. [...]
"""
import argparse, sys, hashlib

# ---------------------------------------------------------------------------
# Analytic value-stream generators for the chain-band binding recurrences.
# These are EXACT (deterministic function of the binary + known init state),
# so no RTL trace is required for the arithmetic/PRNG recurrences.
# ---------------------------------------------------------------------------

def stream_crc32_seed(n):
    """crc32 binding recurrence = the LCG 'seed' carried ld->mul->add->mask->sd.
    rand_beebs: seed = (seed*0x41c64e6d + 0x3039) & 0x7fffffff.
    benchmark_body(170,1): srand_beebs(0) reseeds seed=0 before each 1024-iter
    inner loop; outer runs 170 times -> the SAME 1024-long LCG window repeats."""
    A, C, M = 0x41c64e6d, 0x3039, 0x7fffffff
    out = []
    OUTER = 170
    INNER = 1024
    for _ in range(OUTER):
        seed = 0  # srand_beebs(0)
        for _ in range(INNER):
            seed = (seed * A + C) & M
            out.append(seed)
            if len(out) >= n:
                return out
    return out[:n]

def stream_crc32_s0(n):
    """crc32 SECONDARY carried value = the running crc 's0' (xor-shift-table).
    s0 starts 0xffffffff; each iter: a5=tab[(s0^rng)&0xff]; s0=(s0>>8)^a5.
    This is loop-carried but depends on the (random) rng -> effectively random."""
    A, C, M = 0x41c64e6d, 0x3039, 0x7fffffff
    # crc32 standard table (poly 0xedb88320)
    tab = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (0xedb88320 ^ (c >> 1)) if (c & 1) else (c >> 1)
        tab.append(c & 0xffffffff)
    out = []
    OUTER, INNER = 170, 1024
    for _ in range(OUTER):
        seed = 0
        s0 = 0xffffffff
        for _ in range(INNER):
            seed = (seed * A + C) & M
            rng = seed >> 16
            idx = (s0 ^ rng) & 0xff
            s0 = ((s0 >> 8) ^ tab[idx]) & 0xffffffff
            out.append(s0)
            if len(out) >= n:
                return out
    return out[:n]

def stream_lcg_generic(n, a, c, m, reseed_period=None, reseed_val=0):
    out = []
    seed = reseed_val
    for i in range(n):
        if reseed_period and i % reseed_period == 0:
            seed = reseed_val
        seed = (seed * a + c) % m
        out.append(seed)
    return out

# ---------------------------------------------------------------------------
# Predictors
# ---------------------------------------------------------------------------

class SatConf:
    __slots__ = ('v',)
    def __init__(self): self.v = 0
    def up(self, mx): self.v = min(mx, self.v + 1)
    def reset(self): self.v = 0

def run_predictor(stream, kind, conf_max, conf_thresh, ctx_order=4):
    """Return (confident, correct, total)."""
    n = len(stream)
    confident = 0
    correct = 0
    total = 0
    # state
    last = None
    last2 = None
    stride = None
    stride_conf = SatConf()
    lv_conf = SatConf()
    fcm = {}          # context -> (predicted_value, SatConf)
    MASK = (1 << 64) - 1

    for i, v in enumerate(stream):
        pred = None
        conf = None
        if kind == 'last-value':
            if last is not None:
                pred = last
                conf = lv_conf
        elif kind in ('stride', '2delta'):
            if last is not None and stride is not None:
                pred = (last + stride) & MASK
                conf = stride_conf
        elif kind in ('fcm1', 'fcm2', 'vtage'):
            if kind == 'fcm1':
                key = last
            elif kind == 'fcm2':
                key = (last2, last)
            else:  # vtage: hash of last ctx_order values
                key = tuple(stream[max(0, i - ctx_order):i])
            ent = fcm.get(key)
            if ent is not None:
                pred, conf = ent[0], ent[1]
        # issue?
        total += 1
        if pred is not None and conf is not None and conf.v >= conf_thresh:
            confident += 1
            if pred == v:
                correct += 1
        # ---- update state AFTER (verify-at-execute) ----
        if kind == 'last-value':
            if last is not None:
                if last == v: lv_conf.up(conf_max)
                else: lv_conf.reset()
        elif kind in ('stride', '2delta'):
            if last is not None:
                new_stride = (v - last) & MASK
                if stride is not None and new_stride == stride:
                    stride_conf.up(conf_max)
                else:
                    if kind == '2delta':
                        # 2-delta: only adopt new stride, reset confidence
                        stride_conf.reset()
                    else:
                        stride_conf.reset()
                    stride = new_stride
                if stride is None:
                    stride = new_stride
        elif kind in ('fcm1', 'fcm2', 'vtage'):
            if kind == 'fcm1':
                key = last
            elif kind == 'fcm2':
                key = (last2, last)
            else:
                key = tuple(stream[max(0, i - ctx_order):i])
            if key is not None or kind == 'vtage':
                ent = fcm.get(key)
                if ent is None:
                    fcm[key] = [v, SatConf()]
                else:
                    if ent[0] == v:
                        ent[1].up(conf_max)
                    else:
                        ent[0] = v
                        ent[1].reset()
        last2 = last
        last = v
    return confident, correct, total


PREDICTORS = ['last-value', 'stride', '2delta', 'fcm1', 'fcm2', 'vtage']

def analyze(stream, label, conf_max, conf_thresh, ctx_order):
    n = len(stream)
    distinct = len(set(stream))
    print(f"\n=== {label} ===")
    print(f"  instances={n}  distinct_values={distinct}  "
          f"distinct_frac={distinct/n:.4f}")
    # repeat structure
    print(f"  {'predictor':<12} {'coverage':>9} {'accuracy':>9} {'payoff':>9}")
    best = (None, 0.0, 0.0, 0.0)
    results = {}
    for k in PREDICTORS:
        conf, corr, tot = run_predictor(stream, k, conf_max, conf_thresh, ctx_order)
        cov = conf / tot if tot else 0.0
        acc = corr / conf if conf else 0.0
        payoff = corr / tot if tot else 0.0
        results[k] = (cov, acc, payoff)
        print(f"  {k:<12} {cov:>9.4f} {acc:>9.4f} {payoff:>9.4f}")
        if payoff > best[3]:
            best = (k, cov, acc, payoff)
    print(f"  BEST: {best[0]}  coverage={best[1]:.4f} accuracy={best[2]:.4f} payoff={best[3]:.4f}")
    return results, best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stream', help='built-in stream name')
    ap.add_argument('--file', help='valtrace log file')
    ap.add_argument('--pc', help='hex PC filter for --file')
    ap.add_argument('--n', type=int, default=174080)
    ap.add_argument('--conf-max', type=int, default=7)
    ap.add_argument('--conf-thresh', type=int, default=7)
    ap.add_argument('--ctx-order', type=int, default=4)
    args = ap.parse_args()

    if args.stream == 'crc32_seed':
        s = stream_crc32_seed(args.n)
        analyze(s, 'crc32 LCG seed-recurrence (binding chain)', args.conf_max, args.conf_thresh, args.ctx_order)
    elif args.stream == 'crc32_s0':
        s = stream_crc32_s0(args.n)
        analyze(s, 'crc32 crc-state s0 (secondary carried)', args.conf_max, args.conf_thresh, args.ctx_order)
    elif args.stream == 'all':
        analyze(stream_crc32_seed(args.n), 'crc32 LCG seed-recurrence', args.conf_max, args.conf_thresh, args.ctx_order)
        analyze(stream_crc32_s0(args.n), 'crc32 crc-state s0', args.conf_max, args.conf_thresh, args.ctx_order)
    elif args.file:
        vals = []
        pcf = int(args.pc, 16) if args.pc else None
        import re
        pat = re.compile(r'\[VALTRACE pc=([0-9a-fA-F]+) val=([0-9a-fA-F]+)\]')
        with open(args.file, errors='replace') as f:
            for ln in f:
                m = pat.search(ln)
                if not m: continue
                pc = int(m.group(1), 16)
                if pcf is not None and pc != pcf: continue
                vals.append(int(m.group(2), 16))
        analyze(vals[:args.n], f'file:{args.file} pc={args.pc}', args.conf_max, args.conf_thresh, args.ctx_order)
    else:
        ap.error('need --stream or --file')

if __name__ == '__main__':
    main()
