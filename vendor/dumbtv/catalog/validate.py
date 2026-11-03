#!/usr/bin/env python3
"""Validate catalog/devices/*.yaml.

PyYAML gives a full parse. Without it the file is read with a one-level parser
that still enforces every rule in catalog/schema.json that matters at that depth
(enums, patterns, required keys, prompt shape, model list). CI always has PyYAML;
the fallback exists so a contributor on a stock Mac gets the same answer as CI
for anything the shallow parser can see, and is told which mode ran.

Exit codes: 0 valid, 1 problems found.
"""
import json
import pathlib
import re
import sys

try:
    import yaml as _yaml
except ImportError:
    _yaml = None

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEVICES = ROOT / "catalog" / "devices"
SCHEMA_PATH = ROOT / "catalog" / "schema.json"
REQUIRED = ["id", "title", "platform", "developer_mode", "ip_location", "data", "verify"]
NESTED = {"data", "verify", "adb", "launcher", "prompts", "models", "quirks", "known_limits",
          "contributors"}
HANDLE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*$")
WITH_DATA = {"fireos", "androidtv"}
PATH_KEYS = {"packages", "protected", "never_disable", "user_apps", "settings",
             "settings_restore", "blocked", "allowed"}

problems = []
seen = {}


def fail(name, message):
    problems.append(f"{name}: {message}")


def schema():
    try:
        return json.loads(SCHEMA_PATH.read_text())
    except (OSError, ValueError):
        return {}


def scalar_rules(sch, value, label, name):
    """Apply the simple JSON-Schema constraints for one scalar."""
    if value in (None, ""):
        return
    text = str(value)
    if "enum" in sch and text not in sch["enum"]:
        fail(name, f"{label} '{text}' not one of {sch['enum']}")
    if "pattern" in sch and not re.search(sch["pattern"], text):
        fail(name, f"{label} '{text}' does not match {sch['pattern']}")
    if "minLength" in sch and len(text) < sch["minLength"]:
        fail(name, f"{label} must be at least {sch['minLength']} characters")
    if "maximum" in sch:
        try:
            n = int(text)
        except ValueError:
            fail(name, f"{label} must be a number, got '{text}'")
            return
        if "minimum" in sch and n < sch["minimum"]:
            fail(name, f"{label} below {sch['minimum']}")
        if n > sch["maximum"]:
            fail(name, f"{label} above {sch['maximum']}")


def parse_shallow(text):
    """Top-level scalars plus one block of raw lines per top-level key."""
    top, blocks, cur = {}, {}, None
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = re.match(r"^([a-z_]+):\s*(.*?)\s*$", raw)
        if m:
            cur = m.group(1)
            top[cur] = m.group(2)
            blocks.setdefault(cur, [])
            continue
        if cur is not None:
            blocks[cur].append(raw)
    return top, blocks


