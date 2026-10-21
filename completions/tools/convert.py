#!/usr/bin/env python3
"""Pack JSON command specs into lazily sourceable zsh data.

Development tool only: the plugin itself needs nothing but zsh. With no arguments
it reads `../json` and writes `../zsh`; pass SOURCE or SOURCE OUT for other
directories. Node records are packed into one blob per command so zsh can split
it in C instead of parsing a huge array literal.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

RS = "\x1e"  # node record separator
FS = "\x1f"  # node field separator
GS = "\x1d"  # list separator (names, child ids, suggestion fields)
SRS = "\x1c"  # suggestion record separator

DEFAULT_PRIORITY = 50


def clean(value: object) -> str:
    """single-line, separator-free text safe for the zsh blob"""
    if value is None:
        return ""
    text = str(value)
    text = "".join(" " if ord(char) < 32 or ord(char) == 127 else char
                   for char in text)
    return text.strip()


def names_of(item: dict) -> list[str]:
    name = item.get("name")
    if isinstance(name, str):
        return [clean(name)]
    if isinstance(name, list):
        cleaned = [clean(entry) for entry in name if isinstance(entry, str)]
        return [entry for entry in cleaned if entry]
    return []


def item_list(item: dict, key: str) -> list[dict]:
    value = item.get(key)
    return [entry for entry in value if isinstance(entry, dict)] if isinstance(value, list) else []


def item_args(item: dict) -> list[dict]:
    args = item.get("args")
    if args is None:
        return []
    return args if isinstance(args, list) else [args]


def priority_of(item: dict) -> int:
    value = item.get("priority", DEFAULT_PRIORITY)
    try:
        value = int(value)
    except (TypeError, ValueError):
        value = DEFAULT_PRIORITY
    return max(0, min(value, 100))


def repeatable(item: dict) -> bool:
    value = item.get("isRepeatable", False)
    if isinstance(value, bool):
        return value
    return isinstance(value, (int, float)) and value > 1


def optional_arg(arg: dict) -> bool:
    return bool(arg.get("isOptional"))


def variadic_arg(arg: dict) -> bool:
    return bool(arg.get("isVariadic"))


def arg_is_empty(arg: dict) -> bool:
    """an option arg that only exists to say the option takes a value"""
    return not (
        names_of(arg)
        or arg.get("suggestions")
        or arg.get("template")
        or optional_arg(arg)
        or variadic_arg(arg)
    )


@dataclass
class Node:
    kind: str
    names: list[str] = field(default_factory=list)
    desc: str = ""
    priority: int = DEFAULT_PRIORITY
    flags: str = ""
    template: str = ""
    suggestions: list[str] = field(default_factory=list)
    props: list[int] = field(default_factory=list)
    subs: list[int] = field(default_factory=list)
    args: list[int] = field(default_factory=list)


class Converter:
    def __init__(self) -> None:
        self.nodes: list[Node] = []

    def add(self, node: Node) -> int:
        self.nodes.append(node)
        return len(self.nodes)

    def add_arg(self, arg: dict) -> int:
        flags = ""
        if optional_arg(arg):
            flags += "O"
        if variadic_arg(arg):
            flags += "V"
        suggestions = []
        for suggestion in arg.get("suggestions") or []:
            if isinstance(suggestion, str):
                suggestions.append(GS.join([clean(suggestion), clean(arg.get("description")), "", "0"]))
            elif isinstance(suggestion, dict):
                suggestions.append(GS.join([
                    GS.join(names_of(suggestion)),
                    clean(suggestion.get("description")),
                    "" if suggestion.get("priority") is None else str(priority_of(suggestion)),
                    "1" if bool(suggestion.get("hidden")) else "0",
                ]))
        return self.add(Node(
            kind="a",
            flags=flags,
            template=clean(arg.get("template")),
            suggestions=suggestions,
        ))

    def add_option(self, option: dict) -> int:
        flags = ""
        if bool(option.get("isPersistent")):
            flags += "P"
        if repeatable(option):
            flags += "R"
        if bool(option.get("hidden")):
            flags += "H"
        node = Node(
            kind="o",
            names=names_of(option),
            desc=clean(option.get("description")),
            priority=priority_of(option),
            flags=flags,
        )
        nid = self.add(node)
        args = item_args(option)
        # a lone empty required arg only means "takes a value"; keep that in a
        # flag instead of a node. anything else keeps its arg nodes.
        if len(args) == 1 and arg_is_empty(args[0]):
            node.flags += "T"
        else:
            for arg in args:
                node.args.append(self.add_arg(arg))
        return nid

    def add_node(self, spec: dict, kind: str) -> int:
        flags = ""
        if kind == "s" and bool(spec.get("hidden")):
            flags = "H"
        node = Node(
            kind=kind,
            names=names_of(spec),
            desc=clean(spec.get("description")),
            priority=priority_of(spec),
            flags=flags,
        )
        nid = self.add(node)
        for option in item_list(spec, "options"):
            node.props.append(self.add_option(option))
        for sub in item_list(spec, "subcommands"):
            node.subs.append(self.add_node(sub, "s"))
        for arg in item_args(spec):
            node.args.append(self.add_arg(arg))
        return nid

    def blob(self) -> str:
        records = []
        for node in self.nodes:
            records.append(FS.join([
                node.kind,
                GS.join(node.names),
                node.desc,
                str(node.priority) if node.kind != "a" else "",
                node.flags,
                node.template,
                SRS.join(node.suggestions),
                GS.join(str(child) for child in node.props),
                GS.join(str(child) for child in node.subs),
                GS.join(str(child) for child in node.args),
            ]))
        return RS.join(records)


def zq(text: str) -> str:
    """quote text for zsh $'...'"""
    out = ["$'"]
    escapes = {RS: "\\x1e", FS: "\\x1f", GS: "\\x1d", SRS: "\\x1c"}
    for char in text:
        if char in escapes:
            out.append(escapes[char])
        elif char == "\\":
            out.append("\\\\")
        elif char == "'":
            out.append("\\'")
        elif char == "\n":
            out.append("\\n")
        elif char == "\t":
            out.append("\\t")
        elif char == "\r":
            out.append("\\r")
        elif ord(char) < 32 or ord(char) == 127:
            out.append(" ")
        else:
            out.append(char)
    out.append("'")
    return "".join(out)


def write_if_changed(path: Path, text: str) -> None:
    """rewrite only when the content differs, so compiled caches stay valid"""
    try:
        if path.read_text(encoding="utf-8") == text:
            return
    except (OSError, UnicodeDecodeError):
        pass
    path.write_text(text, encoding="utf-8")


def convert_file(source: Path, out: Path) -> tuple[str, str, int, int]:
    with open(source, encoding="utf-8") as handle:
        spec = json.load(handle)
    if not isinstance(spec, dict):
        raise ValueError("top-level JSON is not an object")
    converter = Converter()
    converter.add_node(spec, "r")
    text = converter.blob()
    name = source.stem
    header = f"# generated by completions/tools/convert.py from {source.name}; do not edit\n"
    body = (
        "typeset -g __tzc_s_version=1\n"
        f"typeset -g __tzc_s_blob={zq(text)}\n"
        "typeset -g __tzc_s_ok=1\n"
    )
    write_if_changed(out / f"{name}.zsh", header + body)
    return name, clean(spec.get("description")), len(converter.nodes), len(text)


def write_index(entries: list[tuple[str, str]], out: Path) -> None:
    lines = [
        "# generated by completions/tools/convert.py; command -> description\n",
        "typeset -gA __tzc_spec_desc\n",
    ]
    for name, desc in sorted(entries):
        # unquoted: zsh treats quotes inside assoc subscripts literally
        if re.fullmatch(r"[A-Za-z0-9_.+-]+", name):
            lines.append(f"__tzc_spec_desc[{name}]={zq(desc)}\n")
    write_if_changed(out / "index.zsh", "".join(lines))


def main() -> int:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, default=None,
                        help="directory with JSON command specs (default: ../json)")
    parser.add_argument("out", nargs="?", type=Path, default=None,
                        help="output directory (default: ../zsh, or SOURCE if only SOURCE is given)")
    args = parser.parse_args()
    source = args.source or here.parent / "json"
    out = args.out or (source if args.source else here.parent / "zsh")

    if not source.is_dir():
        print(f"spec directory not found: {source}", file=sys.stderr)
        return 1
    paths = sorted(source.glob("*.json"))
    if not paths:
        print(f"no JSON specs in {source}", file=sys.stderr)
        return 1
    out.mkdir(parents=True, exist_ok=True)

    entries: list[tuple[str, str]] = []
    total_nodes = total_bytes = 0
    failures = 0
    for path in paths:
        if path.stem == "index":
            print("skip index.json: reserved name", file=sys.stderr)
            failures += 1
            continue
        try:
            name, desc, nodes, size = convert_file(path, out)
        except (OSError, ValueError) as error:
            print(f"skip {path.name}: {error}", file=sys.stderr)
            failures += 1
            continue
        entries.append((name, desc))
        total_nodes += nodes
        total_bytes += size

    write_index(entries, out)
    print(f"packed {len(entries)} specs, {total_nodes} nodes, {total_bytes} blob chars in {out}")
    if failures:
        print(f"skipped {failures} files", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
