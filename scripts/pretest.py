#!/usr/bin/env python3
"""Run the project's deterministic checks without installing or opening user data."""
from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
from typing import Callable, Sequence
import uuid


ROOT = Path(__file__).resolve().parents[1]
EXIT_CODES = {"PASS": 0, "FAIL": 1, "BLOCKED": 2}
GENERATED_ROOTS = {"build", ".build", "DerivedData"}
GENERATED_NAMES = {"__pycache__", ".pytest_cache", "node_modules"}
SOURCE_DIRECTORIES = {"Sources", "Tests", "scripts", ".github", ".agents", "docs", "website"}


@dataclass(frozen=True)
class Check:
    id: str
    command: tuple[str, ...]
    files: tuple[str, ...] = ()
    tools: tuple[str, ...] = ()
    portable: bool = True
    macos: bool = False
    gui: bool = False
    native: bool = False


@dataclass(frozen=True)
class Capabilities:
    macos: bool
    gui: bool
    tools: frozenset[str]


@dataclass(frozen=True)
class Execution:
    returncode: int | None
    seconds: float
    timed_out: bool = False
    unavailable: bool = False


def default_checks() -> tuple[Check, ...]:
    python = sys.executable
    native = (
        ("quit-shortcut", "run-quit-shortcut-test.sh"),
        ("capture-window", "run-capture-window-test.sh"),
        ("status-menu", "run-status-menu-test.sh"),
        ("interface-controls", "run-interface-controls-test.sh"),
    )
    return (
        Check("diff-check", ("git", "diff", "--check", "HEAD"), tools=("git",)),
        Check("design-system", (python, "scripts/check-design-system.py"),
              files=("scripts/check-design-system.py",)),
        Check("versioning", (python, "-B", "-m", "unittest", "discover", "-s", "Tests/Versioning", "-v"),
              files=("Tests/Versioning/test_git_versioning.py",), tools=("git",)),
        Check("pretest-runner", (python, "-B", "-m", "unittest", "discover", "-s", "Tests/Pretest", "-v"),
              files=("Tests/Pretest/test_pretest.py",), tools=("git",)),
        Check("website", ("npm", "--prefix", "website", "test"),
              files=("website/package.json",), tools=("npm", "node")),
        Check("swift-core", ("swift", "test"), files=("Package.swift",),
              tools=("swift",), portable=False, macos=True),
        *(Check("native-" + name, ("bash", "Tests/Native/" + filename),
                files=("Tests/Native/" + filename,), tools=("bash", "swiftc", "xcrun"),
                portable=False, macos=True, gui=True, native=True) for name, filename in native),
    )


def detect_capabilities(repo: Path) -> Capabilities:
    macos = platform.system() == "Darwin"
    gui = False
    if macos:
        try:
            # A GUI bootstrap domain and the same logged-in console user are required.
            # Do not query applications, recordings, settings or accessibility permissions.
            console_user = os.stat("/dev/console").st_uid
            if console_user == os.getuid() and console_user != 0:
                gui = subprocess.run(
                    ["/bin/launchctl", "print", f"gui/{os.getuid()}"], cwd=repo,
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=5, check=False,
                ).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            pass
    names = {name for check in default_checks() for name in check.tools}
    return Capabilities(macos, gui, frozenset(name for name in names if shutil.which(name)))


def prerequisite(check: Check, repo: Path, capabilities: Capabilities) -> tuple[str, str] | None:
    missing_files = [name for name in check.files if not (repo / name).is_file()]
    if missing_files:
        return "FAIL", "Required check files are missing: " + ", ".join(missing_files)
    missing = [name for name in check.tools if name not in capabilities.tools]
    reasons = []
    if check.macos and not capabilities.macos:
        reasons.append("macOS is required")
    if missing:
        reasons.append("missing tools: " + ", ".join(missing))
    if check.gui and not capabilities.gui:
        reasons.append("an active GUI session for the current user is required")
    return ("BLOCKED", "; ".join(reasons)) if reasons else None


def run_command(check: Check, repo: Path, logs: Path, timeout: float) -> Execution:
    started = time.monotonic()
    with (logs / "stdout.log").open("wb") as stdout, (logs / "stderr.log").open("wb") as stderr:
        try:
            process = subprocess.Popen(check.command, cwd=repo, stdin=subprocess.DEVNULL,
                                       stdout=stdout, stderr=stderr, start_new_session=True)
        except OSError as error:
            stderr.write(f"Cannot start check: {error}\n".encode())
            return Execution(None, time.monotonic() - started, unavailable=True)
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            # Terminate the entire group, including a compiler or test child process.
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    pass
                if sig == signal.SIGTERM:
                    try:
                        process.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        pass
            process.wait()
            stderr.write(f"\nPretest timeout after {timeout:g} seconds\n".encode())
    return Execution(process.returncode, time.monotonic() - started, timed_out=timed_out)