def block_keys(lines):
    """`key: value` pairs at one level of indentation."""
    out = {}
    for line in lines:
        m = re.match(r"^\s+([a-z_]+):\s*(.*?)\s*$", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def block_items(lines):
    """`- item` entries, with their following key: value lines."""
    items, cur = [], None
    for line in lines:
        if re.match(r"^\s+-\s", line):
            body = re.sub(r"^\s+-\s*", "", line).strip()
            cur = {}
            m = re.match(r"^([a-z_]+):\s*(.*?)\s*$", body)
            if m:
                cur[m.group(1)] = m.group(2).strip('"')
            else:
                cur["__item__"] = body
            items.append(cur)
        elif cur is not None:
            m = re.match(r"^\s+([a-z_]+):\s*(.*?)\s*$", line)
            if m:
                cur[m.group(1)] = m.group(2).strip('"')
    return items


def check_common(path, top, nested, sch, full):
    name = path.name
    for key in REQUIRED:
        value = top.get(key)
        if value in (None, ""):
            # nested blocks are allowed to have no scalar value of their own
            if key in NESTED and key in nested:
                continue
            fail(name, f"missing or empty required key: {key}")

    scalar_rules(sch.get("properties", {}).get("id", {}), top.get("id"), "id", name)
    scalar_rules(sch.get("properties", {}).get("title", {}), top.get("title"), "title", name)
    scalar_rules(sch.get("properties", {}).get("platform", {}), top.get("platform"), "platform", name)
    scalar_rules(sch.get("properties", {}).get("status", {}), top.get("status"), "status", name)

    slug = top.get("id")
    if slug:
        if slug in seen:
            fail(name, f"duplicate id, also used by {seen[slug]}")
        seen[slug] = name
        if slug != path.stem:
            fail(name, f"id '{slug}' must match filename '{path.stem}'")

    platform = top.get("platform")
    if platform in WITH_DATA:
        if not nested.get("data") or not (ROOT / f"data/{platform}/packages.txt").exists():
            fail(name, f"platform '{platform}' needs entries under data:")

    data = nested.get("data") or {}
    verify = nested.get("verify") or {}
    for ref in list(data.values()) + list(verify.values()):
        if isinstance(ref, str) and ref and not (ROOT / ref).exists():
            fail(name, f"points at a missing file: {ref}")
    if platform in WITH_DATA:
        for key in ("packages", "protected", "never_disable"):
            if not str(data.get(key) or "").strip():
                fail(name, f"data.{key} missing or empty")

    for key in ("blocked", "allowed"):
        if key not in verify:
            fail(name, f"verify.{key} missing")

    port = (nested.get("adb") or {}).get("port")
    if port:
        scalar_rules(sch.get("properties", {}).get("adb", {}).get("properties", {}).get("port", {}),
                     port, "adb.port", name)

    prompts = nested.get("prompts") or []
    if prompts and isinstance(prompts[0], str):
        prompts = block_items(prompts)
    for prompt in prompts:
        label = prompt.get("name") or prompt.get("__item__") or "?"
        if not prompt.get("fix"):
            fail(name, f"prompt '{label}' has no fix")
        flag = prompt.get("blocks_automation")
        if flag not in (None, True, False, "true", "false"):
            fail(name, f"prompt '{label}' blocks_automation must be true or false")

    models = nested.get("models") or []
    # A bare "models:" parses as an empty scalar, so it never reaches the list check below.
    if "models" in top and top["models"] in (None, "") and not models:
        fail(name, "models: is empty; list the model numbers, or write models: [] if unknown")
    if models and isinstance(models[0], str) and models[0].strip().startswith("-"):
        models = block_items(models)
    for m in models:
        label = m.get("__item__") if isinstance(m, dict) else str(m)
        if not label:
            fail(name, "empty entry under models:")

    contributors = nested.get("contributors") or []
    if contributors and isinstance(contributors[0], str) and contributors[0].strip().startswith("-"):
        contributors = [c.get("__item__", "") for c in block_items(contributors)]
    for handle in contributors:
        if not HANDLE.match(str(handle).lstrip("@")):
            fail(name, f"contributors: '{handle}' is not a GitHub handle")

    if full:
        for key, value in nested.items():
            if value is None:
                fail(name, f"{key}: must not be empty")


def main():
    files = sorted(p for p in DEVICES.glob("*.yaml") if not p.name.startswith("_"))
    if not files:
        print("no device files found", file=sys.stderr)
        return 1
    sch = schema()

    for path in files:
        text = path.read_text()
        if _yaml:
            try:
                doc = _yaml.safe_load(text) or {}
            except _yaml.YAMLError as exc:
                fail(path.name, f"not valid yaml: {exc}")
                continue
            if not isinstance(doc, dict):
                fail(path.name, "top level must be a mapping")
                continue
            top = {k: v for k, v in doc.items() if not isinstance(v, (dict, list))}
            nested = {k: v for k, v in doc.items() if isinstance(v, (dict, list))}
            nested["data"] = {k: v for k, v in (doc.get("data") or {}).items()} if isinstance(doc.get("data"), dict) else {}
            nested["verify"] = {k: v for k, v in (doc.get("verify") or {}).items()} if isinstance(doc.get("verify"), dict) else {}
            nested["adb"] = doc.get("adb") if isinstance(doc.get("adb"), dict) else {}
            check_common(path, top, nested, sch, full=True)
        else:
            top, blocks = parse_shallow(text)
            nested = {
                "data": block_keys(blocks.get("data", [])),
                "verify": block_keys(blocks.get("verify", [])),
                "adb": block_keys(blocks.get("adb", [])),
                "prompts": blocks.get("prompts", []),
                "models": blocks.get("models", []),
            }
            check_common(path, top, nested, sch, full=False)

    for line in problems:
        print(f"  {line}", file=sys.stderr)
    if problems:
        print(f"\n{len(problems)} problem(s)", file=sys.stderr)
        return 1

    mode = "full parse" if _yaml else "one-level check — install pyyaml for deep parsing (CI always does)"
    print(f"{len(files)} device file(s) valid ({mode})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
