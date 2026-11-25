#!/usr/bin/env python3
"""Fuzz smoke test and symlink-traversal regression test for macpkg (ASan + UBSan).

Builds an ASan/UBSan-instrumented macpkg binary in /tmp/macpkg-fuzz, runs:
  1. Crafted ZIP symlink-traversal tests (DMG-1).
  2. 200 randomly corrupted copies (100 steam.dmg + 100 crossover zip) with
     timeout 10s each, verifying no crashes, hangs, or sanitizer errors.
"""

from __future__ import annotations

import argparse
import os
import random
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent
STEAM_DMG = Path.home() / "Downloads" / "steam.dmg"
CROSSOVER_ZIP = Path.home() / "Downloads" / "crossover-preview-arm64.zip"
BUILD_TMP = Path("/tmp/macpkg-fuzz")

DMG_SOURCES = [
    "dmg/stream.c",
    "dmg/codecs.c",
    "dmg/xml_plist.c",
    "dmg/udif.c",
    "dmg/hfsplus.c",
    "dmg/apfs.c",
    "dmg/pkg.c",
    "dmg/zip.c",
    "dmg/macpkg.c",
]

CLI_SOURCE = "dmg/macpkg_cli.c"

THIRD_PARTY_GROUPS = [
    (
        ["-DZ_SOLO", "-DZ_PREFIX", "-Ithird_party/zlib"],
        [
            "third_party/zlib/adler32.c",
            "third_party/zlib/crc32.c",
            "third_party/zlib/inffast.c",
            "third_party/zlib/inflate.c",
            "third_party/zlib/inftrees.c",
            "third_party/zlib/zutil.c",
        ],
    ),
    (
        ["-DBZ_NO_STDIO", "-Ithird_party/bzip2"],
        [
            "third_party/bzip2/blocksort.c",
            "third_party/bzip2/bzlib.c",
            "third_party/bzip2/compress.c",
            "third_party/bzip2/crctable.c",
            "third_party/bzip2/decompress.c",
            "third_party/bzip2/huffman.c",
            "third_party/bzip2/randtable.c",
        ],
    ),
    (
        # Upstream lzfse_decode_base.c:241 indexes dst[i - D] with size_t wraparound.
        ["-Ithird_party/lzfse", "-fno-sanitize=pointer-overflow"],
        [
            "third_party/lzfse/lzfse_decode.c",
            "third_party/lzfse/lzfse_decode_base.c",
            "third_party/lzfse/lzfse_fse.c",
            "third_party/lzfse/lzvn_decode_base.c",
        ],
    ),
    (
        [
            "-DXZ_USE_CRC64",
            "-DXZ_USE_SHA256",
            "-DXZ_DEC_ANY_CHECK",
            "-DXZ_DEC_CONCATENATED",
            "-DXZ_DEC_X86",
            "-DXZ_DEC_ARM",
            "-DXZ_DEC_ARMTHUMB",
            "-DXZ_DEC_ARM64",
            "-DXZ_DEC_RISCV",
            "-DXZ_DEC_POWERPC",
            "-DXZ_DEC_IA64",
            "-DXZ_DEC_SPARC",
            "-Ithird_party/xz-embedded",
        ],
        [
            "third_party/xz-embedded/xz_crc32.c",
            "third_party/xz-embedded/xz_crc64.c",
            "third_party/xz-embedded/xz_dec_bcj.c",
            "third_party/xz-embedded/xz_dec_lzma2.c",
            "third_party/xz-embedded/xz_dec_stream.c",
            "third_party/xz-embedded/xz_sha256.c",
        ],
    ),
]


def run_checked(cmd: list[str], cwd: Path) -> None:
    res = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        raise RuntimeError(
            f"Command failed ({res.returncode}): {' '.join(cmd)}\n{res.stdout}\n{res.stderr}"
        )


