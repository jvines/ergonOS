"""What this machine's numpy actually does: matmul, FFT and a sampler-shaped
likelihood workload, timed next to the thread configuration it ran under.

ERGON-63: this used to claim it diagnosed thread oversubscription -- numpy
grabbing every core underneath a process pool that already has them. It
can't: there is no multiprocessing.Pool anywhere below, and a single-process
timing cannot observe what happens under one. For which BLAS/OpenMP runtime
is actually loaded and how many threads it holds right now, see `ergon
doctor`, which introspects it with threadpoolctl.

    ergon bench
    ergon bench --json
"""
from __future__ import annotations

import json
import os
import sys
import time


def env_threads():
    keys = ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
            "NUMEXPR_NUM_THREADS", "VECLIB_MAXIMUM_THREADS")
    return {k: os.environ.get(k) for k in keys}


def timeit(fn, repeats=3):
    """Best of N, not mean.

    The mean measures the machine's other tenants -- a browser, an indexer, the
    compositor. The minimum is the closest thing to what the hardware can do,
    which is the number that is comparable between machines and across time.
    """
    best = float("inf")
    for _ in range(repeats):
        t0 = time.perf_counter()
        fn()
        best = min(best, time.perf_counter() - t0)
    return best


def main(argv) -> int:
    as_json = "--json" in argv
    import numpy as np

    results = {}

    n = 2000
    a = np.random.default_rng(0).random((n, n))
    b = np.random.default_rng(1).random((n, n))
    t = timeit(lambda: a @ b)
    # 2n^3 flops for an n*n matmul.
    results["matmul"] = {"n": n, "seconds": t, "gflops": 2 * n**3 / t / 1e9}

    x = np.random.default_rng(2).random(2**22)
    t = timeit(lambda: np.fft.rfft(x))
    results["fft"] = {"n": len(x), "seconds": t}

    # A sampler-shaped workload: many small likelihood calls, which is what
    # MCMC actually is and what a matmul benchmark completely fails to
    # represent. This is latency-bound, not throughput-bound.
    def loglike():
        rng = np.random.default_rng(3)
        d = rng.normal(size=256)
        s = 0.0
        for _ in range(20000):
            s += -0.5 * np.sum((d - 0.1) ** 2)
        return s
    t = timeit(loglike, repeats=1)
    results["likelihood_calls"] = {"calls": 20000, "seconds": t,
                                   "per_second": 20000 / t}

    results["threads"] = env_threads()
    results["cpus"] = os.cpu_count()
    try:
        b = np.show_config("dicts")["Build Dependencies"]["blas"]
        results["blas"] = f"{b.get('name','?')} {b.get('version','')}".strip()
    except Exception:
        results["blas"] = "unknown"

    if as_json:
        print(json.dumps(results, indent=2))
        return 0

    print(f"\n  cpus       {results['cpus']}")
    print(f"  blas       {results['blas']}")
    unset = [k for k, v in results["threads"].items() if v is None]
    if len(unset) == len(results["threads"]):
        print(f"  threads    all unset — numpy will use all {results['cpus']} cores.")
        print( "             Fine alone; catastrophic under a process pool, where it")
        print(f"             becomes {results['cpus']}x{results['cpus']} oversubscription and runs SLOWER")
        print( "             than single-threaded. Set OMP_NUM_THREADS=1 for sampler runs.")
    else:
        shown = ", ".join(f"{k.split('_')[0]}={v}" for k, v in results["threads"].items() if v)
        print(f"  threads    {shown}")
    m, f, l = results["matmul"], results["fft"], results["likelihood_calls"]
    print(f"\n  matmul     {m['n']}x{m['n']}  {m['seconds']*1e3:7.1f} ms   {m['gflops']:6.1f} GFLOP/s")
    print(f"  fft        2^22     {f['seconds']*1e3:7.1f} ms")
    print(f"  likelihood {l['calls']:,} calls  {l['seconds']:5.2f} s   {l['per_second']:,.0f}/s")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
