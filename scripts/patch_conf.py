#!/usr/bin/env python3
"""Patch CLIProxyAPI's config in place.

Locates the four settings claudex-setup cares about — top-level `host`,
top-level `port`, `remote-management.allow-remote`, and our entry in
`api-keys` — and rewrites just those lines. Everything else in the file
(other providers' settings, comments, formatting) is left untouched, so this
is safe to run against a config that already has other stuff in it, not just
one this script wrote from scratch.

Usage: patch_conf.py <conf_path> <port> <secret>

`secret` is searched for verbatim in `api-keys` first; if found, that entry
is left as-is (idempotent re-run). If not found, a new entry is appended to
the list (or the list is created) rather than replacing whatever was there,
so a manually added key is never clobbered.
"""
from __future__ import annotations

import re
import sys

# CLIProxyAPI seeds a freshly generated config with these example keys. Their
# mere presence in api-keys trips the proxy's own "unsafe_example_api_key"
# check and disables the endpoints entirely, so they must be stripped, not
# just left alongside the real secret.
PLACEHOLDER_KEY_RE = re.compile(r'^\s*-\s*["\']?your-api-key-\d+["\']?\s*$')


def is_top_level(line: str) -> bool:
    return bool(re.match(r"^\S", line)) and ":" in line


def top_level_key(line: str) -> str | None:
    m = re.match(r"^([A-Za-z0-9_-]+):", line)
    return m.group(1) if m else None


def patch(lines: list[str], port: str, secret: str) -> list[str]:
    out: list[str] = []
    seen = {"host": False, "port": False, "remote-management": False, "api-keys": False}
    i, n = 0, len(lines)

    while i < n:
        line = lines[i]
        key = top_level_key(line) if is_top_level(line) else None

        if key == "host":
            out.append('host: "127.0.0.1"\n')
            seen["host"] = True
            i += 1
            continue

        if key == "port":
            out.append(f"port: {port}\n")
            seen["port"] = True
            i += 1
            continue

        if key == "remote-management":
            out.append(line)
            seen["remote-management"] = True
            i += 1
            found = False
            while i < n and not is_top_level(lines[i]):
                sub = lines[i]
                if re.match(r"^\s*allow-remote:", sub):
                    indent = re.match(r"^(\s*)", sub).group(1)
                    out.append(f"{indent}allow-remote: false\n")
                    found = True
                else:
                    out.append(sub)
                i += 1
            if not found:
                out.append("  allow-remote: false\n")
            continue

        if key == "api-keys":
            out.append(line)
            seen["api-keys"] = True
            i += 1
            # Split the section into real list entries and everything else
            # (blank lines, comments). A comment right after the last entry
            # usually documents the *next* key (e.g. "# Enable debug logging"
            # above `debug:`), not this list, so it needs to stay trailing
            # after whatever we add here rather than swallow our entry.
            kept_items = []
            trailing = []
            has_secret = False
            while i < n and not is_top_level(lines[i]):
                sub = lines[i]
                if PLACEHOLDER_KEY_RE.match(sub):
                    # Drop CLIProxyAPI's example entries (your-api-key-1, etc.):
                    # their mere presence makes the proxy refuse to serve at all.
                    i += 1
                    continue
                if re.match(r"^\s*-", sub):
                    if secret in sub:
                        has_secret = True
                    kept_items.append(sub)
                else:
                    trailing.append(sub)
                i += 1
            out.extend(kept_items)
            if not has_secret:
                out.append(f'  - "{secret}"\n')
            out.extend(trailing)
            continue

        out.append(line)
        i += 1

    if not seen["host"]:
        out.append('host: "127.0.0.1"\n')
    if not seen["port"]:
        out.append(f"port: {port}\n")
    if not seen["remote-management"]:
        out.append("remote-management:\n  allow-remote: false\n")
    if not seen["api-keys"]:
        out.append(f'api-keys:\n  - "{secret}"\n')

    return out


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit("usage: patch_conf.py <conf_path> <port> <secret>")
    conf_path, port, secret = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(conf_path) as f:
        lines = f.readlines()

    patched = patch(lines, port, secret)

    with open(conf_path, "w") as f:
        f.writelines(patched)


if __name__ == "__main__":
    main()
