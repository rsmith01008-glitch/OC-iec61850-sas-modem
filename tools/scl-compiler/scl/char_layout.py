"""Character-cell one-line-diagram layout math: turns `topology.py`'s
parsed VoltageLevel/Bay/ConductingEquipment/ConnectivityNode structures
into absolute (small-integer) row/column positions for
`mapping.py`'s `map_diagram`.

Deliberately independent of `tools/scl-generator/generator/diagram/
layout_geometry.py`, not a shared/parameterized reuse of it, even though
the two are algorithmically similar (voltage-level strips stacked
highest-kV-on-top, breakers spaced along a diameter, tap columns):
  1. Different input shape -- layout_geometry.py consumes
     tools/scl-generator's authoring-time dataclasses (Station,
     VoltageLevelBuild, Breaker, ...); this module consumes plain dicts
     parsed straight out of real SCL (topology.py), which never passes
     through tools/scl-generator at all for a hand-authored .scd.
  2. The existing one-way dependency (scl-generator imports FROM
     scl-compiler, via scl_writer.py's `from scl.parse import ...`) must
     not invert, and scl-compiler's own README documents it as
     independently pip-installable with no scl-generator dependency.
  3. Genuinely different unit scale (SVG pixels vs. character cells), not
     just a constant swap -- a shared parameterized function would need a
     unit-scale argument threaded through every call site plus different
     rounding/min-spacing rules. Small deliberate duplication of ~10
     small functions beats that complexity here.

Also deliberately does NOT rely on any stored "layout kind" (real SCL has
no such attribute -- tools/scl-generator's LayoutKind is an authoring-time
Python concept, never written into the SCL itself, only descriptive Bay
`@desc` text). Instead each equipment-bearing Bay's shape is inferred
from its own ConductingEquipment/Terminal graph: a "chain" (a
breaker-and-half-style diameter: an ordered path of equipment between two
bus attachment points) or a "star" (a single-bus-style bay: each piece of
equipment its own bus-to-tap spoke). Anything that resolves to neither
falls back to a simple left-to-right row so nothing crashes or silently
mis-wires a connection -- see `build_diagram`'s "fallback" branch.
"""

ROW_UNIT = 2           # vertical spacing between successive chain/spoke elements
STRIP_GAP_ROWS = 2      # blank rows between stacked voltage-level strips
LEFT_MARGIN_COLS = 2
DIAMETER_PITCH_COLS = 12  # spacing between adjacent chain-shaped bays (diameters)
TAP_PITCH_COLS = 10       # spacing between adjacent star-shaped bays' spokes
BUS_MARGIN_COLS = 2        # bus line extends this far past its outermost attached column


def _bus_node_paths(voltage_levels):
    """The set of every bus-bay ConnectivityNode's pathName, across every
    voltage level -- used only as a fast "is this terminal bus-attached?"
    membership test. Each VL's bus bays' drawn row is computed separately
    in `build_diagram`, in document order (first declared = topmost,
    matching switchyard.scd's own BusA-before-BusB declaration order).
    """
    out = set()
    for vl in voltage_levels:
        for bay in vl["bays"]:
            if bay["isBusBay"]:
                for node in bay["nodes"]:
                    out.add(node["pathName"])
    return out


def _walk_chain(bay, bus_paths):
    """Attempts to order one equipment-bearing Bay's ConductingEquipment
    as a single chain between two bus-attached endpoints (a
    breaker-and-half-style diameter). Returns an explicit ordered list of
    `("bus", nodePath)` / `("equip", eqDict)` / `("node", nodePath)`
    steps, e.g. for a 3-breaker diameter:
    `[("bus",BusA), ("equip",CB1), ("node",N1), ("equip",CB2),
      ("node",N2), ("equip",CB3), ("bus",BusB)]`
    on success (every equipment in the bay consumed, walk ends on a
    second bus-attached node), or None if the bay's graph doesn't form a
    single simple chain.
    """
    equipment = bay["equipment"]
    if not equipment:
        return None

    touching = {}  # nodePath -> [equipIndex, ...]
    for i, eq in enumerate(equipment):
        for t in eq["terminals"]:
            touching.setdefault(t, []).append(i)

    start = None
    for eq in equipment:
        for t in eq["terminals"]:
            if t in bus_paths:
                start = t
                break
        if start:
            break
    if start is None:
        return None

    steps = [("bus", start)]
    used = set()
    current = start
    while True:
        candidates = [i for i in touching.get(current, []) if i not in used]
        if not candidates:
            break
        i = candidates[0]
        eq = equipment[i]
        used.add(i)
        other = eq["terminals"][1] if eq["terminals"][0] == current else eq["terminals"][0]
        steps.append(("equip", eq))
        current = other
        if current in bus_paths:
            break
        steps.append(("node", current))

    if len(used) != len(equipment):
        return None
    if current not in bus_paths:
        return None
    steps.append(("bus", current))
    return steps


