"""JSON (from the GUI's browser form) -> Station, without ever touching
`input()`/`print()` -- the non-interactive counterpart to
`generator/wizard.py`'s Q&A orchestration. Calls the exact same pure
builder functions wizard.py calls (`LAYOUT_BUILDERS[...]`,
`transformer_lv.build_transformer`, the topology dataclasses), so a GUI-
built Station numbers breakers/transformers identically to what the CLI
wizard would produce for the same answers in the same order.

Deliberately tolerant of "still being typed" input, since the live
preview endpoint calls this on every keystroke: a blank required-name
field (voltage level name, tap name, transformer name, LV output name)
means "this item isn't finished yet" and is silently skipped, not an
error -- mirrors generator/wizard.py's own "blank name ends this step"
convention (see wizard._collect_taps's "blank to finish this voltage
level"). A *non-blank but invalid* value (bad tap count, bad identifier,
LV kV >= HV kV, ...) is a real error, isolated to just the one voltage
level or transformer it came from -- see station_from_json's docstring.
"""

import dataclasses

from .. import naming
from ..topology import (
    Tap, TapKind, LayoutKind, Station, EQUIP_CBR, EQUIP_DIS,
    ProtectionDefaults, NetworkDefaults, IedSettingsDefaults, ScadaDefaults,
)
from ..layouts import LAYOUT_BUILDERS, transformer_lv


def _dataclass_from_dict(cls, data):
    """Builds `cls(**kwargs)` using only the fields `data` actually
    provides (missing/None/"" -> that field's own dataclass default,
    introspected via `dataclasses.fields` rather than hand-duplicating
    each default a second time here).
    """
    data = data or {}
    kwargs = {}
    for f in dataclasses.fields(cls):
        v = data.get(f.name)
        if v is not None and v != "":
            kwargs[f.name] = v
    return cls(**kwargs)


def _parse_float(raw, default=0.0):
    if raw is None or raw == "":
        return default
    return float(raw)


def _build_voltage_level(vl_spec, breaker_start_index, errors):
    """Returns (VoltageLevelBuild, [Transformer]) on success, or
    (None, []) if `vl_spec` isn't finished yet (blank name) or its
    layout couldn't be built at all (a real error, recorded into
    `errors["voltage_levels"][cid]`). A bad *transformer* tap nested
    inside an otherwise-valid voltage level does NOT abort the voltage
    level -- only that one transformer is skipped, recorded into
    `errors["transformers"][tap_cid]`.
    """
    cid = vl_spec.get("_cid") or ""
    vl_name = (vl_spec.get("vl_name") or "").strip()
    if not vl_name:
        return None, []

    try:
        naming.validate_identifier(vl_name)
        kv = _parse_float(vl_spec.get("kv"))
        layout_kind = LayoutKind(vl_spec.get("layout_kind"))

        taps = []
        tap_specs = []  # parallel list: (raw tap_spec dict, Tap) for the transformer pass below
        for tap_spec in vl_spec.get("taps") or []:
            tap_name = (tap_spec.get("name") or "").strip()
            if not tap_name:
                continue  # this tap row isn't finished yet -- skip silently, not an error
            naming.validate_identifier(tap_name)
            kind = TapKind(tap_spec.get("kind"))
            tap = Tap(tap_name, kind)
            taps.append(tap)
            tap_specs.append((tap_spec, tap))

        vl = LAYOUT_BUILDERS[layout_kind](vl_name, kv, taps, start_index=breaker_start_index)
    except ValueError as e:
        errors["voltage_levels"][cid] = str(e)
        return None, []

    transformers = []
    for tap_spec, tap in tap_specs:
        if tap.kind != TapKind.TRANSFORMER:
            continue
        tap_cid = tap_spec.get("_cid") or ""
        xfmr = _build_transformer(vl, tap, tap_spec.get("transformer") or {}, tap_cid, errors)
        if xfmr is not None:
            transformers.append(xfmr)

    return vl, transformers


