"""Real SCL switchyard topology (`Substation`/`VoltageLevel`/`Bay`/
`ConductingEquipment`/`Terminal`/`ConnectivityNode`, plus
`PowerTransformer`/`TransformerWinding`/`Terminal`) -> plain dict/list
structures, consumed by `char_layout.py` to compute a one-line diagram
and by `mapping.py`'s `map_diagram` to assemble the final `diagram`
config block.

Deliberately plain dicts, not `tools/scl-generator`'s dataclasses: this
compiler stays independently usable with no dependency on
`scl-generator` (only the reverse dependency exists today -- see
`scl_writer.py`'s own `from scl.parse import ...`).

Node identity is the Terminal/@connectivityNode FULL PATH, never the bare
Terminal/@cNodeName -- `cNodeName` is only unique *within* the Bay that
defines it (e.g. `switchyard.scd`'s "BusA800" and "BusB800" bays each
define a ConnectivityNode literally named "Bus"), so joining terminals to
nodes by full path (matching a ConnectivityNode's own `@pathName`) is the
only correct way to tell them apart.
"""

from .parse import q, children, child, find_all


def _voltage_kv(vl_elem):
    """<Voltage unit="V" multiplier="k">800</Voltage> -> 800.0. This
    project's SCL only ever uses unit="V" multiplier="k" (kV), so the
    element text is read directly as the kV value -- no generic
    unit-multiplier conversion table, matching this codebase's existing
    "don't build machinery for a case that doesn't occur" norm.
    """
    v_elem = child(vl_elem, "Voltage")
    if v_elem is None or v_elem.text is None:
        return None
    return float(v_elem.text)


def _parse_bay(bay_elem):
    nodes = []
    for cn in children(bay_elem, "ConnectivityNode"):
        nodes.append({
            "name": cn.get("name"),
            "pathName": cn.get("pathName"),
            "desc": cn.get("desc"),
        })

    equipment = []
    for ce in children(bay_elem, "ConductingEquipment"):
        terminals = [t.get("connectivityNode") for t in children(ce, "Terminal")]
        equipment.append({
            "name": ce.get("name"),
            "type": ce.get("type"),
            "terminals": terminals,
        })

    return {
        "name": bay_elem.get("name"),
        "desc": bay_elem.get("desc"),
        # A bus bay is a bare rail: one (or more) ConnectivityNode and no
        # equipment of its own -- every real bus bay in this project's
        # SCL (switchyard.scd's BusA800/BusB800/BusA230/BusB230) has
        # exactly this shape.
        "isBusBay": len(equipment) == 0 and len(nodes) > 0,
        "nodes": nodes,
        "equipment": equipment,
    }


def parse_voltage_levels(root_elem):
    """Substation/VoltageLevel[]/Bay[] -> [{name, kv, bays: [...]}, ...],
    in document order (not sorted by kv -- callers needing highest-kv-on-
    top order sort themselves, same responsibility split as
    tools/scl-generator's onelinediagram.render).
    """
    out = []
    for vl_elem in find_all(root_elem, "VoltageLevel"):
        out.append({
            "name": vl_elem.get("name"),
            "kv": _voltage_kv(vl_elem),
            "bays": [_parse_bay(b) for b in children(vl_elem, "Bay")],
        })
    return out


def _winding_node_path(pt_elem, winding_name):
    for w in children(pt_elem, "TransformerWinding"):
        if (w.get("name") or "").upper() == winding_name:
            t = child(w, "Terminal")
            if t is not None:
                return t.get("connectivityNode")
    return None


def parse_transformers(root_elem):
    """PowerTransformer[] -> [{name, hvNodePath, lvNodePath}, ...].
    Skips (rather than errors on) a PowerTransformer missing a clean
    HV+LV TransformerWinding/Terminal pair -- diagram data is
    best-effort/descriptive, never a reason to fail the whole compile
    (map_diagram's caller treats an empty/partial diagram as absent).
    """
    out = []
    for pt_elem in find_all(root_elem, "PowerTransformer"):
        hv = _winding_node_path(pt_elem, "HV")
        lv = _winding_node_path(pt_elem, "LV")
        if hv and lv:
            out.append({"name": pt_elem.get("name"), "hvNodePath": hv, "lvNodePath": lv})
    return out
