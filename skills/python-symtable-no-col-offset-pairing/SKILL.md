---
name: python-symtable-no-col-offset-pairing
description: |
  Pair Python `symtable.SymbolTable` entries with `ast` nodes when the
  symtable side does NOT expose `col_offset`. Use when: (1) building
  a static analyzer that needs per-scope shadow / local-binding sets
  from `symtable` (e.g. `is_local()`, `is_parameter()`,
  `is_imported()`) but also needs to key those sets by AST position,
  (2) seeing colliding keys like `("function", lineno, "lambda")`
  for two lambdas on the same source line (`a, b = lambda: 1,
  lambda: 2`), (3) writing a deferred-scope shadow lookup that
  works correctly when multiple FunctionDef / Lambda share lineno
  and name. The standard library `symtable` module (verified on
  CPython 3.14) exposes `get_lineno()` and `get_name()` but no
  public `get_col_offset()` — and the private `_table.col_offset`
  attribute is not populated either. So the AST col_offset cannot
  be carried through symtable; you must pair the two walks
  separately and assign the AST's col_offset on lookup. Covers the
  group-by-(lineno, name) pairing strategy that avoids both global
  walk-order coupling and cross-Python-version comprehension-scope
  differences (genexpr vs inlined listcomp / setcomp / dictcomp).
author: Claude Code
version: 1.0.0
date: 2026-05-14
---

# Pairing Python symtable with AST when symtable lacks col_offset

## Problem

When you build a deferred-scope shadow map for a Python static
analyzer, the natural source of "what names are local in this
function / lambda" is `symtable.SymbolTable`: it exposes
`get_identifiers()`, and for each name `is_local()`,
`is_parameter()`, `is_imported()`. That gives you the local-shadow
set for free without re-implementing scope rules.

The problem is keying. The analyzer walks the AST and asks "what's
the shadow set for *this* `ast.FunctionDef` / `ast.Lambda` node?"
You want a unique key per scope. The obvious key is
`(lineno, col_offset, name_or_"lambda")`. But CPython's `symtable`
module exposes `get_lineno()` and `get_name()` and NOT
`get_col_offset()` — and the private `_table.col_offset`
attribute is `None`. Verified on CPython 3.14:

```python
>>> import symtable
>>> t = symtable.symtable('a, b = lambda: 1, lambda: 2', '<x>', 'exec')
>>> [m for m in dir(symtable.SymbolTable) if 'col' in m.lower()]
[]
>>> c = t.get_children()[0]
>>> getattr(c.__dict__.get('_table'), 'col_offset', None)
None
```

So the symtable side can only produce `(lineno, name)` keys. Two
lambdas on the same source line both have lineno=L and name="lambda"
— their entries collide.

The naive workaround is to key by `(lineno, name)` on both sides
and store entries in a FIFO `deque`, then `popleft()` at AST-visit
time. This *appears* to work because `symtable.get_children()` and
`ast.iter_child_nodes` both produce children in source order, so
FIFO consumption lines up. But the invariant is undocumented and
brittle — any future visitor reordering, a Python version change
in symtable's compiler-side traversal, or a same-line same-name
collision in a place where AST walk order diverges from symtable
walk order silently mis-shadows.

## Context / Trigger Conditions

Use this skill when:

1. You are reading from `symtable` to compute per-scope shadow sets
   (or any per-scope metadata) that you intend to key by AST
   position.
2. You hit a same-line same-name scope collision — most commonly
   multiple lambdas on a tuple-unpack line like
   `a, b = lambda: 1, lambda: 2`. The symtable yields two
   `("function", lineno, "lambda")` entries that are
   indistinguishable on its side.
3. You looked for `SymbolTable.get_col_offset()` and it does not
   exist (verified through CPython 3.14).
4. You also need to handle comprehension scopes whose presence
   differs across Python versions: 3.10–3.11 give `listcomp`,
   `setcomp`, `dictcomp`, `genexpr` symtable children; 3.12+ inline
   the first three and keep only `genexpr`. PEP 709.
5. You want a pairing that does NOT depend on AST walk order
   matching CPython's compiler-side symtable visit order globally,
   because that ordering is genuinely different in
   AST-decorator-on-FunctionDef cases (decorators evaluate in the
   outer scope; their nested lambdas become children of the OUTER
   symtable scope, not of the FunctionDef they decorate) and the
   `_fields` order on FunctionDef does NOT match source order
   anyway (`decorator_list` comes after `body` in `_fields`).

## Solution: group-by-(lineno, name) pairing

Walk symtable and AST INDEPENDENTLY, then pair within each
`(lineno, name)` group. Within a group, both sides emit siblings
in the same order — symtable in CPython AST-visit registration
order, AST sorted by `col_offset` — so a zip is unambiguous. This
avoids global-walk-order coupling.