def _included(path: str, tracked: bool, report_directory: str | None) -> bool:
    parts = Path(path).parts
    if not parts or parts[0] in GENERATED_ROOTS or any(part in GENERATED_NAMES for part in parts):
        return False
    # Most of website/dist is source-controlled input, not generated output.
    if parts[:3] in (("website", "dist", "server"), ("website", "dist", ".openai")) or parts[-1] == ".DS_Store":
        return False
    if report_directory and (path == report_directory or path.startswith(report_directory + "/")):
        return False
    return tracked or parts[0] in SOURCE_DIRECTORIES or (
        len(parts) == 1 and Path(path).suffix in {".swift", ".py", ".sh", ".md", ".json", ".yml", ".yaml", ".toml"}
    )


def snapshot_sources(repo: Path, run_directory: Path) -> dict:
    """Record hashes only. Never persist diffs, source contents or environment values."""
    def git(*args: str) -> bytes:
        return subprocess.run(["git", *args], cwd=repo, stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=30, check=True).stdout

    head = git("rev-parse", "HEAD").decode().strip()
    try:
        report_directory = run_directory.relative_to(repo).as_posix()
    except ValueError:
        report_directory = None
    index_records = git("ls-files", "--stage", "-z").split(b"\0")
    index = []
    tracked = {os.fsdecode(path) for path in git("ls-tree", "-r", "--name-only", "-z", "HEAD").split(b"\0") if path}
    for record in filter(None, index_records):
        path = os.fsdecode(record.split(b"\t", 1)[1])
        tracked.add(path)
        if _included(path, True, report_directory):
            index.append(record)
    paths = set(os.fsdecode(p) for p in git("diff", "--name-only", "-z", "HEAD").split(b"\0") if p)
    paths.update(os.fsdecode(p) for p in git("ls-files", "--modified", "--deleted", "--others",
                                            "--exclude-standard", "-z").split(b"\0") if p)
    paths = sorted(path for path in paths if _included(path, path in tracked, report_directory))
    hashes = {}
    for path in paths:
        file = repo / path
        try:
            info = file.lstat()
        except FileNotFoundError:
            hashes[path] = {"kind": "deleted"}
            continue
        if stat.S_ISLNK(info.st_mode):
            # Hash the link itself; do not follow it into user data outside the repo.
            payload = os.fsencode(os.readlink(file))
            digest = hashlib.sha256(payload).hexdigest()
            kind = "symlink"
        elif stat.S_ISREG(info.st_mode):
            digest_builder = hashlib.sha256()
            with file.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest_builder.update(chunk)
            digest = digest_builder.hexdigest()
            kind = "file"
        else:
            hashes[path] = {"kind": "non-regular", "mode": stat.S_IMODE(info.st_mode)}
            continue
        hashes[path] = {"kind": kind, "sha256": digest, "mode": stat.S_IMODE(info.st_mode)}
    # Per-file diff hashes avoid command length limits and do not materialize a patch.
    diff_hash = hashlib.sha256()
    for path in paths:
        if path in tracked:
            diff_hash.update(os.fsencode(path) + b"\0")
            diff_hash.update(git("diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--", path))
    source = {"head": head, "index_sha256": hashlib.sha256(b"\0".join(index)).hexdigest(),
              "dirty_diff_sha256": diff_hash.hexdigest(), "changed_files": hashes}
    source["fingerprint"] = hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest()
    return source


def overall_status(statuses: Sequence[str]) -> str:
    if not statuses or "FAIL" in statuses:
        return "FAIL"
    return "BLOCKED" if "BLOCKED" in statuses else "PASS"


def write_report(report: dict, directory: Path) -> None:
    (directory / "summary.json").write_text(json.dumps(report, ensure_ascii=True, indent=2) + "\n")
    lines = [f"# Pretest: {report['status']}", "", f"Scope: **{report['scope']}**", "",
             "Portable scope excludes Swift and native macOS UI checks. It is not a full Pretest pass."
             if report["scope"] == "portable" else "All required checks are included; unavailable checks block the gate.",
             "", f"Source HEAD: `{(report['source_integrity']['before'] or {}).get('head', 'unavailable')}`", "",
             "| Check | Status | Seconds | Evidence |", "|---|---|---:|---|"]
    for result in report["checks"]:
        log = result["stdout_log"]
        error = result["stderr_log"]
        lines.append(f"| {result['id']} | {result['status']} | {result['seconds']:.2f} | "
                     f"[stdout]({log}) · [stderr]({error}) |")
    lines += ["", f"Source integrity: **{report['source_integrity']['status']}**", "",
              report["source_integrity"]["reason"], ""]
    if report["outside_scope"]:
        lines += ["Outside the requested scope: " + ", ".join(report["outside_scope"]), ""]
    for result in report["checks"]:
        lines += [f"## {result['id']}", "", f"`{shlex.join(result['command'])}`", "", result["reason"], ""]
    lines += ["Source snapshots contain hashes only. Generated build output is excluded.", ""]
    (directory / "report.md").write_text("\n".join(lines))


