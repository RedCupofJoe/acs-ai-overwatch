"""Allowlisted CSV tools for Compliant Chris (student career success dataset)."""

from __future__ import annotations

import csv
import json
import os
import statistics
from functools import lru_cache
from pathlib import Path
from typing import Any

DEFAULT_CSV = "/opt/acs-agent/data/student_placement.csv"
DEFAULT_SOURCE = (
    "https://huggingface.co/datasets/maxfactor71/student.placement.salary.prediction"
)
MAX_ROWS = 20
_ID_CANDIDATES = ("student_id", "Student_ID", "id")
_PLACEMENT_CANDIDATES = (
    "placed",
    "Placement_Status",
    "PlacementStatus",
    "placement_status",
)
_PLACED_VALUES = {"1", "true", "yes", "placed"}


def _csv_path() -> Path:
    return Path(os.getenv("CAREER_CSV_PATH", DEFAULT_CSV))


@lru_cache(maxsize=1)
def _load() -> tuple[list[str], list[dict[str, str]]]:
    path = _csv_path()
    if not path.is_file():
        raise FileNotFoundError(f"Career CSV not found: {path}")
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        columns = [(name or "").strip() for name in (reader.fieldnames or [])]
        reader.fieldnames = columns
        rows = [{k: (v or "").strip() for k, v in row.items()} for row in reader]
    return columns, rows


def _first_column(columns: list[str], candidates: tuple[str, ...]) -> str | None:
    lower = {column.lower(): column for column in columns}
    for candidate in candidates:
        if candidate.lower() in lower:
            return lower[candidate.lower()]
    return None


def _is_placed(value: str) -> bool:
    return (value or "").strip().lower().replace(" ", "") in _PLACED_VALUES


def _resolve_column(name: str, columns: list[str]) -> str | None:
    want = (name or "").strip().lower().replace(" ", "_")
    if not want:
        return None
    for column in columns:
        if column.lower() == want:
            return column
    for column in columns:
        if want in column.lower() or column.lower() in want:
            return column
    return None


def _to_number(value: str) -> float | None:
    try:
        return float(value.replace(",", ""))
    except (TypeError, ValueError, AttributeError):
        return None


def _apply_filter(
    rows: list[dict[str, str]],
    column: str,
    op: str,
    value: str,
) -> list[dict[str, str]]:
    op = (op or "eq").lower()
    needle = (value or "").strip().lower()
    numeric_needle = _to_number(value)

    matched: list[dict[str, str]] = []
    for row in rows:
        cell = row.get(column, "")
        if op == "contains":
            if needle in cell.lower():
                matched.append(row)
            continue
        if op in {"gte", "lte"} and numeric_needle is not None:
            number = _to_number(cell)
            if number is None:
                continue
            if op == "gte" and number >= numeric_needle:
                matched.append(row)
            elif op == "lte" and number <= numeric_needle:
                matched.append(row)
            continue
        if cell.lower() == needle:
            matched.append(row)
    return matched


def _trim(rows: list[dict[str, str]], limit: int) -> list[dict[str, str]]:
    cap = max(1, min(int(limit or MAX_ROWS), MAX_ROWS))
    return rows[:cap]


def career_dataset_info(_args: dict[str, Any] | None = None) -> str:
    columns, rows = _load()
    placement_col = _first_column(columns, _PLACEMENT_CANDIDATES)
    placed = 0
    if placement_col:
        placed = sum(1 for row in rows if _is_placed(row.get(placement_col, "")))
    payload = {
        "source": os.getenv("CAREER_CSV_SOURCE", DEFAULT_SOURCE),
        "path": str(_csv_path()),
        "rows": len(rows),
        "columns": columns,
        "placement_column": placement_col,
        "placement_counts": {
            "Placed": placed,
            "Not Placed": len(rows) - placed,
        },
    }
    return json.dumps(payload, indent=2)


