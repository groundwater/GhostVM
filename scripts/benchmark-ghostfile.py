#!/usr/bin/env python3

import argparse
import fcntl
import hashlib
import os
import random
import statistics
import time


F_NOCACHE = getattr(fcntl, "F_NOCACHE", 48)
CHUNK_SIZE = 1024 * 1024


def timed(operation):
    started = time.perf_counter()
    result = operation()
    return time.perf_counter() - started, result


def read_sequential(path, uncached):
    total = 0
    descriptor = os.open(path, os.O_RDONLY)
    try:
        if uncached:
            fcntl.fcntl(descriptor, F_NOCACHE, 1)
        while True:
            chunk = os.read(descriptor, CHUNK_SIZE)
            if not chunk:
                break
            total += len(chunk)
    finally:
        os.close(descriptor)
    return total


def read_random(path, offsets, uncached):
    digest = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY)
    try:
        if uncached:
            fcntl.fcntl(descriptor, F_NOCACHE, 1)
        for offset in offsets:
            digest.update(os.pread(descriptor, 4096, offset))
    finally:
        os.close(descriptor)
    return digest.digest()


def benchmark_pair(source_path, mount_path, samples, operation):
    durations = {"regular": [], "fskit": []}
    results = {"regular": [], "fskit": []}
    paths = {"regular": source_path, "fskit": mount_path}
    for sample in range(samples):
        order = ("regular", "fskit") if sample % 2 == 0 else ("fskit", "regular")
        for label in order:
            duration, result = timed(lambda label=label: operation(paths[label]))
            durations[label].append(duration)
            results[label].append(result)
    return durations, results


def print_throughput(label, durations, byte_count):
    source_seconds = statistics.median(durations["regular"])
    mount_seconds = statistics.median(durations["fskit"])
    mib = byte_count / (1024 * 1024)
    source_rate = mib / source_seconds
    mount_rate = mib / mount_seconds
    print(
        f"{label}: regular={source_rate:.1f} MiB/s "
        f"fskit={mount_rate:.1f} MiB/s ratio={mount_rate / source_rate:.3f}x"
    )


def print_latency(label, durations, operations_per_sample):
    source_us = statistics.median(durations["regular"]) * 1_000_000 / operations_per_sample
    mount_us = statistics.median(durations["fskit"]) * 1_000_000 / operations_per_sample
    print(
        f"{label}: regular={source_us:.1f} us/op "
        f"fskit={mount_us:.1f} us/op ratio={mount_us / source_us:.2f}x"
    )


def main():
    parser = argparse.ArgumentParser(description="Compare regular file I/O with a GhostFile FSKit mount")
    parser.add_argument("source_file")
    parser.add_argument("mounted_file")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--random-reads", type=int, default=1000)
    parser.add_argument("--metadata-ops", type=int, default=5000)
    parser.add_argument("--directory-ops", type=int, default=2000)
    parser.add_argument(
        "--sequential-only",
        action="store_true",
        help="time only the first F_NOCACHE sequential read (useful with a fresh file identity)",
    )
    args = parser.parse_args()

    source_size = os.path.getsize(args.source_file)
    mount_size = os.path.getsize(args.mounted_file)
    if source_size != mount_size:
        raise SystemExit(f"size mismatch: regular={source_size} fskit={mount_size}")

    print(f"file_size={source_size / (1024 * 1024):.1f} MiB samples={args.samples}")

    if not args.sequential_only:
        randomizer = random.Random(0x47484F535446494C)
        max_offset = max(0, source_size - 4096)
        offsets = [randomizer.randrange(0, max_offset + 1) for _ in range(args.random_reads)]
        random_durations, random_results = benchmark_pair(
            args.source_file,
            args.mounted_file,
            args.samples,
            lambda path: read_random(path, offsets, True),
        )
        if len(set(random_results["regular"] + random_results["fskit"])) != 1:
            raise SystemExit("random-read digest mismatch")
        print_latency("random 4 KiB reads (F_NOCACHE)", random_durations, args.random_reads)

    sequential_durations, sequential_results = benchmark_pair(
        args.source_file,
        args.mounted_file,
        args.samples,
        lambda path: read_sequential(path, True),
    )
    sequential_totals = sequential_results["regular"] + sequential_results["fskit"]
    if set(sequential_totals) != {source_size}:
        raise SystemExit("sequential-read length mismatch")
    print_throughput("sequential reads (F_NOCACHE)", sequential_durations, source_size)

    if args.sequential_only:
        return

    cached_durations, cached_results = benchmark_pair(
        args.source_file,
        args.mounted_file,
        args.samples,
        lambda path: read_sequential(path, False),
    )
    cached_totals = cached_results["regular"] + cached_results["fskit"]
    if set(cached_totals) != {source_size}:
        raise SystemExit("cached sequential-read length mismatch")
    print_throughput("sequential reads (warm cache)", cached_durations, source_size)

    source_directory = os.path.dirname(args.source_file)
    mount_directory = os.path.dirname(args.mounted_file)
    metadata_durations, _ = benchmark_pair(
        args.source_file,
        args.mounted_file,
        args.samples,
        lambda path: [os.stat(path) for _ in range(args.metadata_ops)],
    )
    print_latency("stat", metadata_durations, args.metadata_ops)

    directory_durations, directory_results = benchmark_pair(
        source_directory,
        mount_directory,
        args.samples,
        lambda path: [tuple(sorted(entry.name for entry in os.scandir(path))) for _ in range(args.directory_ops)],
    )
    if directory_results["regular"][-1][-1] != directory_results["fskit"][-1][-1]:
        raise SystemExit("directory listing mismatch")
    print_latency("readdir", directory_durations, args.directory_ops)


if __name__ == "__main__":
    main()
