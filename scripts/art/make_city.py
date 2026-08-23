#!/usr/bin/env python3
"""Generates data/gridcity.cityspec.json — gridlock's ONE authored city.

The city is generated (not hand-typed) so its two mirror symmetries are
structural rather than a thing a reviewer has to check by eye: every scenery
piece's orbit under ix -> 8-ix and iy -> 8-iy is in the list by construction,
which is what `tests/test_city.nim` asserts.

  python3 scripts/art/make_city.py > data/gridcity.cityspec.json
"""
import json
import sys

GRID = 9
SPACING = 112
MARGIN = 64
LANE_CELLS = 14
CELL_PX = 8
BOARD = MARGIN * 2 + SPACING * (GRID - 1)

DEPOTS = [
    {"id": "D0", "node": [1, 1], "alias": "Carbon", "colour": "#e07a3f"},
    {"id": "D1", "node": [7, 1], "alias": "Oxygen", "colour": "#4a8fe7"},
    {"id": "D2", "node": [1, 7], "alias": "Germanium", "colour": "#5fbf6a"},
    {"id": "D3", "node": [7, 7], "alias": "Silicon", "colour": "#f2c14e"},
]

PLAZA_BLOCKS = {(3, 3), (3, 4), (4, 3), (4, 4)}


def scenery():
    pieces = []
    for by in range(GRID - 1):
        for bx in range(GRID - 1):
            if (bx, by) in PLAZA_BLOCKS:
                continue
            # A symmetric art pick: the same block and its whole mirror orbit
            # always draw the same tile.
            ring = min(bx, GRID - 2 - bx) + min(by, GRID - 2 - by)
            art = "block_park" if ring % 2 == 0 else "block_roof"
            pieces.append({
                "kind": "rect",
                "x": MARGIN + SPACING * bx + 28,
                "y": MARGIN + SPACING * by + 28,
                "w": 56,
                "h": 56,
                "art": art,
            })
    for by, bx in sorted(PLAZA_BLOCKS):
        pieces.append({
            "kind": "disc",
            "cx": MARGIN + SPACING * bx + SPACING // 2,
            "cy": MARGIN + SPACING * by + SPACING // 2,
            "r": 30,
            "art": "plaza",
        })
    return pieces


def main():
    spec = {
        "name": "gridcity",
        "grid": [GRID, GRID],
        "node_spacing_px": SPACING,
        "margin_px": MARGIN,
        "lane_cells": LANE_CELLS,
        "cell_px": CELL_PX,
        "lane_offset_px": 6,
        "arterial_cols": [2, 4, 6],
        "arterial_rows": [2, 4, 6],
        "districts": [3, 3],
        "district_names": [["NW", "N", "NE"], ["W", "CENTRE", "E"],
                           ["SW", "S", "SE"]],
        "depots": DEPOTS,
        "signal": {
            "cycle_ticks": 96,
            "green_ns_ticks": 48,
            "offset_rule": "((ix + iy) mod 4) * 24",
        },
        "scenery": scenery(),
    }
    assert BOARD == 1024, BOARD
    json.dump(spec, sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