def build_asan_binary(build_dir: Path) -> Path:
    obj_dir = build_dir / "obj"
    obj_dir.mkdir(parents=True, exist_ok=True)
    cc = os.environ.get("CC", "clang")
    san_flags = [
        "-O1",
        "-g",
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror=implicit-function-declaration",
        "-fsanitize=address,undefined",
        "-fno-sanitize-recover=all",
        "-fno-omit-frame-pointer",
    ]
    dmg_cppflags = [
        "-DZ_SOLO",
        "-DZ_PREFIX",
        "-DXZ_USE_CRC64",
        "-Idmg",
        "-Ithird_party/zlib",
        "-Ithird_party/bzip2",
        "-Ithird_party/lzfse",
        "-Ithird_party/xz-embedded",
    ]

    objs: list[str] = []
    for src in DMG_SOURCES:
        obj = obj_dir / (src.replace("/", "_") + ".o")
        run_checked([cc, *san_flags, *dmg_cppflags, "-c", src, "-o", str(obj)], ROOT_DIR)
        objs.append(str(obj))

    for extra_flags, srcs in THIRD_PARTY_GROUPS:
        for src in srcs:
            obj = obj_dir / (src.replace("/", "_") + ".o")
            run_checked([cc, *san_flags, *extra_flags, "-c", src, "-o", str(obj)], ROOT_DIR)
            objs.append(str(obj))

    cli_obj = obj_dir / "cli.o"
    run_checked([cc, *san_flags, "-Idmg", "-c", CLI_SOURCE, "-o", str(cli_obj)], ROOT_DIR)
    bin_path = build_dir / "macpkg-asan"
    run_checked([cc, *san_flags, "-o", str(bin_path), str(cli_obj), *objs], ROOT_DIR)
    return bin_path


def _add_zip_symlink(zf: zipfile.ZipFile, arcname: str, target: str) -> None:
    zi = zipfile.ZipInfo(arcname)
    zi.create_system = 3  # Unix
    zi.external_attr = (stat.S_IFLNK | 0o777) << 16
    zf.writestr(zi, target.encode("utf-8"))


