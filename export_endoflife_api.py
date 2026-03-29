#!/usr/bin/env python3
"""
export_endoflife_api_v1.py

But
- Exporter l'ensemble des données de l'API EndOfLife v1 vers un unique CSV,
  en parcourant les produits puis les releases de chaque produit.

Prérequis
- Python 3.8+
- Accès réseau à https://endoflife.date

Usage
- Export par défaut dans le dossier courant:
    python export_endoflife_api.py
- Export vers un chemin précis:
    python export_endoflife_api.py --output "D:/tmp/endoflife_api_v1_full_export.csv"
- Changer l'URL de base de l'API:
    python export_endoflife_api.py --base-url "https://endoflife.date/api/v1"

Format du CSV
- 1 ligne par release de produit.
- Colonnes stables:
  - product
  - release_index
- Les autres colonnes sont construites dynamiquement à partir des clés JSON trouvées
  dans les objets "release" (union de toutes les clés rencontrées).
- Les structures complexes (liste/dict) sont sérialisées en JSON compact.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterable, List


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


def _extract_products_list(products_payload: Any) -> List[Any]:
    if isinstance(products_payload, list):
        return products_payload

    if isinstance(products_payload, dict):
        result = products_payload.get("result")
        if isinstance(result, list):
            return result

    return []


def _ensure_release_list(product_payload: Any) -> List[Dict[str, Any]]:
    if isinstance(product_payload, list):
        return [item for item in product_payload if isinstance(item, dict)]

    if isinstance(product_payload, dict):
        result = product_payload.get("result")
        if result is not None:
            return _ensure_release_list(result)

        candidate_keys = ("releases", "cycles", "data", "result", "items")
        for key in candidate_keys:
            value = product_payload.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]

    return []


def _normalize_cell(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (str, int, float, bool)):
        return str(value)
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _error_details(exc: BaseException) -> str:
    if isinstance(exc, urllib.error.HTTPError):
        return f"HTTP {exc.code} ({exc.reason})"
    if isinstance(exc, urllib.error.URLError):
        return f"Erreur réseau ({exc.reason})"
    return str(exc)


def _log_info(message: str) -> None:
    print(message, flush=True)


def _log_error(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def export_endoflife_csv(base_url: str, output_path: Path) -> int:
    base_url = base_url.rstrip("/")
    products_url = f"{base_url}/products"

    _log_info(f"[INFO] Récupération de la liste des produits: {products_url}")
    raw_products_payload = _http_get_json(products_url)
    products_payload = _extract_products_list(raw_products_payload)
    if not products_payload:
        raise RuntimeError("La réponse de /products ne contient aucune liste de produits exploitable.")
    _log_info(f"[INFO] {len(products_payload)} produits trouvés.")

    rows: List[Dict[str, str]] = []
    dynamic_columns: set[str] = set()
    errors: List[str] = []
    product_count = len(products_payload)

    for product_idx, product_item in enumerate(products_payload, start=1):
        if isinstance(product_item, str):
            product = product_item
        elif isinstance(product_item, dict):
            product = str(
                product_item.get("slug")
                or product_item.get("product")
                or product_item.get("name")
                or ""
            ).strip()
        else:
            continue

        if not product:
            _log_info(f"[{product_idx}/{product_count}] [WARN] Produit ignoré: nom vide.")
            continue

        product_encoded = urllib.parse.quote(product, safe="")
        product_url = f"{base_url}/products/{product_encoded}"
        _log_info(f"[{product_idx}/{product_count}] [INFO] Téléchargement: {product}")
        try:
            product_payload = _http_get_json(product_url)
        except Exception as exc:  # noqa: BLE001
            details = _error_details(exc)
            message = f"[{product_idx}/{product_count}] [ERROR] Échec pour '{product}': {details}"
            _log_error(message)
            errors.append(message)
            continue
        releases = _ensure_release_list(product_payload)
        _log_info(
            f"[{product_idx}/{product_count}] [OK] {product}: "
            f"{len(releases)} release(s) récupérée(s)."
        )

        for index, release in enumerate(releases, start=1):
            row: Dict[str, str] = {
                "product": product,
                "release_index": str(index),
            }
            for key, value in release.items():
                row[key] = _normalize_cell(value)
                dynamic_columns.add(key)
            rows.append(row)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = ["product", "release_index"] + sorted(dynamic_columns)

    with output_path.open("w", encoding="utf-8", newline="") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames, extrasaction="ignore", quoting=csv.QUOTE_ALL)
        writer.writeheader()
        writer.writerows(rows)

    if errors:
        _log_error(
            f"[WARN] Export terminé avec {len(errors)} erreur(s) produit. "
            "Voir les messages [ERROR] ci-dessus."
        )
    else:
        _log_info("[INFO] Export terminé sans erreur produit.")

    return len(rows)


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Export complet EndOfLife API v1 vers CSV")
    parser.add_argument(
        "--base-url",
        default="https://endoflife.date/api/v1",
        help="URL de base de l'API (défaut: %(default)s)",
    )
    parser.add_argument(
        "--output",
        default="endoflife_api_v1_full_export.csv",
        help="Chemin du CSV de sortie (défaut: %(default)s)",
    )
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = _build_arg_parser()
    args = parser.parse_args(argv)

    try:
        row_count = export_endoflife_csv(args.base_url, Path(args.output))
    except urllib.error.HTTPError as exc:
        print(f"Erreur HTTP {exc.code} pendant l'export: {exc}", file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        print(f"Erreur réseau pendant l'export: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"Erreur inattendue: {exc}", file=sys.stderr)
        return 1

    print(f"Export terminé: {args.output} ({row_count} lignes).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

