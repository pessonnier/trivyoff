#!/usr/bin/env python3
"""
export_endoflife_api_v1.py

Exporte le payload `/products/full` de l'API EndOfLife v1 vers :
- un JSON brut,
- un CSV simplifie avec une ligne par release et 21 colonnes fixes.

Colonnes : product, cycle, eol, latest, release_date, latest_release_date, lts,
extendedSupport, support_date, is_supported, eol_date, is_eol, lts_date,
is_lts, discontinued_date, is_discontinued, extended_support_date,
is_extended_support, link, www et discontinued.

Les champs polymorphes eol, lts et discontinued privilegient la date lorsqu'elle
existe, sinon leur valeur booleenne.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple


SCALAR_TYPES = (str, int, float, bool)


def _http_get_json(url: str, timeout: int = 60) -> Any:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "export_endoflife_api_v1.py",
            "Accept": "application/json",
        },
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = response.read().decode("utf-8")
    return json.loads(payload)


def _json_compact(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _normalize_cell(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (str, int, float)):
        return str(value)
    return _json_compact(value)


def _resolve_column_name(
    path: str,
    column_aliases: Dict[str, str],
    used_column_names: set[str],
) -> str:
    existing = column_aliases.get(path)
    if existing is not None:
        return existing

    candidate = path
    if candidate.casefold() in used_column_names:
        suffix = 2
        while f"{path}__dup{suffix}".casefold() in used_column_names:
            suffix += 1
        candidate = f"{path}__dup{suffix}"

    used_column_names.add(candidate.casefold())
    column_aliases[path] = candidate
    return candidate



def _flatten_value(
    prefix: str,
    value: Any,
    row: Dict[str, str],
    dynamic_columns: set[str],
    column_aliases: Dict[str, str],
    used_column_names: set[str],
) -> None:
    column_name = _resolve_column_name(prefix, column_aliases, used_column_names)
    dynamic_columns.add(column_name)

    if value is None or isinstance(value, SCALAR_TYPES):
        row[column_name] = _normalize_cell(value)
        return

    if isinstance(value, dict):
        row[column_name] = _json_compact(value)
        for key, child in value.items():
            _flatten_value(
                f"{prefix}.{key}",
                child,
                row,
                dynamic_columns,
                column_aliases,
                used_column_names,
            )
        return

    if isinstance(value, list):
        row[column_name] = _json_compact(value)
        for index, child in enumerate(value):
            _flatten_value(
                f"{prefix}[{index}]",
                child,
                row,
                dynamic_columns,
                column_aliases,
                used_column_names,
            )
        return

    row[column_name] = _normalize_cell(value)



def _extract_full_payload(raw_payload: Any) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    if isinstance(raw_payload, dict):
        result = raw_payload.get("result")
        if isinstance(result, list):
            products = [item for item in result if isinstance(item, dict)]
            return raw_payload, products

    raise RuntimeError("La reponse de /products/full ne contient pas de liste 'result' exploitable.")



def _log_info(message: str) -> None:
    print(message, flush=True)



def _derive_json_output(csv_output: Path, json_output: str | None) -> Path:
    if json_output:
        return Path(json_output)
    if csv_output.suffix:
        return csv_output.with_suffix(".json")
    return Path(str(csv_output) + ".json")



def export_endoflife_full(base_url: str, csv_output: Path, json_output: Path) -> int:
    base_url = base_url.rstrip("/")
    full_url = f"{base_url}/products/full"

    _log_info(f"[INFO] Recuperation du payload complet: {full_url}")
    raw_payload = _http_get_json(full_url)
    payload, products = _extract_full_payload(raw_payload)
    _log_info(f"[INFO] {len(products)} produit(s) trouve(s) dans /products/full.")

    json_output.parent.mkdir(parents=True, exist_ok=True)
    with json_output.open("w", encoding="utf-8", newline="\n") as json_file:
        json.dump(payload, json_file, ensure_ascii=False, indent=2)
        json_file.write("\n")
    _log_info(f"[INFO] JSON brut ecrit: {json_output}")

    rows: List[Dict[str, str]] = []
    dynamic_columns: set[str] = {"product", "release_index"}
    column_aliases: Dict[str, str] = {}
    used_column_names = {"product", "release_index"}

    payload_metadata = {
        key: value
        for key, value in payload.items()
        if key != "result"
    }

    for product_index, product in enumerate(products, start=1):
        product_name = str(product.get("name") or product.get("label") or "").strip()
        releases = product.get("releases")
        releases_list = releases if isinstance(releases, list) else []

        _log_info(
            f"[{product_index}/{len(products)}] [INFO] Aplatissement de '{product_name or '<sans nom>'}' "
            f"({len(releases_list)} release(s))."
        )

        base_row: Dict[str, str] = {
            "product": product_name,
            "release_index": "",
        }

        for key, value in payload_metadata.items():
            _flatten_value(
                f"payload.{key}",
                value,
                base_row,
                dynamic_columns,
                column_aliases,
                used_column_names,
            )

        for key, value in product.items():
            if key == "releases":
                continue
            _flatten_value(
                f"product.{key}",
                value,
                base_row,
                dynamic_columns,
                column_aliases,
                used_column_names,
            )
        _flatten_value(
            "product.releases_count",
            len(releases_list),
            base_row,
            dynamic_columns,
            column_aliases,
            used_column_names,
        )

        if releases_list:
            for release_index, release in enumerate(releases_list, start=1):
                row = dict(base_row)
                row["release_index"] = str(release_index)
                _flatten_value(
                    "release",
                    release,
                    row,
                    dynamic_columns,
                    column_aliases,
                    used_column_names,
                )
                rows.append(row)
        else:
            rows.append(dict(base_row))

    def lifecycle_value(date_value: Any, state_value: Any) -> str:
        normalized_date = _normalize_cell(date_value)
        return normalized_date if normalized_date else _normalize_cell(state_value)

    def availability_value(end_state_value: Any) -> str:
        if isinstance(end_state_value, bool):
            has_ended = end_state_value
        elif isinstance(end_state_value, str) and end_state_value.casefold() in {"true", "false"}:
            has_ended = end_state_value.casefold() == "true"
        else:
            return ""
        return "false" if has_ended else "true"

    simple_rows: List[Dict[str, str]] = []
    for row in rows:
        eol_date = row.get("release.eolFrom")
        is_eol = row.get("release.isEol")
        lts_date = row.get("release.ltsFrom")
        is_lts = row.get("release.isLts")
        support_date = row.get("release.eoasFrom")
        is_end_of_active_support = row.get("release.isEoas")
        extended_support_date = row.get("release.eoesFrom")
        is_end_of_extended_support = row.get("release.isEoes")
        discontinued_date = row.get("release.discontinuedFrom")
        is_discontinued = row.get("release.isDiscontinued")

        simple_rows.append(
            {
                "product": _normalize_cell(row.get("product")),
                "cycle": _normalize_cell(row.get("release.name")),
                "eol": lifecycle_value(eol_date, is_eol),
                "latest": _normalize_cell(row.get("release.latest.name")),
                "release_date": _normalize_cell(row.get("release.releaseDate")),
                "latest_release_date": _normalize_cell(row.get("release.latest.date")),
                "lts": lifecycle_value(lts_date, is_lts),
                "extendedSupport": (
                    _normalize_cell(extended_support_date)
                    if extended_support_date is not None
                    else availability_value(is_end_of_extended_support)
                ),
                "support_date": _normalize_cell(support_date),
                "is_supported": availability_value(is_end_of_active_support),
                "eol_date": _normalize_cell(eol_date),
                "is_eol": _normalize_cell(is_eol),
                "lts_date": _normalize_cell(lts_date),
                "is_lts": _normalize_cell(is_lts),
                "discontinued_date": _normalize_cell(discontinued_date),
                "is_discontinued": _normalize_cell(is_discontinued),
                "extended_support_date": _normalize_cell(extended_support_date),
                "is_extended_support": availability_value(is_end_of_extended_support),
                "link": _normalize_cell(row.get("release.latest.link")),
                "www": _normalize_cell(row.get("product.links.html")),
                "discontinued": lifecycle_value(discontinued_date, is_discontinued),
            }
        )
    rows = simple_rows

    csv_output.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "product",
        "cycle",
        "eol",
        "latest",
        "release_date",
        "latest_release_date",
        "lts",
        "extendedSupport",
        "support_date",
        "is_supported",
        "eol_date",
        "is_eol",
        "lts_date",
        "is_lts",
        "discontinued_date",
        "is_discontinued",
        "extended_support_date",
        "is_extended_support",
        "link",
        "www",
        "discontinued",
    ]

    with csv_output.open("w", encoding="utf-8", newline="") as csv_file:
        writer = csv.DictWriter(
            csv_file,
            fieldnames=fieldnames,
            extrasaction="ignore",
            quoting=csv.QUOTE_ALL,
        )
        writer.writeheader()
        writer.writerows(rows)

    _log_info(f"[INFO] CSV simplifie ecrit: {csv_output}")
    return len(rows)



def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Export complet EndOfLife API v1 (/products/full) vers JSON + CSV")
    parser.add_argument(
        "--base-url",
        default="https://endoflife.date/api/v1",
        help="URL de base de l'API (defaut: %(default)s)",
    )
    parser.add_argument(
        "--output",
        "--csv-output",
        dest="csv_output",
        default="endoflife_api_v1_full_export.csv",
        help="Chemin du CSV de sortie (defaut: %(default)s)",
    )
    parser.add_argument(
        "--json-output",
        default="",
        help="Chemin du JSON brut de sortie (defaut: meme nom que le CSV avec extension .json)",
    )
    return parser



def main(argv: Iterable[str] | None = None) -> int:
    parser = _build_arg_parser()
    args = parser.parse_args(argv)

    csv_output = Path(args.csv_output)
    json_output = _derive_json_output(csv_output, args.json_output or None)

    try:
        row_count = export_endoflife_full(args.base_url, csv_output, json_output)
    except urllib.error.HTTPError as exc:
        print(f"Erreur HTTP {exc.code} pendant l'export: {exc}", file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        print(f"Erreur reseau pendant l'export: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"Erreur inattendue: {exc}", file=sys.stderr)
        return 1

    print(f"Export termine: {csv_output} ({row_count} lignes). JSON: {json_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())