def check_macpkg_run(
    bin_path: Path, archive: Path, out_dir: Path, timeout_s: float = 10.0
) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            [str(bin_path), str(archive), str(out_dir)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(f"macpkg timed out after {timeout_s}s on {archive}") from exc

    combined = proc.stdout + "\n" + proc.stderr
    for marker in (
        "AddressSanitizer",
        "UndefinedBehaviorSanitizer",
        "LeakSanitizer",
        "runtime error:",
        "SUMMARY: ",
    ):
        if marker in combined:
            raise AssertionError(
                f"Sanitizer error ({marker}) on {archive} (rc={proc.returncode}):\n{combined}"
            )
    if proc.returncode < 0:
        sig_name = signal.Signals(-proc.returncode).name
        raise AssertionError(f"macpkg crashed with signal {sig_name} on {archive}:\n{combined}")
    # Also guard against shell-style 128+sig exit codes from abort handlers.
    if proc.returncode >= 128:
        raise AssertionError(
            f"macpkg terminated abnormally (rc={proc.returncode}) on {archive}:\n{combined}"
        )
    return proc.returncode, proc.stdout, proc.stderr


def run_symlink_traversal_tests(bin_path: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="macpkg_trav_") as tmp:
        root = Path(tmp)
        outside = root / "outside"
        outside.mkdir()

        # Case 1: Symlink directory pointing outside, followed by regular file inside it.
        z1 = root / "trav_dir.zip"
        out1 = root / "out1"
        out1.mkdir()
        with zipfile.ZipFile(z1, "w") as zf:
            _add_zip_symlink(zf, "Evil.app/Contents/MacOS", str(outside))
            zf.writestr("Evil.app/Contents/MacOS/pwned.txt", b"owned")
        rc, _, _ = check_macpkg_run(bin_path, z1, out1)
        if rc == 0:
            raise AssertionError("Expected trav_dir.zip to fail, but rc == 0")
        if (outside / "pwned.txt").exists():
            raise AssertionError("CRITICAL: DMG-1 traversal wrote outside output dir (case 1)!")

        # Case 2: Deep relative escape symlink, followed by file through that link.
        z2 = root / "trav_rel.zip"
        out2 = root / "out2"
        out2.mkdir()
        with zipfile.ZipFile(z2, "w") as zf:
            _add_zip_symlink(zf, "Evil.app/Contents/esc", "../../../outside")
            zf.writestr("Evil.app/Contents/esc/pwned2.txt", b"owned2")
        rc, _, _ = check_macpkg_run(bin_path, z2, out2)
        if rc == 0:
            raise AssertionError("Expected trav_rel.zip to fail, but rc == 0")
        if (outside / "pwned2.txt").exists():
            raise AssertionError("CRITICAL: DMG-1 traversal wrote outside output dir (case 2)!")

        # Case 3: Entry path containing '..' component directly.
        z3 = root / "trav_dotdot.zip"
        out3 = root / "out3"
        out3.mkdir()
        with zipfile.ZipFile(z3, "w") as zf:
            zf.writestr("../../outside/pwned3.txt", b"owned3")
        rc, _, _ = check_macpkg_run(bin_path, z3, out3)
        if rc == 0:
            raise AssertionError("Expected trav_dotdot.zip to fail, but rc == 0")
        if (outside / "pwned3.txt").exists():
            raise AssertionError("CRITICAL: DMG-1 traversal wrote outside output dir (case 3)!")

        # Case 4: Valid relative internal symlink must succeed.
        z4 = root / "valid_rel.zip"
        out4 = root / "out4"
        out4.mkdir()
        with zipfile.ZipFile(z4, "w") as zf:
            zf.writestr("Good.app/Contents/Resources/data.txt", b"hello")
            _add_zip_symlink(zf, "Good.app/Contents/MacOS/link", "../Resources/data.txt")
        rc, out, err = check_macpkg_run(bin_path, z4, out4)
        if rc != 0:
            raise AssertionError(f"Expected valid_rel.zip to succeed, got rc={rc}: {out}\n{err}")
        link_p = out4 / "Good.app/Contents/MacOS/link"
        if not link_p.is_symlink() or os.readlink(link_p) != "../Resources/data.txt":
            raise AssertionError("Valid internal relative symlink was not preserved!")

    print("PASS: DMG-1 symlink traversal regression tests (4/4 cases)")


def clone_file(src: Path, dst: Path) -> None:
    # APFS CoW clone avoids duplicating 600 MB per iteration.
    res = subprocess.run(["cp", "-c", str(src), str(dst)])
    if res.returncode != 0:
        shutil.copyfile(src, dst)


def mutate_file(path: Path, size: int, rng: random.Random, iteration: int, is_dmg: bool) -> None:
    mode = iteration % 5
    with open(path, "r+b") as f:
        if mode == 0 and size > 4096:
            # Truncate: tiny header cut, early-archive cut, or tail/CD cut.
            early_cap = min(size - 1, 8 * 1024 * 1024)
            cut = rng.choice(
                [
                    rng.randint(0, min(4096, size)),
                    rng.randint(4096, early_cap),
                    max(0, size - rng.randint(1, 4096)),
                ]
            )
            f.truncate(cut)
            return

        if mode == 1:
            # Corrupt tail metadata (UDIF koly block or ZIP EOCD + Central Directory).
            tail_window = min(size, 2 * 1024 * 1024 if not is_dmg else 4096)
            for _ in range(rng.randint(4, 32)):
                off = size - tail_window + rng.randrange(tail_window)
                f.seek(off)
                f.write(bytes([rng.randrange(256) for _ in range(rng.randint(1, 16))]))
            return

        if mode == 2:
            # Corrupt early local headers / streams / superblocks.
            head_window = min(size, 65536 if is_dmg else 2 * 1024 * 1024)
            for _ in range(rng.randint(4, 32)):
                off = rng.randrange(head_window)
                f.seek(off)
                f.write(bytes([rng.randrange(256) for _ in range(rng.randint(1, 16))]))
            return

        if mode == 3:
            if is_dmg and size > 512:
                # Flip fields inside koly trailer (last 512 bytes) and XML plist region.
                for _ in range(rng.randint(2, 16)):
                    off = size - 512 + rng.randrange(512)
                    f.seek(off)
                    f.write(bytes([rng.randrange(256) for _ in range(rng.randint(1, 8))]))
                if size > 262144:
                    for _ in range(rng.randint(2, 16)):
                        off = size - rng.randint(1024, min(size, 262144))
                        f.seek(off)
                        f.write(bytes([rng.randrange(256) for _ in range(rng.randint(1, 8))]))
            else:
                # Mutate ZIP Central Directory start + early payload entries.
                cd_window = min(size, 3 * 1024 * 1024)
                head_window = min(size, 1024 * 1024)
                for _ in range(rng.randint(8, 32)):
                    off = size - cd_window + rng.randrange(cd_window)
                    f.seek(off)
                    f.write(bytes([rng.randrange(256) for _ in range(rng.randint(1, 16))]))
                for _ in range(rng.randint(4, 16)):
                    off = rng.randrange(head_window)
                    f.seek(off)
                    f.write(bytes([rng.randrange(256) for _ in range(rng.randint(1, 16))]))
            return

        # Random scattered byte mutations throughout the file (dense enough to hit early entries).
        n_mut = rng.randint(8, 40) if is_dmg else rng.randint(64, 256)
        for j in range(n_mut):
            if not is_dmg and j < 8:
                off = rng.randrange(min(size, 2 * 1024 * 1024))
            else:
                off = rng.randrange(size)
            f.seek(off)
            f.write(bytes([rng.randrange(256) for _ in range(rng.randint(1, 16))]))


def run_fuzz_corpus(
    bin_path: Path, src: Path, label: str, count: int, seed: int, timeout_s: float
) -> None:
    if not src.exists():
        raise FileNotFoundError(f"Missing fuzz seed file: {src}")
    size = src.stat().st_size
    rng = random.Random(seed)
    is_dmg = src.suffix == ".dmg"

    with tempfile.TemporaryDirectory(prefix=f"macpkg_fuzz_{label}_") as tmp:
        tmp_dir = Path(tmp)
        for i in range(count):
            mutated = tmp_dir / f"{label}_{i}{src.suffix}"
            out_dir = tmp_dir / f"out_{i}"
            out_dir.mkdir()
            clone_file(src, mutated)
            try:
                mutate_file(mutated, size, rng, i, is_dmg=is_dmg)
                check_macpkg_run(bin_path, mutated, out_dir, timeout_s=timeout_s)
            finally:
                if mutated.exists():
                    mutated.unlink()
                shutil.rmtree(out_dir, ignore_errors=True)
            if (i + 1) % 25 == 0 or (i + 1) == count:
                print(f"  [{label}] {i + 1}/{count} completed cleanly")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dmg-count", type=int, default=100)
    parser.add_argument("--zip-count", type=int, default=100)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--seed", type=int, default=20261114)
    args = parser.parse_args()

    print(f"Building ASan+UBSan macpkg in {BUILD_TMP} ...")
    bin_path = build_asan_binary(BUILD_TMP)

    run_symlink_traversal_tests(bin_path)

    print(
        f"Running fuzz smoke test: {args.dmg_count} corrupted steam.dmg + "
        f"{args.zip_count} corrupted crossover zips (timeout={args.timeout}s each) ..."
    )
    run_fuzz_corpus(
        bin_path, STEAM_DMG, "steam_dmg", args.dmg_count, seed=args.seed, timeout_s=args.timeout
    )
    run_fuzz_corpus(
        bin_path,
        CROSSOVER_ZIP,
        "crossover_zip",
        args.zip_count,
        seed=args.seed + 1,
        timeout_s=args.timeout,
    )
    total = args.dmg_count + args.zip_count
    print(f"PASS: fuzz smoke test ({total}/{total} corrupted archives, 0 crashes/hangs/UB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
