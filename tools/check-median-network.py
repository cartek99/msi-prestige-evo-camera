#!/usr/bin/env python3
"""Prove that the 19 s2() swaps in shaders/impulse3x3.frag leave the median of 9 in p4.
Zero/one principle: a compare-swap network that is right for all 2^9 zero/one inputs is right for
every input. The random test is a second, independent check."""
import itertools, random, re, sys
from pathlib import Path
src = Path(__file__).resolve().parent.parent.joinpath("shaders/impulse3x3.frag").read_text()
pairs = [(int(a), int(b)) for a, b in re.findall(r"s2\(p(\d), p(\d)\)", src)]
def median(v):
    p = list(v)
    for a, b in pairs:
        p[a], p[b] = min(p[a], p[b]), max(p[a], p[b])
    return p[4]
zero_one = all(median(v) == sorted(v)[4] for v in itertools.product([0, 1], repeat=9))
rand = all(median(v) == sorted(v)[4] for v in ([random.random() for _ in range(9)] for _ in range(200000)))
print(f"{len(pairs)} swaps; zero/one proof: {zero_one}; 200000 random: {rand}")
sys.exit(0 if zero_one and rand else 1)
