"""Probe which cores this process tree can use (cpu0-5 = efficiency, cpu6-9 = performance on Apple M5)."""
import multiprocessing as mp
import sys
import time

import psutil


def spin(seconds):
    t = time.time()
    while time.time() - t < seconds:
        pass


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    psutil.cpu_percent(percpu=True)
    time.sleep(1.0)
    print("idle   ", psutil.cpu_percent(percpu=True), flush=True)
    procs = [mp.Process(target=spin, args=(4,)) for _ in range(n)]
    for p in procs:
        p.start()
    time.sleep(0.5)
    psutil.cpu_percent(percpu=True)
    time.sleep(2.5)
    print(f"{n} spin ", psutil.cpu_percent(percpu=True), flush=True)
    for p in procs:
        p.join()