```python
import ast, symtable
from collections import defaultdict

# Comprehension scope names that symtable emits (varies by Python
# version per PEP 709). The analyzer almost never pushes a
# deferred-function scope for these, so skip them on the sym side
# but still recurse to collect any function/lambda inside them.
_COMPREHENSION_SCOPE_NAMES = frozenset(
    ("genexpr", "listcomp", "setcomp", "dictcomp")
)

def build_scope_shadow_map(source: str, tree: ast.AST) -> dict:
    """Return dict keyed by ("function", lineno, col_offset, name)
    -> set of identifiers that shadow outer aliases inside that
    function / lambda scope."""

    # Phase 1: gather symtable function entries grouped by
    # (lineno, name).
    sym_groups = defaultdict(list)

    def sym_walk(table):
        for child in table.get_children():
            if child.get_type() == "annotation":
                continue
            if child.get_type() == "function":
                if child.get_name() not in _COMPREHENSION_SCOPE_NAMES:
                    shadowed = set()
                    for ident in child.get_identifiers():
                        sym = child.lookup(ident)
                        if (
                            sym.is_local()
                            or sym.is_parameter()
                            or sym.is_imported()
                        ):
                            shadowed.add(ident)
                    sym_groups[
                        (child.get_lineno(), child.get_name())
                    ].append(shadowed)
            sym_walk(child)

    sym_walk(symtable.symtable(source, "<analysis>", "exec"))

    # Phase 2: gather AST function / lambda nodes grouped by
    # (lineno, name).
    ast_groups = defaultdict(list)
    for node in ast.walk(tree):
        if isinstance(
            node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)
        ):
            name = (
                "lambda" if isinstance(node, ast.Lambda) else node.name
            )
            ast_groups[(node.lineno, name)].append(node)

    # Phase 3: pair within each group. Sort AST by col_offset; zip
    # with symtable group. CPython's compiler-side symtable visit
    # registers siblings in AST-visit (and therefore source) order,
    # so this aligns within a (lineno, name) group.
    result = {}
    for group_key in set(sym_groups) | set(ast_groups):
        sym_list = sym_groups.get(group_key, [])
        ast_list = sorted(
            ast_groups.get(group_key, []),
            key=lambda n: getattr(n, "col_offset", 0),
        )
        if len(sym_list) != len(ast_list):
            raise RuntimeError(
                "symtable / AST function-scope count mismatch for "
                "(lineno={}, name={!r}): symtable={}, AST={}".format(
                    group_key[0], group_key[1],
                    len(sym_list), len(ast_list),
                )
            )
        for shadowed, node in zip(sym_list, ast_list):
            col = getattr(node, "col_offset", 0)
            result[("function", node.lineno, col, group_key[1])] = (
                shadowed
            )
    return result
```

Then on the AST side, the lookup key is unique:

```python
def scope_key(node):
    col = getattr(node, "col_offset", 0)
    if isinstance(node, ast.Lambda):
        return ("function", node.lineno, col, "lambda")
    return ("function", node.lineno, col, node.name)
```

No `popleft`, no FIFO, no walk-order coupling, no need to special-case
decorators-evaluated-in-outer-scope. The pairing only depends on
within-group ordering matching, and within a group (same lineno,
same name) the siblings always come from the SAME enclosing scope
in the same compiler visit order, so `col_offset`-sorted AST
aligns with symtable registration order.

## Verification

1. Two lambdas on one line, one shadows an imported name via
   parameter default, the other does not:

   ```python
   from os import system
   a, b = lambda system=print: system('x'), lambda: system('y')
   ```

   Expected: lambda 1 has `system` in its shadow set; lambda 2
   does not. Mirror image (swap the two lambdas) must also work.

2. Three lambdas on one line:

   ```python
   from os import system
   x = [lambda system=print: system('a'),
        lambda system=print: system('b'),
        lambda: system('c')]
   ```

   Expected: only the third lambda's call should be reported as
   the destructive `os.system`.

3. Cross-version: run the same source under CPython 3.10, 3.11,
   3.12, 3.13, 3.14. The `listcomp` / `setcomp` / `dictcomp`
   skip-by-name filter handles the PEP 709 inlining transition.
   Only `genexpr` retains its own scope on modern CPython.

## Notes

- The `_table.col_offset` private attribute is `None` on 3.14
  (confirmed). Do NOT rely on it even on Pythons where it might be
  populated — it is not part of the public API.
- The `Symbol.get_id()` exposed on symtable returns a memory id of
  the underlying C structure; it does not match
  `id(ast_node)`, so it cannot bridge the two sides directly.
- Walk-order coupling that the naive `deque` approach hides:
  `FunctionDef._fields` order is `(name, args, body, decorator_list,
  returns, type_comment, type_params)` — `decorator_list` comes AFTER
  `body`. CPython's symtable visitor evaluates decorators (and any
  nested lambdas inside them) in the ENCLOSING scope BEFORE
  entering the function's own scope. So `ast.iter_child_nodes(fn)`
  yields children in `_fields` order, not source order, and the
  resulting global walk order diverges from symtable's for any
  function whose decorator contains a lambda. The group-by-(lineno,
  name) approach sidesteps this by never relying on global walk
  order — only per-group alignment of siblings parsed from the same
  source span.
- Comprehension scope handling per CPython version:
  - 3.8 – 3.11: all four (`listcomp`, `setcomp`, `dictcomp`,
    `genexpr`) get their own symtable child.
  - 3.12+: PEP 709 inlines `listcomp` / `setcomp` / `dictcomp`.
    Only `genexpr` retains its own scope.
  - Skipping by name on the symtable side (and not yielding
    `ast.GeneratorExp` / `ast.ListComp` / etc. on the AST side)
    keeps the two sides aligned without per-version code.
- PEP 572 (walrus) inside a comprehension or generator expression
  binds the target in the ENCLOSING scope, not in the
  comprehension scope. The analyzer side sees `system` in the
  enclosing function's `get_identifiers()` automatically; you do
  not need to special-case this in symtable consumption.
- Same approach works for any per-scope metadata pulled from
  symtable that the analyzer wants to key by AST position, not
  just shadow sets.

## References

- [Python symtable module docs](https://docs.python.org/3/library/symtable.html)
- [PEP 709 — Inlined comprehensions (3.12+)](https://peps.python.org/pep-0709/)
- [PEP 572 — Assignment expressions / walrus](https://peps.python.org/pep-0572/)
- Worked example: a deferred-scope shadow-map builder (`_build_scope_shadow_map`) that pairs symtable scopes to AST nodes by grouping on (lineno, name) as above.
- Related: `python-ast-static-analyzer-scoping` (broader scope of import-alias resolution + execution-time model)
