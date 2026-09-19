#!/usr/bin/env python3
"""Convert a torchrun entrypoint script into a paired reading/launching notebook.

    python3 tools/py_to_ipynb.py notebooks/*.py

The scripts in notebooks/ are all torchrun entrypoints: they read RANK,
LOCAL_RANK and WORLD_SIZE from the environment and call init_process_group.
Nothing in them runs correctly in a single notebook kernel, so the notebook this
produces is not a translation of the script into cells that execute in order.
It is two things instead:

  1. A launch cell that shells out to torchrun, which is how the script is
     actually meant to run.
  2. The source, split at top-level definitions, so the code can be read and
     edited next to the output.

The .py stays the entrypoint. Editing a source cell does not write back to it;
re-run this script after changing the .py to refresh the notebook.
"""
import argparse
import ast
import pathlib
import sys

import nbformat
from nbformat.v4 import new_code_cell, new_markdown_cell, new_notebook

# Scripts whose docstring shows a --nproc_per_node the launch cell should match.
DEFAULT_NPROC = 2


def split_source(src):
    """Split module source at top-level statement boundaries.

    Uses the AST rather than a regex on `def`, so a decorated function keeps its
    decorators and a nested def does not start a new cell. Comments immediately
    above a statement belong with it.
    """
    tree = ast.parse(src)
    lines = src.splitlines()
    body = [n for n in tree.body if not (isinstance(n, ast.Expr)
            and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str)
            and n.lineno == 1)]
    if not body:
        return []

    starts = []
    for node in body:
        start = min([node.lineno] + [d.lineno for d in getattr(node, "decorator_list", [])])
        # Walk back over comments and blank lines directly above the statement.
        i = start - 2
        while i >= 0 and (lines[i].lstrip().startswith("#") or not lines[i].strip()):
            i -= 1
        starts.append(i + 2)

    cells, buf = [], []
    for idx, node in enumerate(body):
        end = starts[idx + 1] - 1 if idx + 1 < len(starts) else len(lines)
        chunk = "\n".join(lines[starts[idx] - 1:end]).strip("\n")
        if not chunk.strip():
            continue
        # Keep runs of imports and simple assignments together rather than
        # emitting a one-line cell per import.
        if isinstance(node, (ast.Import, ast.ImportFrom, ast.Assign)):
            buf.append(chunk)
            continue
        if buf:
            cells.append("\n".join(buf))
            buf = []
        cells.append(chunk)
    if buf:
        cells.append("\n".join(buf))
    return cells


def nproc_from_docstring(doc):
    """Take the nproc_per_node the script's own docstring recommends."""
    for line in (doc or "").splitlines():
        if "--nproc_per_node=" in line:
            tail = line.split("--nproc_per_node=", 1)[1]
            num = tail.split()[0].strip("\\").strip()
            if num.isdigit():
                return int(num)
    return DEFAULT_NPROC


def convert(py_path):
    src = py_path.read_text()
    doc = ast.get_docstring(ast.parse(src)) or ""
    title = doc.strip().splitlines()[0] if doc.strip() else py_path.stem
    nproc = nproc_from_docstring(doc)

    cells = [
        new_markdown_cell(
            "# %s\n\n%s\n\n---\n\nGenerated from `%s` by `tools/py_to_ipynb.py`. "
            "The `.py` beside this notebook is the entrypoint; this notebook "
            "launches it and shows its source." % (py_path.stem, doc.strip(), py_path.name)
        ),
        new_markdown_cell(
            "## Run\n\n`torchrun` spawns one process per GPU and sets `RANK`, "
            "`LOCAL_RANK` and `WORLD_SIZE` in each. Set `NPROC` to the number of "
            "GPUs on this node — `nvidia-smi --list-gpus | wc -l`."
        ),
        new_code_cell("!nvidia-smi --list-gpus"),
        new_code_cell(
            "NPROC = %d  # GPUs on this node\n"
            "!torchrun --nproc_per_node={NPROC} %s" % (nproc, py_path.name)
        ),
        new_markdown_cell(
            "## Source\n\n**These cells do not run in this kernel.** The script "
            "calls `init_process_group`, which needs the `RANK` / `WORLD_SIZE` "
            "environment that only `torchrun` sets; running a cell below raises "
            "`KeyError: 'RANK'` or hangs in rendezvous. They are here to read and "
            "edit against. Edits do not write back to the `.py` — change the "
            "script and re-run `tools/py_to_ipynb.py`."
        ),
    ]
    cells += [new_code_cell(c) for c in split_source(src)]

    nb = new_notebook(cells=cells, metadata={
        "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
        "language_info": {"name": "python"},
    })
    out = py_path.with_suffix(".ipynb")
    nbformat.write(nb, str(out))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="+", type=pathlib.Path)
    args = ap.parse_args()
    for p in args.paths:
        if p.suffix != ".py":
            print("skipping %s: not a .py" % p, file=sys.stderr)
            continue
        print("wrote %s" % convert(p))


if __name__ == "__main__":
    main()