def _walk_star(bay, bus_paths):
    """Attempts to interpret one equipment-bearing Bay as a star (a
    single-bus-style bay: every piece of equipment has exactly one
    bus-attached terminal and one tap-attached terminal, all sharing the
    SAME bus node). Returns [(busPath, [(equip, tapPath), ...])] on
    success, or None.
    """
    equipment = bay["equipment"]
    if not equipment:
        return None
    bus_path = None
    spokes = []
    for eq in equipment:
        terms = eq["terminals"]
        if len(terms) != 2:
            return None
        bus_ends = [t for t in terms if t in bus_paths]
        tap_ends = [t for t in terms if t not in bus_paths]
        if len(bus_ends) != 1 or len(tap_ends) != 1:
            return None
        if bus_path is None:
            bus_path = bus_ends[0]
        elif bus_path != bus_ends[0]:
            return None
        spokes.append((eq, tap_ends[0]))
    return bus_path, spokes


def _tap_kind(node_path, xfmr_node_paths, tap_kinds):
    if node_path in xfmr_node_paths:
        return "transformer"
    return tap_kinds.get(node_path, "unknown")


def build_diagram(voltage_levels, transformers, tap_kinds):
    """voltage_levels/transformers: topology.py's parsed shape.
    tap_kinds: {connectivityNodePath -> "line"|"feeder"} from the
    optional oc:tap Private extension (private_ext.connectivity_node_private).
    Returns the compiled `diagram` dict (see mapping.py's map_diagram),
    or an empty dict if there is no real topology to lay out (e.g. a
    minimal/legacy SCD with no Substation/VoltageLevel at all).
    """
    if not voltage_levels:
        return {}

    xfmr_node_paths = set()
    for x in transformers:
        xfmr_node_paths.add(x["hvNodePath"])
        xfmr_node_paths.add(x["lvNodePath"])

    bus_paths = _bus_node_paths(voltage_levels)

    # Highest kV on top, matching tools/scl-generator's onelinediagram.py
    # convention -- ties broken by document order for determinism.
    ordered_vls = sorted(
        enumerate(voltage_levels), key=lambda pair: (-(pair[1]["kv"] or 0), pair[0])
    )

    buses = []
    breakers = []
    disconnects = []
    taps = []
    segments = []
    node_xy = {}  # connectivityNode path -> (x, y), for transformerLinks resolution
    bus_x_extent = {}  # bus node path -> [minX, maxX]

    strip_y = 0
    for _orig_index, vl in ordered_vls:
        bus_bays = [b for b in vl["bays"] if b["isBusBay"]]
        equip_bays = [b for b in vl["bays"] if not b["isBusBay"] and b["equipment"]]

        # First pass: lay out every equipment bay's columns, tracking the
        # tallest chain (in step count -- "bus","equip","node",...,"bus")
        # so every bus row in this strip lines up consistently regardless
        # of which diameter/bay is tallest. A star bay always spans
        # exactly 3 positions (bus/CB/tap), same as the shortest possible
        # chain (bus/equip/bus), so 3 is the floor.
        max_chain_len = 3
        bay_plans = []
        for bay in equip_bays:
            chain = _walk_chain(bay, bus_paths)
            if chain is not None:
                bay_plans.append(("chain", bay, chain))
                max_chain_len = max(max_chain_len, len(chain))
                continue
            star = _walk_star(bay, bus_paths)
            if star is not None:
                bay_plans.append(("star", bay, star))
                continue
            bay_plans.append(("fallback", bay, None))

        col = LEFT_MARGIN_COLS
        for kind, bay, plan in bay_plans:
            if kind == "chain":
                x = col
                y = strip_y
                prev_y = None
                for step_kind, value in plan:
                    if step_kind == "bus":
                        node_xy[value] = (x, y)
                        ext = bus_x_extent.setdefault(value, [x, x])
                        ext[0] = min(ext[0], x)
                        ext[1] = max(ext[1], x)
                    elif step_kind == "equip":
                        eq = value
                        if eq["type"] == "CBR":
                            breakers.append({
                                "id": eq["name"], "label": eq["name"], "x": x, "y": y,
                                "statusFullRef": "%s/LD0/XCBR1.Pos" % eq["name"],
                                "controlFullRef": "%s/LD0/XCBR1.PosCtl" % eq["name"],
                                "measFullRefBase": "%s/LD0/MMXU1" % eq["name"],
                            })
                        else:
                            disconnects.append({"id": eq["name"], "x": x, "y": y, "orientation": "v"})
                    else:  # "node" -- an internal tap between two equipment
                        node_xy[value] = (x, y)
                        taps.append({
                            "id": value,
                            "kind": _tap_kind(value, xfmr_node_paths, tap_kinds),
                            "label": value.rsplit("/", 1)[-1],
                            "x": x, "y": y,
                        })
                    if prev_y is not None:
                        segments.append({"x1": x, "y1": prev_y, "x2": x, "y2": y})
                    prev_y = y
                    y += ROW_UNIT
                col += DIAMETER_PITCH_COLS

            elif kind == "star":
                bus_path, spokes = plan
                by = strip_y
                bx = None
                for eq, tap_path in spokes:
                    x = col
                    if bx is None:
                        bx = x
                    ext = bus_x_extent.setdefault(bus_path, [x, x])
                    ext[0] = min(ext[0], x)
                    ext[1] = max(ext[1], x)
                    cb_y = by + ROW_UNIT
                    tap_y = by + 2 * ROW_UNIT
                    segments.append({"x1": x, "y1": by, "x2": x, "y2": cb_y})
                    if eq["type"] == "CBR":
                        breakers.append({
                            "id": eq["name"], "label": eq["name"], "x": x, "y": cb_y,
                            "statusFullRef": "%s/LD0/XCBR1.Pos" % eq["name"],
                            "controlFullRef": "%s/LD0/XCBR1.PosCtl" % eq["name"],
                            "measFullRefBase": "%s/LD0/MMXU1" % eq["name"],
                        })
                    else:
                        disconnects.append({"id": eq["name"], "x": x, "y": cb_y, "orientation": "v"})
                    segments.append({"x1": x, "y1": cb_y, "x2": x, "y2": tap_y})
                    node_xy[tap_path] = (x, tap_y)
                    taps.append({
                        "id": tap_path,
                        "kind": _tap_kind(tap_path, xfmr_node_paths, tap_kinds),
                        "label": tap_path.rsplit("/", 1)[-1],
                        "x": x, "y": tap_y,
                    })
                    col += TAP_PITCH_COLS
                node_xy[bus_path] = (bx if bx is not None else col, by)

            else:
                # Fallback: a bay whose equipment graph isn't a clean
                # chain or star (not exercised by switchyard.scd; kept
                # simple and non-crashing rather than guessing
                # connectivity). Each equipment gets its own column with
                # no inferred connectivity/segments.
                for eq in bay["equipment"]:
                    x = col
                    y = strip_y + ROW_UNIT
                    if eq["type"] == "CBR":
                        breakers.append({
                            "id": eq["name"], "label": eq["name"], "x": x, "y": y,
                            "statusFullRef": "%s/LD0/XCBR1.Pos" % eq["name"],
                            "controlFullRef": "%s/LD0/XCBR1.PosCtl" % eq["name"],
                            "measFullRefBase": "%s/LD0/MMXU1" % eq["name"],
                        })
                    else:
                        disconnects.append({"id": eq["name"], "x": x, "y": y, "orientation": "v"})
                    col += TAP_PITCH_COLS

        # Second pass: emit one `buses[]` entry per bus bay at this
        # strip's rank row, spanning every column that attached to it.
        for rank, bay in enumerate(bus_bays):
            for node in bay["nodes"]:
                ext = bus_x_extent.get(node["pathName"])
                if ext is None:
                    continue
                y = strip_y + rank * (max_chain_len - 1) * ROW_UNIT
                # node["desc"] (e.g. switchyard.scd's "800kV Bus A") is
                # already the intended human label when present -- only
                # fall back to synthesizing one from kv+name when a
                # station's SCL doesn't bother with bus descriptions.
                label = node["desc"] or ("%s%s" % (("%gkV " % vl["kv"]) if vl["kv"] else "", node["name"]))
                buses.append({
                    "id": node["pathName"],
                    "label": label,
                    "x1": ext[0] - BUS_MARGIN_COLS, "y1": y,
                    "x2": ext[1] + BUS_MARGIN_COLS, "y2": y,
                    "orientation": "h",
                })

        strip_height = (max_chain_len - 1) * ROW_UNIT
        strip_y += strip_height + STRIP_GAP_ROWS

    transformer_links = []
    for x in transformers:
        if x["hvNodePath"] in node_xy and x["lvNodePath"] in node_xy:
            transformer_links.append({
                "name": x["name"], "hvTapId": x["hvNodePath"], "lvTapId": x["lvNodePath"],
            })

    if not breakers and not disconnects and not buses:
        return {}

    all_x = [b["x1"] for b in buses] + [b["x2"] for b in buses] + \
        [b["x"] for b in breakers] + [d["x"] for d in disconnects] + [t["x"] for t in taps]
    all_y = [b["y1"] for b in buses] + [b["y2"] for b in buses] + \
        [b["y"] for b in breakers] + [d["y"] for d in disconnects] + [t["y"] for t in taps]
    width = (max(all_x) + LEFT_MARGIN_COLS) if all_x else 0
    height = (max(all_y) + ROW_UNIT) if all_y else 0

    return {
        "width": width, "height": height,
        "buses": buses, "breakers": breakers, "disconnects": disconnects,
        "taps": taps, "segments": segments, "transformerLinks": transformer_links,
    }
