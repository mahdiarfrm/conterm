import itertools
import sys
import time

# Paced terminal stream; sleep-per-line from argv (0 = full rate).
delay = float(sys.argv[1]) if len(sys.argv) > 1 else 0.03
for i in itertools.count():
    pad = "x" * (10 + (i * 7) % 60)
    print(f"\033[3{(i % 6) + 1}mstream {i:07d}\033[0m {pad} lorem ipsum dolor sit amet")
    if delay:
        time.sleep(delay)
