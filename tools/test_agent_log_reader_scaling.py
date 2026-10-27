#!/usr/bin/env python3
"""Production-reader RSS/time scaling on invented 1, 4 and 16 MiB JSONL records."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent
MIB = 1 << 20


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-path", type=Path, help="Existing Swift debug bin directory")
    parser.add_argument("--recorder-pid", type=int, help="Wait for this authorized recorder to reach <=1 percent CPU before each writer timing case")
    args = parser.parse_args()
    debug = args.build_path or Path(subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=REPO, text=True).strip())
    objects = [p for module in ("Core", "Inbound", "Storage")
               for p in sorted((debug / f"{module}.build").glob("*.swift.o"))]
    assert objects, "Build the package before running the scaling regression"
    with tempfile.TemporaryDirectory(prefix="activityprobe-reader-scaling-") as temporary:
        root = Path(temporary)
        binary = root / "reader"
        subprocess.run(["swiftc", "-I", str(debug / "Modules"),
                        str(REPO / "tools/agent-log-reader-scaling.swift"),
                        *map(str, objects), "-lsqlite3", "-o", str(binary)], cwd=REPO, check=True)

        def cpu():
            result = subprocess.run(["ps", "-o", "%cpu=", "-p", str(args.recorder_pid)], text=True, capture_output=True)
            return float(result.stdout.strip()) if result.stdout.strip() else None

        def measure(shape, size, writer=False):
            start_cpu = None
            if writer and args.recorder_pid:
                while (start_cpu := cpu()) is not None and start_cpu > 1.0:
                    time.sleep(1)

            run = subprocess.run(["/usr/bin/time", "-l", str(binary),
                                  str(root / f"{shape}-{size}-{writer}"), str(size), shape, "writer" if writer else "reader"],
                                 text=True, capture_output=True, check=True, timeout=180)
            result = json.loads(run.stdout)
            if writer and args.recorder_pid:
                result.update(recorderCPUStart=start_cpu, recorderCPUEnd=cpu())
            result["rss"] = int(re.search(r"(\d+)\s+maximum resident set size", run.stderr)[1])
            print(json.dumps(result, sort_keys=True), flush=True)
            return result

        baseline = measure("dense", 0)["rss"]
        for shape in ("dense", "prose", "base64", "unicode", "selected", "flag", "key"):
            measurements = [measure(shape, size * MIB) for size in (1, 4, 16)]
            for result in measurements:
                # Count all reader allocations, including parser/masking temporaries.
                # Fixed runtime/cache headroom avoids allocator/page-size noise.
                # Selected fields, flag serializations and unknown keys can coexist
                # with raw and masked buffers. Keep the original four at 3x;
                # bound the extra selected representations at 5x, rather than
                # dropping their occurrence content to meet a smaller envelope.
                copies = 3 if shape in ("dense", "prose", "base64", "unicode") else 5
                assert result["rss"] <= baseline + copies * result["bytes"] + 24 * MIB, result
            first, middle, last = measurements
            # CPU scaling excludes scheduling contention from concurrent CI builds.
            # The subprocess deadline separately bounds wall time.
            assert middle["cpu"] <= first["cpu"] * 7 + 1, measurements
            assert last["cpu"] <= first["cpu"] * 24 + 2, measurements
        for shape in ("dense", "prose", "selected", "flag", "key"):
            for size in (1, 4, 16):
                result = measure(shape, size * MIB, writer=True)
                assert result["rss"] <= baseline + 9 * result["bytes"] + 32 * MIB, result
                # Preparation is linear in payload size; it must not hold the SQL writer.
                assert result["lockSeconds"] <= 2.0, result
                assert result["lockSeconds"] <= result["appendElapsed"] * 0.5 + 0.1, result
    print("Reader/writer scaling: 21 reader and 15 writer cases passed; temp folder deleted")


if __name__ == "__main__":
    main()
