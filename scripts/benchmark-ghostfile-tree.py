#!/usr/bin/env python3

import argparse
import os
import statistics
import time


def inventory(root):
    files = []
    directories = []
    for current, directory_names, file_names in os.walk(root):
        relative_directory = os.path.relpath(current, root)
        directories.append(relative_directory)
        files.extend(
            os.path.join(relative_directory, name) if relative_directory != "." else name
            for name in file_names
        )
        directory_names.sort()
        file_names.sort()
    return sorted(files), sorted(directories)


def timed(operation):
    started = time.perf_counter()
    result = operation()
    return time.perf_counter() - started, result


def benchmark_pair(native_operation, mounted_operation, samples):
    durations = {"native": [], "fskit": []}
    results = {"native": [], "fskit": []}
    operations = {"native": native_operation, "fskit": mounted_operation}
    for sample in range(samples):
        order = ("native", "fskit") if sample % 2 == 0 else ("fskit", "native")
        for label in order:
            duration, result = timed(operations[label])
            durations[label].append(duration)
            results[label].append(result)
    return durations, results


def print_rate(label, durations, operation_count, unit="ops/s"):
    native_rate = operation_count / statistics.median(durations["native"])
    fskit_rate = operation_count / statistics.median(durations["fskit"])
    print(
        f"{label}: native={native_rate:.1f} {unit} "
        f"fskit={fskit_rate:.1f} {unit} ratio={fskit_rate / native_rate:.3f}x"
    )


def read_files(root, relative_paths):
    byte_count = 0
    checksum = 0
    for relative_path in relative_paths:
        with open(os.path.join(root, relative_path), "rb", buffering=0) as stream:
            contents = stream.read()
        byte_count += len(contents)
        checksum = (checksum + sum(contents)) & 0xFFFFFFFF
    return byte_count, checksum


def stat_files(root, relative_paths):
    return sum(os.stat(os.path.join(root, path)).st_size for path in relative_paths)


def list_directories(root, relative_paths):
    entry_count = 0
    for relative_path in relative_paths:
        path = root if relative_path == "." else os.path.join(root, relative_path)
        with os.scandir(path) as entries:
            entry_count += sum(1 for _ in entries)
    return entry_count


def main():
    parser = argparse.ArgumentParser(
        description="Compare native and GhostFile FSKit file-tree operation rates"
    )
    parser.add_argument("native_root")
    parser.add_argument("mounted_root")
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--small-file-ops", type=int, default=2048)
    parser.add_argument("--stat-ops", type=int, default=8192)
    parser.add_argument("--directory-ops", type=int, default=2048)
    args = parser.parse_args()

    native_files, native_directories = inventory(args.native_root)
    mounted_files, mounted_directories = inventory(args.mounted_root)
    if native_files != mounted_files or native_directories != mounted_directories:
        raise SystemExit("native and mounted tree inventories differ")

    print(f"tree_files={len(native_files)} tree_directories={len(native_directories)}")
    entry_count = len(native_files) + len(native_directories)
    walk_durations, walk_results = benchmark_pair(
        lambda: inventory(args.native_root),
        lambda: inventory(args.mounted_root),
        args.samples,
    )
    if any(result != walk_results["native"][0] for values in walk_results.values() for result in values):
        raise SystemExit("tree inventory changed during benchmark")
    print_rate("recursive tree enumeration", walk_durations, entry_count, "entries/s")

    stat_paths = [native_files[index % len(native_files)] for index in range(args.stat_ops)]
    stat_durations, stat_results = benchmark_pair(
        lambda: stat_files(args.native_root, stat_paths),
        lambda: stat_files(args.mounted_root, stat_paths),
        args.samples,
    )
    if len(set(stat_results["native"] + stat_results["fskit"])) != 1:
        raise SystemExit("stat size totals differ")
    print_rate("small-file stat", stat_durations, len(stat_paths), "IOPS")

    read_paths = native_files[: min(args.small_file_ops, len(native_files))]
    read_durations, read_results = benchmark_pair(
        lambda: read_files(args.native_root, read_paths),
        lambda: read_files(args.mounted_root, read_paths),
        args.samples,
    )
    if len(set(read_results["native"] + read_results["fskit"])) != 1:
        raise SystemExit("small-file contents differ")
    print_rate("open + read small files", read_durations, len(read_paths), "IOPS")
    byte_count = read_results["native"][0][0]
    native_mib = byte_count / statistics.median(read_durations["native"]) / (1024 * 1024)
    fskit_mib = byte_count / statistics.median(read_durations["fskit"]) / (1024 * 1024)
    print(
        f"small-file payload throughput: native={native_mib:.2f} MiB/s "
        f"fskit={fskit_mib:.2f} MiB/s ratio={fskit_mib / native_mib:.3f}x"
    )

    directory_paths = [
        native_directories[index % len(native_directories)] for index in range(args.directory_ops)
    ]
    directory_durations, directory_results = benchmark_pair(
        lambda: list_directories(args.native_root, directory_paths),
        lambda: list_directories(args.mounted_root, directory_paths),
        args.samples,
    )
    if len(set(directory_results["native"] + directory_results["fskit"])) != 1:
        raise SystemExit("directory entry totals differ")
    print_rate("directory listing", directory_durations, len(directory_paths), "IOPS")


if __name__ == "__main__":
    main()
