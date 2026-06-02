import subprocess, sys, textwrap, os, json

TOOL = os.path.join(os.path.dirname(__file__), "paged_ipc_profile.py")

SYNTHETIC_LOG = textwrap.dedent("""\
[LINUX_STATUS] cyc=1000000 mcycle=1000000 minstret=2000000 priv=3 satp=0000000000000000 rob_empty=0 fe_stall=0
[PERF_PROFILE] cyc=1000000 itlb_lookups=100 itlb_misses=2 ptw_walks_itlb=2 ptw_walks_dtlb=1 ptw_busy_cycles=40 ptw_faults=0 fe_stall_total=10 fe_stall_xlate=2 fe_stall_icache=3 fe_stall_backend=5 flush_commit=1 flush_bru=4 flush_satp=0 dtlb_lookups=80 dtlb_misses=1 dcache_accesses=50 dcache_misses=3
[LINUX_STATUS] cyc=2000000 mcycle=2000000 minstret=2900000 priv=1 satp=8000000000081cbd rob_empty=1 fe_stall=1
[PERF_PROFILE] cyc=2000000 itlb_lookups=200 itlb_misses=120 ptw_walks_itlb=118 ptw_walks_dtlb=5 ptw_busy_cycles=600000 ptw_faults=0 fe_stall_total=520000 fe_stall_xlate=500000 fe_stall_icache=15000 fe_stall_backend=5000 flush_commit=30 flush_bru=12 flush_satp=8 dtlb_lookups=160 dtlb_misses=3 dcache_accesses=120 dcache_misses=20
""")

def run(log_text):
    p = subprocess.run([sys.executable, TOOL, "--stdin", "--json"],
                       input=log_text, capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)

def test_overall_and_paged_ipc():
    r = run(SYNTHETIC_LOG)
    assert abs(r["overall_ipc"] - 1.45) < 1e-6
    paged = [w for w in r["intervals"] if w["mmu_on"]]
    assert len(paged) == 1
    assert abs(paged[0]["ipc"] - 0.9) < 1e-6

def test_attribution_ranks_xlate_first():
    r = run(SYNTHETIC_LOG)
    top = r["paged_attribution"][0]
    assert top["family"] == "fe_stall_xlate"
    assert top["delta"] == 500000

def test_sanity_invariants_pass():
    r = run(SYNTHETIC_LOG)
    assert r["sanity"]["itlb_misses_le_lookups"] is True
    assert r["sanity"]["fe_stall_split_sums"] is True
