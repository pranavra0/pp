#!/usr/bin/env python3
"""Milestone 0 golden fixtures and reproducible single-process benchmarks.

The runner deliberately owns one shared case list.  ``--check`` runs that list
against one explicitly named engine; ``--compare`` runs the same list against
both explicit binaries and compares process output plus store artifacts.  No
background process or daemon is started by this file.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable


SCHEMA = "pp-m0-golden-v1"
STORE_DIR = Path(".pp") / "store"
REQUIRED_CASES = frozenset({
    "canonical-codec",
    "node-trace",
    "store-layout",
    "transport-message",
    "diagnostic-source-range",
})
CASE_REQUIRED_FIELDS = {
    "canonical-codec": frozenset({"argv", "source", "exit", "stdout", "stderr",
                                  "object", "files"}),
    "node-trace": frozenset({"argv", "source", "exit", "stdout", "stderr",
                             "node_key", "object", "trace", "files"}),
    "store-layout": frozenset({"argv", "source", "exit", "stdout", "stderr",
                               "ignore", "files"}),
    "transport-message": frozenset({
        "argv", "generated_inputs", "setup", "exit", "stdout", "stderr",
        "reply_file", "reply_sha256", "unknown_key", "artifacts",
    }),
    "diagnostic-source-range": frozenset({
        "argv", "source_range", "exit", "stdout", "stderr",
        "stderr_file", "stderr_sha256",
    }),
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_bytes(path: Path) -> bytes:
    return path.read_bytes()


def scrub_env(home: Path) -> dict[str, str]:
    env = os.environ.copy()
    # The benchmark contract is direct subprocess execution, not a daemon.
    for name in ("PP_DAEMON", "PP_SERVER", "PP_SOCKET"):
        env.pop(name, None)
    env["HOME"] = str(home)
    return env


def invoke(binary: Path, args: list[str], root: Path, home: Path,
           timeout: float = 60.0) -> subprocess.CompletedProcess[bytes]:
    # ``binary`` is resolved before this function and is the first argv item on
    # every call.  Keeping this as subprocess.run also makes process boundaries
    # and startup costs observable in the benchmark.
    home.mkdir(parents=True, exist_ok=True)
    return subprocess.run(
        [str(binary), *args], cwd=root, env=scrub_env(home),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=timeout, check=False,
    )


def text(value: bytes) -> str:
    return value.decode("utf-8", errors="replace")


def store_files(home: Path, include_locks: bool = False) -> dict[str, bytes]:
    root = home / STORE_DIR
    if not root.exists():
        return {}
    result: dict[str, bytes] = {}
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        rel = path.relative_to(root).as_posix()
        if not include_locks and rel.startswith("locks/"):
            continue
        result[rel] = read_bytes(path)
    return result


def store_metadata(files: dict[str, bytes]) -> list[dict[str, Any]]:
    return [
        {"path": path, "bytes": len(files[path]), "sha256": sha256(files[path])}
        for path in sorted(files)
    ]


def normalized_path(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        # An explicitly selected engine may live outside the checkout. Keep
        # committed metadata portable; binary hash and size retain identity.
        return "<external-binary>"


def normalize_transport_output(value: bytes, work: Path) -> str:
    rendered = text(value)
    rendered = rendered.replace(str(work), "<work>")
    rendered = re.sub(r"\S*/\.pp/cluster/secret", "<cluster-secret>", rendered)
    rendered = re.sub(r"(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])",
                      "<cluster-id>", rendered)
    return rendered
def normalize_diagnostic_output(value: bytes, root: Path,
                                source_range: str) -> bytes:
    """Normalize only the source pathname in a diagnostic.

    Reader messages and coordinates are part of the golden contract.  The
    pathname is the one field that can differ when engines run from different
    checkouts.
    """
    source = source_range.split(":", 1)[0]
    candidates = {
        source.replace("\\", "/"),
        Path(source).as_posix(),
        str(root / source),
        str((root / source).resolve()),
    }
    rendered = text(value)
    for candidate in sorted((item for item in candidates if item),
                            key=len, reverse=True):
        rendered = rendered.replace(candidate, "<source>")
    return rendered.encode("utf-8")


def comparable_case_bytes(root: Path, name: str, spec: dict[str, Any],
                          key: str, value: bytes) -> bytes:
    if name == "diagnostic-source-range" and key == "stderr":
        return normalize_diagnostic_output(value, root, spec["source_range"])
    return value




def transport_artifacts(work: Path, home: Path, token: Path, shared: Path,
                        reply: Path) -> dict[str, bytes]:
    artifacts: dict[str, bytes] = {}
    home_root = home
    if home_root.exists():
        for path in sorted(p for p in home_root.rglob("*") if p.is_file()):
            rel = path.relative_to(home_root).as_posix()
            if "/locks/" not in f"/{rel}" and not rel.startswith("locks/"):
                artifacts[f"home/{rel}"] = read_bytes(path)
    for label, path in (("inputs/token", token), ("outputs/reply", reply)):
        if path.exists():
            artifacts[label] = read_bytes(path)
    if shared.exists():
        for path in sorted(p for p in shared.rglob("*") if p.is_file()):
            rel = path.relative_to(shared).as_posix()
            if not rel.startswith("locks/"):
                artifacts[f"shared/{rel}"] = read_bytes(path)
    return artifacts


def normalized_transport_bytes(path: str, data: bytes) -> bytes:
    if path == "home/.pp/cluster/id" and re.fullmatch(rb"[0-9a-f]{32}\n", data):
        return b"<cluster-id>\n"
    if path == "home/.pp/cluster/secret" and re.fullmatch(rb"[0-9a-f]{64}\n", data):
        return b"<cluster-secret>\n"
    if path == "inputs/token":
        rendered = text(data)
        rendered = re.sub(r'"[0-9a-f]{32}"', '"<cluster-id>"', rendered)
        rendered = re.sub(r"\b[0-9]{9,12}\b", "<timestamp>", rendered)
        rendered = re.sub(r'"[0-9a-f]{64}"', '"<signature>"', rendered)
        return rendered.encode("utf-8")
    return data


def transport_metadata(files: dict[str, bytes]) -> list[dict[str, Any]]:
    volatile = {"home/.pp/cluster/id", "home/.pp/cluster/secret",
                "inputs/token"}
    return [
        {
            "path": path,
            "bytes": len(data),
            "sha256": None if path in volatile else sha256(data),
            "normalized_sha256": sha256(normalized_transport_bytes(path, data)),
            "volatile": path in volatile,
        }
        for path, data in sorted(files.items())
    ]


def write_source_fixtures(root: Path) -> None:
    directory = root / "lisp" / "tests" / "golden"
    directory.mkdir(parents=True, exist_ok=True)
    sources = {
        "codec.pp": (
            "print(force(node {\n"
            "  vec[1 + 2, 2.5, \"m0\", :kw, quote { sym }, cons(1, 2),\n"
            "      vec[1, vec[2]], {\"a\" -> 1, \"b\" -> 2}, hash-set(1, 2),\n"
            "      nil, 1 = 1, 1 = 2]\n"
            "}))\n"
        ),
        "node.pp": "print(force(node { 40 + 2 }))\n",
        "parallel.pp": (
            "print(force(node { vec["
            "node { 1 + 1 }, node { 2 + 1 }, node { 3 + 1 }, node { 4 + 1 }, "
            "node { 5 + 1 }, node { 6 + 1 }, node { 7 + 1 }, node { 8 + 1 }"
            "] }))\n"
        ),
        "gc.pp": (
            '{:tree -> {"m0.txt" -> {:kind -> :file, :mode -> 420, '
            ':blob -> blob("m0")}}}\n'
        ),
        # This is intentionally malformed: the location is part of the golden
        # diagnostic contract and is generated by the OCaml reader below.
        "diagnostics-input.pp": "print(1 2)\n",
    }
    for name, content in sources.items():
        (directory / name).write_text(content, encoding="utf-8")


def choose_named(files: dict[str, bytes], directory: str) -> tuple[str, bytes]:
    choices = [(path, data) for path, data in files.items()
               if path.startswith(directory + "/")]
    if len(choices) != 1:
        raise RuntimeError(f"expected one {directory} artifact, got {len(choices)}")
    return choices[0]


def generate_golden(root: Path, binary: Path) -> None:
    write_source_fixtures(root)
    golden = root / "lisp" / "tests" / "golden"
    expected: dict[str, Any] = {
        "schema": SCHEMA,
        "reference": {
            "engine": "ocaml",
            "binary": normalized_path(root, binary),
            "binary_argument_required": True,
            "daemon": False,
        },
        "cases": {},
    }

    with tempfile.TemporaryDirectory(prefix="pp-m0-golden-") as raw:
        work = Path(raw)
        home = work / "home"
        home.mkdir()
        proc = invoke(binary, ["lisp/tests/golden/codec.pp"], root, home)
        if proc.returncode != 0:
            raise RuntimeError(f"codec fixture failed ({proc.returncode}): {text(proc.stderr)}")
        codec_files = store_files(home)
        object_path, object_bytes = choose_named(codec_files, "objects")
        object_name = Path(object_path).name
        (golden / "canonical-value.object").write_bytes(object_bytes)
        canonical = {
            "codec": "store object encoding emitted by OCaml Codec.encode_value",
            "value_hash": object_name,
            "bytes_file": "canonical-value.object",
            "bytes": len(object_bytes),
            "bytes_sha256": sha256(object_bytes),
            "stdout": text(proc.stdout),
            "stderr": text(proc.stderr),
            "exit": proc.returncode,
        }
        (golden / "canonical-value.json").write_text(
            json.dumps(canonical, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        expected["cases"]["canonical-codec"] = {
            "argv": [normalized_path(root, binary), "lisp/tests/golden/codec.pp"],
            "source": "codec.pp",
            "exit": proc.returncode,
            "stdout": text(proc.stdout),
            "stderr": text(proc.stderr),
            "object": {"path": object_path, "bytes_file": "canonical-value.object",
                       "value_hash": object_name, "sha256": sha256(object_bytes)},
            "files": store_metadata(codec_files),
        }

        # A minimal node fixture gives a stable key (trace filename), encoded
        # result, and the trace SET bytes without depending on source paths.
        node_home = work / "node-home"
        node_home.mkdir()
        node = invoke(binary, ["lisp/tests/golden/node.pp"], root, node_home)
        if node.returncode != 0:
            raise RuntimeError(f"node fixture failed ({node.returncode}): {text(node.stderr)}")
        node_files = store_files(node_home)
        node_object_path, node_object_bytes = choose_named(node_files, "objects")
        node_trace_path, node_trace_bytes = choose_named(node_files, "traces")
        (golden / "node-key.txt").write_text(Path(node_trace_path).name + "\n", encoding="utf-8")
        (golden / "node-trace.txt").write_bytes(node_trace_bytes)
        expected["cases"]["node-trace"] = {
            "argv": [normalized_path(root, binary), "lisp/tests/golden/node.pp"],
            "source": "node.pp",
            "exit": node.returncode,
            "stdout": text(node.stdout),
            "stderr": text(node.stderr),
            "node_key": Path(node_trace_path).name,
            "object": {"path": node_object_path, "bytes_file": None,
                       "value_hash": Path(node_object_path).name,
                       "sha256": sha256(node_object_bytes)},
            "trace": {"path": node_trace_path, "bytes_file": "node-trace.txt",
                      "sha256": sha256(node_trace_bytes)},
            "files": store_metadata(node_files),
        }
        node_layout = store_files(node_home)
        (golden / "store-layout.json").write_text(
            json.dumps({
                "store": ".pp/store",
                "ignore": ["locks/**"],
                "files": store_metadata(node_layout),
            }, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        expected["cases"]["store-layout"] = {
            "argv": [normalized_path(root, binary), "lisp/tests/golden/node.pp"],
            "source": "node.pp",
            "exit": node.returncode,
            "stdout": text(node.stdout),
            "stderr": text(node.stderr),
            "ignore": ["locks/**"],
            "files": store_metadata(node_layout),
        }

        # A valid, freshly minted token is needed to reach the transport
        # decision.  An unknown key makes the reply deterministic (MISS) while
        # still exercising the OCaml token and reply codecs.
        transport_home = work / "transport-home"
        transport_home.mkdir()
        cluster = invoke(binary, ["cluster-init"], root, transport_home)
        if cluster.returncode != 0:
            raise RuntimeError(f"cluster-init failed ({cluster.returncode}): {text(cluster.stderr)}")
        token = work / "token.txt"
        minted = invoke(binary, ["--mint-token", str(token), "3600"], root, transport_home)
        if minted.returncode != 0:
            raise RuntimeError(f"mint-token failed ({minted.returncode}): {text(minted.stderr)}")
        reply = work / "reply.txt"
        unknown_key = "0" * 64
        served = invoke(binary, ["--serve-hit", unknown_key, str(token),
                                 str(work / "shared"), str(reply)], root, transport_home)
        if served.returncode != 0:
            raise RuntimeError(f"serve-hit failed ({served.returncode}): {text(served.stderr)}")
        reply_bytes = read_bytes(reply)
        (golden / "transport-reply.txt").write_bytes(reply_bytes)
        transport_files = transport_artifacts(
            work, transport_home, token, work / "shared", reply)
        expected["cases"]["transport-message"] = {
            "argv": [normalized_path(root, binary), "--serve-hit", unknown_key],
            "generated_inputs": ["token", "shared_root", "reply_file"],
            "setup": {
                "cluster-init": {
                    "exit": cluster.returncode,
                    "stdout": normalize_transport_output(cluster.stdout, work),
                    "stderr": normalize_transport_output(cluster.stderr, work),
                },
                "mint-token": {
                    "exit": minted.returncode,
                    "stdout": normalize_transport_output(minted.stdout, work),
                    "stderr": normalize_transport_output(minted.stderr, work),
                },
                "serve-hit": {
                    "exit": served.returncode,
                    "stdout": normalize_transport_output(served.stdout, work),
                    "stderr": normalize_transport_output(served.stderr, work),
                },
            },
            "exit": served.returncode,
            "stdout": text(served.stdout),
            "stderr": text(served.stderr),
            "reply_file": "transport-reply.txt",
            "reply_sha256": sha256(reply_bytes),
            "unknown_key": unknown_key,
            "artifacts": transport_metadata(transport_files),
        }

        diagnostics_home = work / "diagnostics-home"
        diagnostics_home.mkdir()
        diagnostic = invoke(binary, ["lisp/tests/golden/diagnostics-input.pp"], root,
                            diagnostics_home)
        diagnostic_bytes = diagnostic.stderr
        (golden / "diagnostic.stderr").write_bytes(diagnostic_bytes)
        expected["cases"]["diagnostic-source-range"] = {
            "argv": [normalized_path(root, binary), "lisp/tests/golden/diagnostics-input.pp"],
            "exit": diagnostic.returncode,
            "stdout": text(diagnostic.stdout),
            "stderr": text(diagnostic.stderr),
            "stderr_file": "diagnostic.stderr",
            "stderr_sha256": sha256(diagnostic_bytes),
            "source_range": "lisp/tests/golden/diagnostics-input.pp:1",
        }

    (golden / "manifest.json").write_text(
        json.dumps(expected, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"generated {golden / 'manifest.json'} from {binary}")


def _assert_portable(value: Any, label: str) -> None:
    if isinstance(value, str) and value.startswith("/"):
        raise RuntimeError(f"non-portable absolute path in {label}: {value}")
    if isinstance(value, dict):
        for key, child in value.items():
            _assert_portable(child, f"{label}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _assert_portable(child, f"{label}[{index}]")


def _validate_file_metadata(items: Any, label: str,
                            require_normalized: bool = False) -> None:
    if not isinstance(items, list) or not items:
        raise RuntimeError(f"{label} must be a non-empty file metadata list")
    paths: set[str] = set()
    for item in items:
        if not isinstance(item, dict) or set(item) - {
                "path", "bytes", "sha256", "normalized_sha256", "volatile"}:
            raise RuntimeError(f"{label} contains malformed metadata")
        if not isinstance(item.get("path"), str) or item["path"].startswith("/"):
            raise RuntimeError(f"{label} contains a non-portable path")
        if item["path"] in paths:
            raise RuntimeError(f"{label} contains duplicate path {item['path']}")
        paths.add(item["path"])
        if not isinstance(item.get("bytes"), int) or item["bytes"] < 0:
            raise RuntimeError(f"{label} has invalid byte size")
        if require_normalized:
            normalized = item.get("normalized_sha256")
            if (not isinstance(normalized, str)
                    or re.fullmatch(r"[0-9a-f]{64}", normalized) is None):
                raise RuntimeError(f"{label} has invalid normalized_sha256")
            raw = item.get("sha256")
            if item.get("volatile"):
                if raw is not None:
                    raise RuntimeError(f"{label} volatile artifact has raw sha256")
            elif (not isinstance(raw, str)
                  or re.fullmatch(r"[0-9a-f]{64}", raw) is None):
                raise RuntimeError(f"{label} has invalid sha256")
        else:
            digest = item.get("sha256")
            if (not isinstance(digest, str)
                    or re.fullmatch(r"[0-9a-f]{64}", digest) is None):
                raise RuntimeError(f"{label} has invalid sha256")


def expected_manifest(root: Path) -> dict[str, Any]:
    path = root / "lisp" / "tests" / "golden" / "manifest.json"
    if not path.exists():
        raise RuntimeError(f"missing {path}; run --generate first")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"invalid manifest {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        raise RuntimeError(f"unsupported golden schema in {path}")
    reference = data.get("reference")
    if not isinstance(reference, dict):
        raise RuntimeError("manifest reference section is required")
    required_reference = {"engine", "binary", "binary_argument_required", "daemon"}
    if set(reference) != required_reference:
        raise RuntimeError("manifest reference schema is incomplete")
    if reference["binary_argument_required"] is not True or reference["daemon"] is not False:
        raise RuntimeError("manifest must require an explicit non-daemon binary")
    cases = data.get("cases")
    if not isinstance(cases, dict) or set(cases) != REQUIRED_CASES:
        actual = sorted(cases) if isinstance(cases, dict) else []
        raise RuntimeError(
            f"manifest case set must be {sorted(REQUIRED_CASES)}, got {actual}")
    for name, required in CASE_REQUIRED_FIELDS.items():
        spec = cases[name]
        if not isinstance(spec, dict) or not required.issubset(spec):
            missing = sorted(required - set(spec)) if isinstance(spec, dict) else sorted(required)
            raise RuntimeError(f"{name} schema is incomplete; missing {missing}")
        argv = spec["argv"]
        if not isinstance(argv, list) or not argv or argv[0] != reference["binary"]:
            raise RuntimeError(f"{name}.argv must start with reference.binary")
        if name in ("canonical-codec", "node-trace", "store-layout"):
            _validate_file_metadata(spec["files"], f"{name}.files")
        if name == "transport-message":
            setup = spec["setup"]
            if not isinstance(setup, dict) or set(setup) != {"cluster-init", "mint-token", "serve-hit"}:
                raise RuntimeError("transport-message.setup schema is incomplete")
            for process in setup.values():
                if (not isinstance(process, dict)
                        or set(process) != {"exit", "stdout", "stderr"}):
                    raise RuntimeError("transport-message.setup process schema is incomplete")
            _validate_file_metadata(spec["artifacts"], "transport-message.artifacts",
                                    require_normalized=True)
        if "object" in spec:
            object_descriptor = spec["object"]
            if not isinstance(object_descriptor, dict) or not {
                "path", "bytes_file", "value_hash", "sha256"
            }.issubset(object_descriptor):
                raise RuntimeError(f"{name}.object schema is incomplete")
        if "trace" in spec:
            trace_descriptor = spec["trace"]
            if (not isinstance(trace_descriptor, dict)
                    or not {"path", "bytes_file", "sha256"}.issubset(trace_descriptor)):
                raise RuntimeError(f"{name}.trace schema is incomplete")
    golden = root / "lisp" / "tests" / "golden"
    def require_golden_file(name: Any, label: str) -> None:
        if (not isinstance(name, str) or Path(name).is_absolute()
                or ".." in Path(name).parts
                or not (golden / name).is_file()):
            raise RuntimeError(f"{label} must name an existing golden fixture")
    def require_source_file(name: Any, label: str) -> None:
        if not isinstance(name, str) or Path(name).is_absolute() or ".." in Path(name).parts:
            raise RuntimeError(f"{label} must name an existing source fixture")
        candidates = (root / name, golden / name)
        if not any(candidate.is_file() for candidate in candidates):
            raise RuntimeError(f"{label} must name an existing source fixture")
    for case_name, spec in cases.items():
        if "source" in spec:
            require_source_file(spec["source"], f"{case_name}.source")
        if "source_range" in spec:
            require_source_file(spec["source_range"].split(":", 1)[0],
                                f"{case_name}.source_range")
        for field in ("stderr_file", "reply_file"):
            if field in spec:
                require_golden_file(spec[field], f"{case_name}.{field}")
        for field in ("object", "trace"):
            descriptor = spec.get(field)
            if isinstance(descriptor, dict) and descriptor.get("bytes_file") is not None:
                require_golden_file(descriptor["bytes_file"],
                                    f"{case_name}.{field}.bytes_file")
    _assert_portable(data, "manifest")
    return data


def compare_bytes(actual: bytes, expected: bytes, label: str, failures: list[str]) -> None:
    if actual != expected:
        failures.append(f"{label}: bytes differ (actual sha256={sha256(actual)}, expected sha256={sha256(expected)})")


def run_case(root: Path, binary: Path, name: str, spec: dict[str, Any]) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix=f"pp-m0-{name}-") as raw:
        work = Path(raw)
        home = work / "home"
        home.mkdir()
        if name in ("canonical-codec", "node-trace", "store-layout"):
            proc = invoke(binary, [f"lisp/tests/golden/{spec['source']}"], root, home)
            return {
                "exit": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr,
                "store": store_files(home),
            }
        if name == "diagnostic-source-range":
            proc = invoke(binary, ["lisp/tests/golden/diagnostics-input.pp"], root, home)
            return {"exit": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr,
                    "store": store_files(home)}
        if name == "transport-message":
            token = work / "token.txt"
            shared = work / "shared"
            reply = work / "reply.txt"
            cluster = invoke(binary, ["cluster-init"], root, home)
            minted = (invoke(binary, ["--mint-token", str(token), "3600"], root, home)
                      if cluster.returncode == 0 else None)
            served = (invoke(binary, ["--serve-hit", spec["unknown_key"], str(token),
                                      str(shared), str(reply)], root, home)
                      if minted is not None and minted.returncode == 0 else None)
            final = served or minted or cluster
            def setup_record(proc: subprocess.CompletedProcess[bytes] | None) -> dict[str, Any]:
                if proc is None:
                    return {"exit": -1, "stdout": "", "stderr": "not run"}
                return {
                    "exit": proc.returncode,
                    "stdout": normalize_transport_output(proc.stdout, work),
                    "stderr": normalize_transport_output(proc.stderr, work),
                }
            artifacts = transport_artifacts(work, home, token, shared, reply)
            return {
                "exit": final.returncode,
                "stdout": final.stdout,
                "stderr": final.stderr,
                "reply": read_bytes(reply) if reply.exists() else b"",
                "setup": {
                    "cluster-init": setup_record(cluster),
                    "mint-token": setup_record(minted),
                    "serve-hit": setup_record(served),
                },
                "artifacts": transport_metadata(artifacts),
            }
    raise RuntimeError(f"unknown golden case {name}")


def compare_artifacts(actual: list[dict[str, Any]], expected: list[dict[str, Any]],
                      label: str, failures: list[str]) -> None:
    one = {item["path"]: item for item in actual}
    two = {item["path"]: item for item in expected}
    if set(one) != set(two):
        failures.append(f"{label}: paths differ: actual={sorted(one)} expected={sorted(two)}")
        return
    for path in sorted(two):
        a, e = one[path], two[path]
        if a["bytes"] != e["bytes"]:
            failures.append(f"{label}: {path} byte size differs")
        if bool(e.get("volatile")) != bool(a.get("volatile")):
            failures.append(f"{label}: {path} volatility differs")
        if a["normalized_sha256"] != e["normalized_sha256"]:
            failures.append(f"{label}: {path} normalized sha256 differs")
        if not e.get("volatile") and a["sha256"] != e["sha256"]:
            failures.append(f"{label}: {path} sha256 differs")


def check_case(root: Path, binary: Path, name: str, spec: dict[str, Any]) -> list[str]:
    golden = root / "lisp" / "tests" / "golden"
    result = run_case(root, binary, name, spec)
    failures: list[str] = []
    if result["exit"] != spec.get("exit", 0):
        failures.append(f"{name}: exit {result['exit']} != {spec.get('exit', 0)}")
    compare_bytes(result["stdout"], spec.get("stdout", "").encode(), f"{name}: stdout", failures)
    compare_bytes(
        comparable_case_bytes(root, name, spec, "stderr", result["stderr"]),
        comparable_case_bytes(root, name, spec, "stderr",
                              spec.get("stderr", "").encode()),
        f"{name}: stderr", failures)
    if name in ("canonical-codec", "node-trace", "store-layout"):
        actual = result["store"]
        # Store inventory is compared exactly, including VERSION and object/
        # trace bytes. Lock files are deliberately excluded as ephemeral.
        expected_paths = {item["path"] for item in spec.get("files", [])}
        if set(actual) != expected_paths:
            failures.append(f"{name}: store paths differ: actual={sorted(actual)} expected={sorted(expected_paths)}")
        for item in spec.get("files", []):
            path = item["path"]
            if path in actual:
                if item.get("bytes") != len(actual[path]):
                    failures.append(f"{name}: {path} byte size differs")
                if item.get("sha256") != sha256(actual[path]):
                    failures.append(f"{name}: {path} sha256 differs (actual={sha256(actual[path])}, expected={item['sha256']})")
        if name == "canonical-codec":
            obj = spec["object"]
            if obj["path"] not in actual:
                failures.append(f"{name}: missing object {obj['path']}")
            else:
                expected_object = (golden / obj["bytes_file"]).read_bytes()
                compare_bytes(actual[obj["path"]], expected_object,
                              f"{name}: canonical object", failures)
                if obj["sha256"] != sha256(expected_object):
                    failures.append(f"{name}: object metadata sha256 is inconsistent")
        if name == "node-trace":
            trace = spec["trace"]
            if trace["path"] not in actual:
                failures.append(f"{name}: missing trace {trace['path']}")
            else:
                expected_trace = (golden / trace["bytes_file"]).read_bytes()
                compare_bytes(actual[trace["path"]], expected_trace,
                              f"{name}: trace", failures)
                if trace["sha256"] != sha256(expected_trace):
                    failures.append(f"{name}: trace metadata sha256 is inconsistent")
    elif name == "transport-message":
        for phase, expected in spec["setup"].items():
            actual = result["setup"].get(phase)
            if actual != expected:
                failures.append(f"{name}: {phase} setup output differs")
        compare_artifacts(result["artifacts"], spec["artifacts"],
                          f"{name}: durable artifacts", failures)
        expected_reply = (golden / spec["reply_file"]).read_bytes()
        compare_bytes(result["reply"], expected_reply,
                      f"{name}: reply", failures)
        if spec["reply_sha256"] != sha256(expected_reply):
            failures.append(f"{name}: reply metadata sha256 is inconsistent")
    elif name == "diagnostic-source-range":
        expected_diagnostic = (golden / spec["stderr_file"]).read_bytes()
        compare_bytes(
            comparable_case_bytes(root, name, spec, "stderr", result["stderr"]),
            comparable_case_bytes(root, name, spec, "stderr", expected_diagnostic),
            f"{name}: diagnostic", failures)
        if spec["stderr_sha256"] != sha256(expected_diagnostic):
            failures.append(f"{name}: diagnostic metadata sha256 is inconsistent")
    return failures


def run_check(root: Path, binary: Path, compare_with: Path | None = None) -> int:
    manifest = expected_manifest(root)
    failures: list[str] = []
    first: dict[str, dict[str, Any]] = {}
    for name, spec in manifest["cases"].items():
        failures.extend(check_case(root, binary, name, spec))
        if compare_with is not None:
            # Re-run the shared case once for the second engine.  The returned
            # bytes are kept only for process-output/artifact comparison below.
            first[name] = run_case(root, binary, name, spec)
    if compare_with is not None:
        for name, spec in manifest["cases"].items():
            other = run_case(root, compare_with, name, spec)
            one = first[name]
            for key in ("exit", "stdout", "stderr", "reply"):
                if key in one or key in other:
                    first_value = one.get(key)
                    other_value = other.get(key)
                    if key == "stderr":
                        first_value = comparable_case_bytes(
                            root, name, spec, key, first_value)
                        other_value = comparable_case_bytes(
                            root, name, spec, key, other_value)
                    if first_value != other_value:
                        failures.append(f"compare {name}: {key} differs between engines")
            if name in ("canonical-codec", "node-trace", "store-layout"):
                if one.get("store") != other.get("store"):
                    failures.append(f"compare {name}: durable store artifacts differ between engines")
            if name == "transport-message":
                if one.get("setup") != other.get("setup"):
                    failures.append(f"compare {name}: setup process output differs between engines")
                compare_artifacts(one.get("artifacts", []), other.get("artifacts", []),
                                  f"compare {name}: durable artifacts", failures)
    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return 1
    label = f"{binary}" if compare_with is None else f"{binary} vs {compare_with}"
    print(f"PASS golden {label}: {len(manifest['cases'])} shared cases")
    return 0


def make_parallel_source(root: Path) -> Path:
    return root / "lisp" / "tests" / "golden" / "parallel.pp"


def benchmark_contract(name: str, proc: subprocess.CompletedProcess[bytes],
                       before: dict[str, bytes], after: dict[str, bytes]) -> None:
    if proc.returncode != 0:
        raise RuntimeError(f"{name}: command exited {proc.returncode}")
    stdout, stderr = proc.stdout, proc.stderr
    node_paths = [path for path in after if path.startswith(("objects/", "traces/"))]
    if name == "startup":
        if not re.fullmatch(rb"pp v[0-9]+\.[0-9]+\.[0-9]+[^\n]*\n", stdout):
            raise RuntimeError(f"{name}: unexpected version output: {text(stdout)}")
        if stderr or node_paths:
            raise RuntimeError(f"{name}: startup produced unexpected durable output")
    elif name == "parse":
        if not (stdout.startswith(b"(print (force (node [")
                and b'"m0"' in stdout and stdout.endswith(b")))\n")):
            raise RuntimeError(f"{name}: parser output contract failed: {text(stdout)}")
        if stderr or node_paths:
            raise RuntimeError(f"{name}: parse created runtime artifacts")
    elif name == "pure_evaluation":
        if stdout != b"3\n" or stderr or node_paths:
            raise RuntimeError(f"{name}: expected 3 and no durable node artifacts")
    elif name in ("cold_node", "warm_node"):
        if stdout != b"42\n" or stderr:
            raise RuntimeError(f"{name}: expected 42 on stdout and empty stderr")
        if not any(path.startswith("objects/") for path in after):
            raise RuntimeError(f"{name}: no result object was stored")
        if not any(path.startswith("traces/") for path in after):
            raise RuntimeError(f"{name}: no node trace was stored")
        if name == "warm_node" and after != before:
            raise RuntimeError(f"{name}: warm invocation changed durable store")
    elif name == "store_lookup":
        if stdout != b"42\n" or b"[why]" not in stderr:
            raise RuntimeError(f"{name}: why lookup did not report the node result")
        if after != before:
            raise RuntimeError(f"{name}: lookup changed durable store")
    elif name == "gc":
        if not re.fullmatch(
                rb"pp gc: objects kept=[0-9]+ deleted=[0-9]+, "
                rb"traces kept=[0-9]+ deleted=[0-9]+, "
                rb"blobs kept=[0-9]+ deleted=[0-9]+\n", stdout):
            raise RuntimeError(f"{name}: unexpected GC report: {text(stdout)}")
        if stderr or "gc-roots" not in before or "gc-roots" not in after:
            raise RuntimeError(f"{name}: rooted GC contract failed")
        if len(after) >= len(before):
            raise RuntimeError(f"{name}: GC did not sweep any durable artifact")
    elif name == "parallel_build":
        if stdout != b"[2 3 4 5 6 7 8 9]\n" or stderr:
            raise RuntimeError(f"{name}: expected eight forced node results")
        if sum(path.startswith("traces/") for path in after) < 9:
            raise RuntimeError(f"{name}: fewer than nine node traces; no parallel batch")
        if sum(path.startswith("objects/") for path in after) < 9:
            raise RuntimeError(f"{name}: fewer than nine node objects; no parallel batch")
    else:
        raise RuntimeError(f"unknown benchmark workload {name}")


def timed(binary: Path, args: list[str], root: Path, home: Path,
          name: str, contract: Callable[[str, subprocess.CompletedProcess[bytes],
                                          dict[str, bytes], dict[str, bytes]], None]
          | None = None) -> float:
    before = store_files(home)
    start = time.perf_counter_ns()
    proc = invoke(binary, args, root, home)
    elapsed = (time.perf_counter_ns() - start) / 1_000_000.0
    if proc.returncode != 0:
        raise RuntimeError(
            f"benchmark command failed ({proc.returncode}): {binary} {' '.join(args)}\n"
            f"stdout={text(proc.stdout)}stderr={text(proc.stderr)}"
        )
    after = store_files(home)
    if contract is not None:
        contract(name, proc, before, after)
    return elapsed


def benchmark(root: Path, binary: Path, samples: int, warmups: int,
              output: Path) -> None:
    write_source_fixtures(root)
    source_codec = "lisp/tests/golden/codec.pp"
    source_node = "lisp/tests/golden/node.pp"
    source_parallel = "lisp/tests/golden/parallel.pp"
    source_gc = "lisp/tests/golden/gc.pp"
    workloads: dict[str, Callable[[Path], float]] = {}

    def fresh(label: str, args: list[str]) -> Callable[[Path], float]:
        def run(_: Path) -> float:
            with tempfile.TemporaryDirectory(prefix=f"pp-m0-bench-{label}-") as raw:
                return timed(binary, args, root, Path(raw) / "home",
                             label, benchmark_contract)
        return run

    workloads["startup"] = fresh("startup", ["--version"])
    workloads["parse"] = fresh("parse", ["fmt", "--to-sexpr", source_codec])
    workloads["pure_evaluation"] = fresh("pure_evaluation", ["-e", "1 + 2"])
    workloads["cold_node"] = fresh("cold_node", [source_node])

    def warm_node(_: Path) -> float:
        with tempfile.TemporaryDirectory(prefix="pp-m0-bench-warm-") as raw:
            home = Path(raw) / "home"
            first = invoke(binary, [source_node], root, home)
            if first.returncode != 0 or first.stdout != b"42\n" or first.stderr:
                raise RuntimeError(f"warm-node setup contract failed: {text(first.stderr)}")
            if not store_files(home):
                raise RuntimeError("warm-node setup produced no durable store")
            return timed(binary, [source_node], root, home,
                         "warm_node", benchmark_contract)
    workloads["warm_node"] = warm_node

    def store_lookup(_: Path) -> float:
        with tempfile.TemporaryDirectory(prefix="pp-m0-bench-store-") as raw:
            home = Path(raw) / "home"
            first = invoke(binary, [source_node], root, home)
            if first.returncode != 0 or first.stdout != b"42\n" or first.stderr:
                raise RuntimeError(f"store setup contract failed: {text(first.stderr)}")
            if not any(path.startswith("traces/") for path in store_files(home)):
                raise RuntimeError("store setup produced no node trace")
            return timed(binary, ["why", source_node], root, home,
                         "store_lookup", benchmark_contract)
    workloads["store_lookup"] = store_lookup

    def gc(_: Path) -> float:
        with tempfile.TemporaryDirectory(prefix="pp-m0-bench-gc-") as raw:
            work = Path(raw)
            home = work / "home"
            target = work / "reconciled"
            target.mkdir()
            first = invoke(binary, [
                "--grant", f"fs:{target}:rw", "--reconcile", str(target), source_gc,
            ], root, home)
            if first.returncode != 0:
                raise RuntimeError(f"gc setup failed: {text(first.stderr)}")
            if first.stdout or b"[reconcile:fs]" not in first.stderr:
                raise RuntimeError("gc setup did not report a filesystem reconciliation")
            if (target / "m0.txt").read_bytes() != b"m0":
                raise RuntimeError("gc setup did not materialize its desired root")
            rooted = store_files(home)
            if "gc-roots" not in rooted or not any(
                    path.startswith(("objects/", "traces/")) for path in rooted):
                raise RuntimeError("gc setup did not create reachable durable roots")
            return timed(binary, ["gc", "--gc-keep-epochs", "1",
                                  "--gc-grace-seconds", "0"], root, home,
                         "gc", benchmark_contract)
    workloads["gc"] = gc
    workloads["parallel_build"] = fresh(
        "parallel_build", ["--schedule", "parallel:4", source_parallel])

    binary_meta = normalized_path(root, binary)
    data: dict[str, Any] = {
        "schema": "pp-m0-benchmark-v1",
        "binary": binary_meta,
        "binary_sha256": sha256(binary.read_bytes()),
        "binary_size_bytes": binary.stat().st_size,
        "binary_argument_required": True,
        "daemon": False,
        "cwd": ".",
        "path_policy": "all committed paths are relative to cwd",
        "process_model": "one direct child process per measurement; no daemon",
        "commands": {
            "startup": [binary_meta, "--version"],
            "parse": [binary_meta, "fmt", "--to-sexpr", source_codec],
            "pure_evaluation": [binary_meta, "-e", "1 + 2"],
            "cold_node": [binary_meta, source_node],
            "warm_node": [binary_meta, source_node],
            "store_lookup": [binary_meta, "why", source_node],
            "gc": [binary_meta, "gc", "--gc-keep-epochs", "1", "--gc-grace-seconds", "0"],
            "parallel_build": [binary_meta, "--schedule", "parallel:4", source_parallel],
        },
        "workloads": {},
    }
    for name, workload in workloads.items():
        for _ in range(warmups):
            workload(root)
        values = [workload(root) for _ in range(samples)]
        data["workloads"][name] = {
            "unit": "ms",
            "median": round(statistics.median(values), 3),
            "variance": round(statistics.pvariance(values), 6),
            "min": round(min(values), 3),
            "max": round(max(values), 3),
            "samples": [round(value, 3) for value in values],
        }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {output}")
    for name, result in data["workloads"].items():
        print(f"{name}: median={result['median']:.3f}ms variance={result['variance']:.6f}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--generate", action="store_true")
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--compare", action="store_true")
    modes.add_argument("--benchmark", action="store_true")
    parser.add_argument("--binary", type=Path,
                        help="one explicit engine executable for --generate/--check/--benchmark")
    parser.add_argument("--reference", type=Path,
                        help="explicit reference executable for --compare")
    parser.add_argument("--candidate", type=Path,
                        help="explicit candidate executable for --compare")
    parser.add_argument("--samples", type=int, default=11)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def explicit_binary(path: Path | None, label: str) -> Path:
    if path is None:
        raise SystemExit(f"{label} is required; pass an explicit executable path")
    resolved = path.resolve()
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise SystemExit(f"{label} is not an executable file: {resolved}")
    return resolved


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    if args.generate:
        generate_golden(root, explicit_binary(args.binary, "--binary"))
        return 0
    if args.check:
        return run_check(root, explicit_binary(args.binary, "--binary"))
    if args.compare:
        reference = explicit_binary(args.reference, "--reference")
        candidate = explicit_binary(args.candidate, "--candidate")
        return run_check(root, reference, candidate)
    binary = explicit_binary(args.binary, "--binary")
    if args.samples < 1 or args.warmups < 0:
        raise SystemExit("--samples must be >= 1 and --warmups must be >= 0")
    output = args.output or (root / "scripts" / "benchmarks" / "m0-baseline.json")
    benchmark(root, binary, args.samples, args.warmups, output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
