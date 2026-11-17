"""Static checks for SystemVerilog constructs that Quartus Prime Lite 22.1 rejects (BUG-005).

Usage: python scripts/check_quartus_compat.py <file.sv> [<file.sv> ...]
Exit status 1 if any violation is found. Quartus cannot run in CI, so these rules stand in for it.

Rules:
  QC1  named generate block (`begin : g_...`) outside an explicit generate/endgenerate region
  QC2  `for (` or `if (` at module scope outside generate/endgenerate (a bare generate construct)
  QC3  unary minus applied to a size cast, e.g. `-R_W'(128)`
  QC4  inline genvar declaration, `for (genvar ...)`
  QC5  procedural block (always*/initial/final) whose body is not a begin/end block; the checker
       needs begin/end to know where procedural code ends (the project style requires it anyway)

The checker tracks generate nesting and begin/end scopes on a comment- and string-stripped token
stream. It is deliberately small: it understands the subset of SystemVerilog this project uses.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

PROC_KEYWORDS = {"always", "always_ff", "always_comb", "always_latch", "initial", "final"}
TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_$]*|\d+'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+|\S")
SIZE_CAST_NEG_RE = re.compile(r"-\s*[A-Za-z0-9_]+\s*'\s*\(")


@dataclass
class Violation:
    path: str
    line: int
    rule: str
    text: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.rule}: {self.text}"


def strip_comments_and_strings(src: str) -> str:
    """Blank out comments and string literals, keeping newlines so line numbers survive."""
    out = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(c if c == "\n" else " " for c in src[i:j]))
            i = j
        elif src[i] == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i))
            i = j
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def tokenize(clean: str) -> list[tuple[str, int]]:
    tokens = []
    for line_no, line in enumerate(clean.split("\n"), start=1):
        tokens.extend((m.group(0), line_no) for m in TOKEN_RE.finditer(line))
    return tokens


def skip_parens(tokens: list[tuple[str, int]], i: int) -> int:
    """tokens[i] is '('; return the index just past its matching ')'."""
    depth = 0
    while i < len(tokens):
        if tokens[i][0] == "(":
            depth += 1
        elif tokens[i][0] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def check_source(path: str, src: str) -> list[Violation]:
    clean = strip_comments_and_strings(src)
    violations: list[Violation] = []

    for line_no, line in enumerate(clean.split("\n"), start=1):
        if SIZE_CAST_NEG_RE.search(line):
            violations.append(Violation(path, line_no, "QC3", "unary minus on a size cast"))

    tokens = tokenize(clean)
    gen_depth = 0  # nesting of generate ... endgenerate regions
    scopes: list[str] = []  # one entry per open begin: "proc" or "gen" (or "bare")
    func_depth = 0  # inside function/task bodies (procedural)
    i = 0
    while i < len(tokens):
        tok, line = tokens[i]
        procedural = func_depth > 0 or "proc" in scopes
        if tok == "generate":
            gen_depth += 1
        elif tok == "endgenerate":
            gen_depth = max(0, gen_depth - 1)
        elif tok in ("function", "task"):
            func_depth += 1
        elif tok in ("endfunction", "endtask"):
            func_depth = max(0, func_depth - 1)
        elif tok in PROC_KEYWORDS and not procedural:
            j = i + 1
            if j < len(tokens) and tokens[j][0] == "@":  # event control
                j += 1
                if j < len(tokens) and tokens[j][0] == "(":
                    j = skip_parens(tokens, j)
                elif j < len(tokens):
                    j += 1  # @* or @identifier
            if j < len(tokens) and tokens[j][0] == "begin":
                scopes.append("proc")
                i = j + 1
                continue
            violations.append(
                Violation(path, line, "QC5", f"'{tok}' body is not a begin/end block")
            )
        elif tok == "begin":
            label = None
            if i + 2 < len(tokens) and tokens[i + 1][0] == ":":
                label = tokens[i + 2][0]
            if procedural:
                scopes.append("proc")
            else:
                if label and label.startswith("g_") and gen_depth == 0:
                    violations.append(
                        Violation(path, line, "QC1", f"generate block '{label}' outside generate")
                    )
                scopes.append("gen" if gen_depth else "bare")
        elif tok == "end":
            if scopes:
                scopes.pop()
        elif (
            tok in ("for", "if")
            and not procedural
            and i + 1 < len(tokens)
            and tokens[i + 1][0] == "("
        ):
            if tok == "for" and i + 2 < len(tokens) and tokens[i + 2][0] == "genvar":
                violations.append(Violation(path, line, "QC4", "inline genvar declaration"))
            if gen_depth == 0:
                violations.append(
                    Violation(path, line, "QC2", f"module-scope '{tok} (' outside generate")
                )
        i += 1
    return violations


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    violations = []
    for name in argv:
        violations.extend(check_source(name, Path(name).read_text()))
    for v in violations:
        print(v)
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