def _build_transformer(hv_vl, hv_tap, xfmr_spec, tap_cid, errors):
    """Returns a Transformer, or None if `xfmr_spec` isn't finished yet
    (blank name) or is invalid (recorded into
    `errors["transformers"][tap_cid]` -- keyed by the *tap's* _cid, since
    that's the stable id the client's nested transformer sub-form is
    painted under).
    """
    xfmr_name = (xfmr_spec.get("name") or "").strip()
    if not xfmr_name:
        return None

    try:
        naming.validate_ied_name(xfmr_name)
        lv_kv = _parse_float(xfmr_spec.get("lv_kv"))

        lv_outputs = []
        for out_spec in xfmr_spec.get("lv_outputs") or []:
            out_name = (out_spec.get("name") or "").strip()
            if not out_name:
                continue
            naming.validate_identifier(out_name)
            lv_outputs.append((out_name, TapKind(out_spec.get("kind"))))
        if not lv_outputs:
            raise ValueError("transformer %r needs at least 1 LV output" % xfmr_name)

        hv_tap_node = hv_vl.tap_node_for(hv_tap)
        return transformer_lv.build_transformer(xfmr_name, hv_vl, hv_tap_node, lv_kv, lv_outputs)
    except ValueError as e:
        errors["transformers"][tap_cid] = str(e)
        return None


def station_from_json(data):
    """Returns (Station, errors). `errors` is always
    `{"voltage_levels": {cid: msg}, "transformers": {cid: msg}}`, plus an
    optional top-level `"name"` key -- never raises, so this is safe to
    call on every keystroke from the live-preview endpoint. The returned
    Station always includes every voltage level/transformer that built
    successfully, even if others failed -- one bad card never blanks the
    whole preview.
    """
    data = data or {}
    errors = {"voltage_levels": {}, "transformers": {}}

    raw_name = (data.get("name") or "").strip()
    if raw_name:
        try:
            naming.validate_identifier(raw_name)
        except naming.NameError_ as e:
            errors["name"] = str(e)
    station_name = raw_name or "Station"

    voltage_levels = []
    transformers = []
    breaker_index = 1
    for vl_spec in data.get("voltage_levels") or []:
        vl, vl_transformers = _build_voltage_level(vl_spec, breaker_index, errors)
        if vl is None:
            continue
        voltage_levels.append(vl)
        transformers.extend(vl_transformers)
        breaker_index += len(vl.breakers)

    station = Station(
        name=station_name,
        voltage_levels=voltage_levels,
        transformers=transformers,
        protection=_dataclass_from_dict(ProtectionDefaults, data.get("protection")),
        network=_dataclass_from_dict(NetworkDefaults, data.get("network")),
        ied_settings=_dataclass_from_dict(IedSettingsDefaults, data.get("ied_settings")),
        scada=_dataclass_from_dict(ScadaDefaults, data.get("scada")),
    )
    return station, errors


def _n_cbr(vl):
    return sum(1 for b in vl.breakers if b.equip_type == EQUIP_CBR)


def _n_dis(vl):
    return sum(1 for b in vl.breakers if b.equip_type == EQUIP_DIS)


def summary(station):
    """Live-updating counts for the GUI's sidebar -- the same numbers
    generator.wizard._print_summary prints at the end of a CLI session,
    just as a JSON-able dict instead of stdout lines.
    """
    vls = [
        {
            "vl_name": vl.vl_name, "kv": vl.kv, "layout_kind": vl.layout_kind.value,
            "taps": len(vl.taps), "breakers": _n_cbr(vl), "disconnects": _n_dis(vl),
        }
        for vl in station.voltage_levels
    ]
    xfmrs = [
        {
            "name": x.name, "hv_vl": x.hv_vl.vl_name, "hv_kv": x.hv_vl.kv,
            "lv_kv": x.lv_vl.kv, "lv_outputs": len(x.lv_vl.taps),
        }
        for x in station.transformers
    ]
    return {
        "name": station.name,
        "voltage_levels": vls,
        "transformers": xfmrs,
        "total_breakers": sum(v["breakers"] for v in vls),
        "total_disconnects": sum(v["disconnects"] for v in vls),
        "scada_ied_name": station.scada.ied_name,
    }
