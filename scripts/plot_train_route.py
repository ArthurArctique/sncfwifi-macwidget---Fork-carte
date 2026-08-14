#!/usr/bin/env python3
"""Trace le graphe du trajet TGV INOUI et la position GPS actuelle.

Le graphe est un GeoJSON LineString servi par /router/api/train/graph.
La vitesse et la position viennent, elles, de /router/api/train/gps.

Exemples :
    python3 scripts/plot_train_route.py
    python3 scripts/plot_train_route.py --output /tmp/trajet.png
    python3 scripts/plot_train_route.py --graph-file graph.json --gps-file gps.json

Le fond OpenStreetMap est facultatif : si les tuiles externes ne répondent pas,
le script conserve et exporte quand même la géométrie du trajet.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any

import geopandas as gpd
import matplotlib

# Le script exporte un PNG par défaut : éviter que Matplotlib tente d'initialiser
# un backend graphique macOS dans un terminal ou un environnement sans fenêtre.
if "--show" not in sys.argv:
    matplotlib.use("Agg")

import matplotlib.pyplot as plt
import requests
from shapely.geometry import Point, shape
from shapely.ops import unary_union

try:
    import contextily as ctx
except ImportError:  # pragma: no cover - permet le tracé sans fond de carte
    ctx = None


GRAPH_URL = "https://wifi.sncf/router/api/train/graph"
GPS_URL = "https://wifi.sncf/router/api/train/gps"
DETAILS_URL = "https://wifi.sncf/router/api/train/details"
TIMEOUT = 8
ROUTE_COLOR = "#7D206F"
GPS_COLOR = "#111111"
STOP_COLOR = "#E7A400"


def fetch_json(url: str) -> Any:
    response = requests.get(url, timeout=TIMEOUT)
    response.raise_for_status()
    return response.json()


def read_json_file(path: str) -> Any:
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def graph_geometry(payload: dict[str, Any]):
    """Accepte un GeoJSON brut, Feature ou FeatureCollection."""
    payload_type = payload.get("type")

    if payload_type == "Feature":
        return shape(payload["geometry"])

    if payload_type == "FeatureCollection":
        geometries = [
            shape(feature["geometry"])
            for feature in payload.get("features", [])
            if feature.get("geometry")
        ]
        if not geometries:
            raise ValueError("La FeatureCollection ne contient aucune géométrie")
        return unary_union(geometries)

    if "coordinates" in payload:
        return shape(payload)

    raise ValueError("Réponse graph inconnue : géométrie GeoJSON absente")


def number(payload: dict[str, Any], *keys: str) -> float | None:
    for key in keys:
        value = payload.get(key)
        if value is None:
            continue
        try:
            result = float(value)
        except (TypeError, ValueError):
            continue
        if math.isfinite(result):
            return result
    return None


def gps_point(payload: dict[str, Any]) -> tuple[Point, float | None] | None:
    latitude = number(payload, "latitude", "lat")
    longitude = number(payload, "longitude", "lon", "lng")
    if latitude is None or longitude is None:
        return None

    # L'API SNCF renvoie la vitesse en m/s ; conversion pour le sous-titre.
    speed_mps = number(payload, "speed")
    speed_kmh = speed_mps * 3.6 if speed_mps is not None else None
    return Point(longitude, latitude), speed_kmh


def stop_points(details: dict[str, Any]) -> gpd.GeoDataFrame:
    rows: list[dict[str, Any]] = []
    for stop in details.get("stops", []):
        coords = stop.get("coordinates") or {}
        latitude = number(coords, "latitude", "lat")
        longitude = number(coords, "longitude", "lon", "lng")
        if latitude is None or longitude is None:
            continue
        rows.append(
            {
                "label": stop.get("label", ""),
                "code": stop.get("code", ""),
                "geometry": Point(longitude, latitude),
            }
        )
    return gpd.GeoDataFrame(rows, geometry="geometry", crs="EPSG:4326")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graph-url", default=GRAPH_URL, help="URL du graphe GeoJSON")
    parser.add_argument("--gps-url", default=GPS_URL, help="URL de la position GPS")
    parser.add_argument("--details-url", default=DETAILS_URL, help="URL des arrêts")
    parser.add_argument("--graph-file", help="GeoJSON du graphe déjà sauvegardé")
    parser.add_argument("--gps-file", help="JSON GPS déjà sauvegardé")
    parser.add_argument("--details-file", help="JSON des détails déjà sauvegardé")
    parser.add_argument("--output", default="train-route.png", help="PNG de sortie")
    parser.add_argument(
        "--no-basemap",
        action="store_true",
        help="Ne pas tenter de télécharger un fond OpenStreetMap",
    )
    parser.add_argument("--no-gps", action="store_true", help="Ne pas afficher la position GPS")
    parser.add_argument("--no-stops", action="store_true", help="Ne pas afficher les arrêts")
    parser.add_argument("--show", action="store_true", help="Ouvrir la fenêtre matplotlib")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        graph_payload = (
            read_json_file(args.graph_file)
            if args.graph_file
            else fetch_json(args.graph_url)
        )
        geometry = graph_geometry(graph_payload)
    except Exception as exc:
        print(f"Impossible de charger le graphe : {exc}", file=sys.stderr)
        return 1

    route = gpd.GeoDataFrame({"name": ["trajet"]}, geometry=[geometry], crs="EPSG:4326")
    route_mercator = route.to_crs(epsg=3857)

    gps_mercator: gpd.GeoDataFrame | None = None
    speed_kmh: float | None = None
    if not args.no_gps:
        try:
            gps_payload = (
                read_json_file(args.gps_file)
                if args.gps_file
                else fetch_json(args.gps_url)
            )
            current = gps_point(gps_payload)
            if current is not None:
                point, speed_kmh = current
                gps = gpd.GeoDataFrame(
                    {"name": ["position actuelle"]},
                    geometry=[point],
                    crs="EPSG:4326",
                )
                gps_mercator = gps.to_crs(epsg=3857)
        except Exception as exc:
            print(f"Position GPS indisponible : {exc}", file=sys.stderr)

    stops_mercator: gpd.GeoDataFrame | None = None
    if not args.no_stops:
        try:
            details_payload = (
                read_json_file(args.details_file)
                if args.details_file
                else fetch_json(args.details_url)
            )
            stops = stop_points(details_payload)
            if not stops.empty:
                stops_mercator = stops.to_crs(epsg=3857)
        except Exception as exc:
            print(f"Arrêts indisponibles : {exc}", file=sys.stderr)

    fig, ax = plt.subplots(figsize=(12, 8))
    route_mercator.plot(
        ax=ax,
        color=ROUTE_COLOR,
        linewidth=3.0,
        alpha=0.9,
        zorder=3,
        label="Trajet API",
    )

    if stops_mercator is not None:
        stops_mercator.plot(
            ax=ax,
            color=STOP_COLOR,
            edgecolor="white",
            linewidth=0.8,
            markersize=34,
            zorder=4,
            label="Gares",
        )

        # Annoter seulement le départ et l'arrivée pour garder la carte lisible.
        for index in [0, len(stops_mercator) - 1]:
            stop = stops_mercator.iloc[index]
            ax.annotate(
                str(stop["label"]),
                xy=(stop.geometry.x, stop.geometry.y),
                xytext=(6, 6),
                textcoords="offset points",
                fontsize=9,
                fontweight="bold",
                zorder=5,
            )

    if gps_mercator is not None:
        gps_mercator.plot(
            ax=ax,
            color=GPS_COLOR,
            edgecolor="white",
            linewidth=1.5,
            markersize=110,
            zorder=6,
            label="Position GPS",
        )

    if not args.no_basemap and ctx is not None:
        try:
            ctx.add_basemap(
                ax,
                source=ctx.providers.OpenStreetMap.Mapnik,
                attribution_size=7,
                alpha=0.72,
                zorder=1,
            )
        except Exception as exc:
            print(f"Fond de carte indisponible, tracé conservé : {exc}", file=sys.stderr)
    elif not args.no_basemap and ctx is None:
        print("contextily absent : tracé sans fond de carte", file=sys.stderr)

    title = "Carte du trajet TGV INOUI"
    if speed_kmh is not None:
        title += f" · {speed_kmh:.0f} km/h"
    ax.set_title(title, fontsize=16, fontweight="bold", pad=14)
    ax.set_axis_off()
    ax.legend(loc="lower left", frameon=True)
    fig.tight_layout()
    fig.savefig(args.output, dpi=180, bbox_inches="tight")
    print(f"Carte écrite dans {args.output}")

    if args.show:
        plt.show()
    else:
        plt.close(fig)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