def run_suite(repo: Path, output_root: Path, *, portable: bool = False, timeout: float = 600,
              checks: Sequence[Check] | None = None, capabilities: Capabilities | None = None,
              command_runner: Callable = run_command, snapshotter: Callable = snapshot_sources,
              progress: Callable | None = None) -> dict:
    """Dependency injection is for unit tests; the CLI always uses the complete check plan."""
    repo = repo.resolve()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    directory = output_root.resolve() / stamp
    directory.mkdir(parents=True)
    plan = tuple(default_checks() if checks is None else checks)
    selected = tuple(check for check in plan if not portable or check.portable)
    caps = capabilities if capabilities is not None else detect_capabilities(repo)
    integrity = {"status": "BLOCKED", "reason": "Source identity could not be recorded.", "before": None, "after": None}
    try:
        integrity["before"] = snapshotter(repo, directory)
    except (OSError, subprocess.SubprocessError):
        pass
    results = []
    for check in selected:  # Native probes must never contend for the GUI.
        if check.id == "swift-core":
            check = replace(check, command=check.command + ("--scratch-path", str(directory / "swift-build")))
        elif check.id in {"native-interface-controls", "native-status-menu"}:
            check = replace(check, command=check.command + ("--render", str(directory / "renders" / check.id)))
        if progress:
            progress(f"RUN     {check.id}")
        logs = directory / "checks" / check.id
        logs.mkdir(parents=True)
        for name in ("stdout.log", "stderr.log"):
            (logs / name).touch()
        row = {"id": check.id, "command": list(check.command), "cwd": str(repo), "seconds": 0.0,
               "returncode": None, "timed_out": False, "stdout_log": f"checks/{check.id}/stdout.log",
               "stderr_log": f"checks/{check.id}/stderr.log"}
        issue = prerequisite(check, repo, caps)
        if issue:
            row["status"], row["reason"] = issue
            (logs / "stderr.log").write_text(row["reason"] + "\n")
        else:
            result = command_runner(check, repo, logs, timeout)
            row.update(seconds=round(result.seconds, 3), returncode=result.returncode, timed_out=result.timed_out)
            if result.timed_out:
                row.update(status="FAIL", reason=f"Exceeded {timeout:g} seconds; the process group was terminated.")
            elif result.unavailable:
                row.update(status="BLOCKED", reason="The check executable could not be started; see stderr.")
            elif result.returncode == 0:
                row.update(status="PASS", reason="Command completed successfully.")
            elif check.native and result.returncode == 77:
                row.update(status="BLOCKED", reason="The native probe reported unavailable prerequisites (exit 77); see stderr.")
            else:
                row.update(status="FAIL", reason=f"Command exited with status {result.returncode}; see logs.")
        results.append(row)
        if progress:
            progress(f"{row['status']:7} {row['id']}: {row['reason']}")
    try:
        integrity["after"] = snapshotter(repo, directory)
    except (OSError, subprocess.SubprocessError):
        pass
    if integrity["before"] is not None and integrity["after"] is not None:
        stable = integrity["before"] == integrity["after"]
        integrity.update(status="PASS" if stable else "FAIL", reason=(
            "HEAD, index, dirty diff and changed source hashes are unchanged."
            if stable else "Sources changed during the run. Results do not certify the final sources; rerun Pretest."))
    status = overall_status([row["status"] for row in results] + [integrity["status"]]) if results else "FAIL"
    report = {"schema_version": 1, "status": status, "exit_code": EXIT_CODES[status],
              "scope": "portable" if portable else "full", "created_at": stamp,
              "directory": str(directory), "timeout_seconds": timeout, "checks": results,
              "outside_scope": [check.id for check in plan if check not in selected], "source_integrity": integrity}
    write_report(report, directory)
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portable", action="store_true", help="Run only portable checks; does not certify native UI or Swift.")
    parser.add_argument("--list", action="store_true", help="List the selected checks without running them or writing reports.")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/pretest", help="Parent directory for unique run reports.")
    parser.add_argument("--timeout", type=float, default=600, help="Maximum seconds per check (default: 600).")
    args = parser.parse_args(argv)
    if not 0 < args.timeout < float("inf"):
        parser.error("--timeout must be a finite positive number")
    if args.list:
        print("Scope: " + ("portable (Swift and native UI excluded)" if args.portable else "full"))
        for check in default_checks():
            if not args.portable or check.portable:
                print(f"{check.id}: {shlex.join(check.command)}")
        return 0
    report = run_suite(ROOT, args.output_dir, portable=args.portable, timeout=args.timeout,
                       progress=lambda message: print(message, flush=True))
    print(f"{report['source_integrity']['status']:7} source-integrity: {report['source_integrity']['reason']}")
    print(f"Pretest {report['scope']}: {report['status']}; report: {report['directory']}/report.md")
    return report["exit_code"]


if __name__ == "__main__":
    raise SystemExit(main())