def query_career_dataset(args: dict[str, Any] | None = None) -> str:
    args = args or {}
    columns, rows = _load()
    operation = str(args.get("operation") or "sample").strip().lower()
    limit = int(args.get("limit") or MAX_ROWS)

    if operation == "schema":
        return career_dataset_info(args)

    if operation == "lookup":
        student_id = str(args.get("student_id") or args.get("value") or "").strip()
        if not student_id:
            return "lookup requires student_id"
        id_col = _first_column(columns, _ID_CANDIDATES)
        if id_col is None:
            return f"No student id column. Known: {', '.join(columns)}"
        hits = [row for row in rows if row.get(id_col, "").lower() == student_id.lower()]
        if not hits:
            return json.dumps({"student_id": student_id, "matches": 0})
        return json.dumps({"matches": len(hits), "rows": hits[:MAX_ROWS]}, indent=2)

    filtered = rows
    column_name = str(args.get("column") or "").strip()
    if column_name:
        resolved = _resolve_column(column_name, columns)
        if resolved is None:
            return f"Unknown column {column_name!r}. Known: {', '.join(columns)}"
        filtered = _apply_filter(
            filtered,
            resolved,
            str(args.get("op") or "eq"),
            str(args.get("value") or ""),
        )

    if operation == "aggregate":
        group_by = _resolve_column(str(args.get("group_by") or ""), columns)
        if group_by is None:
            return "aggregate requires group_by matching a known column"
        metric = str(args.get("metric") or "count").lower()
        metric_column = _resolve_column(str(args.get("metric_column") or ""), columns)
        buckets: dict[str, list[dict[str, str]]] = {}
        for row in filtered:
            buckets.setdefault(row.get(group_by, "") or "(blank)", []).append(row)
        results = []
        for key, group in sorted(buckets.items(), key=lambda item: (-len(item[1]), item[0])):
            entry: dict[str, Any] = {"group": key, "count": len(group)}
            if metric in {"mean", "avg", "average"} and metric_column:
                numbers = [
                    n
                    for n in (_to_number(row.get(metric_column, "")) for row in group)
                    if n is not None
                ]
                if numbers:
                    entry[f"mean_{metric_column}"] = round(statistics.mean(numbers), 2)
            results.append(entry)
        return json.dumps(
            {
                "rows_considered": len(filtered),
                "group_by": group_by,
                "groups": results[:40],
            },
            indent=2,
        )

    sample = _trim(filtered, limit)
    return json.dumps(
        {
            "operation": "sample" if operation != "filter" else "filter",
            "matches": len(filtered),
            "returned": len(sample),
            "rows": sample,
        },
        indent=2,
    )


CAREER_TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "career_dataset_info",
            "description": (
                "Describe the Hugging Face student placement CSV: source, row count, "
                "column names, and overall placement counts."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "query_career_dataset",
            "description": (
                "Query the student placement CSV. Use operation=schema for columns, "
                "lookup for student_id (for example S0), filter/sample for rows, aggregate "
                "for group counts or mean of a numeric column such as salary_lpa or cgpa."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "operation": {
                        "type": "string",
                        "enum": ["schema", "sample", "lookup", "filter", "aggregate"],
                    },
                    "student_id": {"type": "string"},
                    "column": {"type": "string"},
                    "op": {
                        "type": "string",
                        "enum": ["eq", "contains", "gte", "lte"],
                    },
                    "value": {"type": "string"},
                    "group_by": {"type": "string"},
                    "metric": {"type": "string", "enum": ["count", "mean"]},
                    "metric_column": {"type": "string"},
                    "limit": {"type": "integer"},
                },
            },
        },
    },
]

CAREER_HANDLERS = {
    "career_dataset_info": career_dataset_info,
    "query_career_dataset": query_career_dataset,
}


def looks_like_career_question(text: str) -> bool:
    lowered = (text or "").lower()
    markers = (
        "student",
        "career",
        "placement",
        "placed",
        "salary",
        "lpa",
        "cgpa",
        "branch",
        "major",
        "employability",
        "internship",
        "dataset",
        "csv",
        "tier",
        "s0",
        "s1",
    )
    return any(token in lowered for token in markers)
