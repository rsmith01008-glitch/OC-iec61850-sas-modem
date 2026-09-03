"""Station -> real IEC 61850-6 SCL `.scd` document (lxml ElementTree).

Every element/attribute name and ordering rule here was cross-checked
against the vendored SCL2007B4 XSD during this tool's design (see
tools/scl-generator's plan / tools/scl-compiler/README.md), not guessed:
in particular, `Private` (when present) must always be emitted as the
FIRST child of `LN0`, `LN`, `DOI`, `SubNetwork`, `ConnectedAP`, `GSE`
before any other child -- `xs:extension`'s base-type sequence always
comes before the derived type's own. Getting this wrong doesn't fail
loudly at write time (lxml doesn't validate on construction); it fails
later at `--validate-xsd` with a schema line number, which is why
tests/test_scl_writer.py runs every fixture through the real
`scl.validate.validate_xsd` and `scl_compile.compile_scd`, not just a
well-formedness check.

Imports SCL_NS/OC_NS/OC_PRIVATE_TYPE/q/oc_q from tools/scl-compiler/scl/
parse.py rather than redefining them -- one source of truth for the
namespace constants both tools share.
"""

import sys
from pathlib import Path
from typing import Dict, List

from lxml import etree

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scl-compiler"))
from scl.parse import SCL_NS, OC_NS, OC_PRIVATE_TYPE, q, oc_q  # noqa: E402

from .topology import (  # noqa: E402
    Station, VoltageLevelBuild, Transformer, Node, BusNode, TapNode,
    Breaker, BayGroup, EQUIP_CBR,
)
from .derive import remote_trips_for, illustrative_interlocks  # noqa: E402
from . import naming  # noqa: E402

# Per-phase current (WYE) and phase-to-phase voltage (DEL) DO names -- see
# _build_data_type_templates's comment for why these replace the single
# "Amp"/"Vol" DO real hardware never actually has (each is one physical
# Create:EE meter block bridged through its own OpenComputers Adapter,
# and a 3-phase circuit needs 3 of each kind, not 1).
AMP_PHASES = ("AmpA", "AmpB", "AmpC")
VOL_PHASES = ("VolAB", "VolBC", "VolCA")


def _el(parent, tag, attrib=None, text=None):
    """Appends a real-SCL-namespaced child. `attrib` values are
    stringified (SCL is all-string XML attributes; callers pass Python
    bools/numbers freely).
    """
    e = etree.SubElement(parent, q(tag))
    if attrib:
        for k, v in attrib.items():
            if v is not None:
                e.set(k, _attr_str(v))
    if text is not None:
        e.text = text
    return e


def _oc_el(parent, tag, attrib=None):
    e = etree.SubElement(parent, oc_q(tag))
    if attrib:
        for k, v in attrib.items():
            if v is not None:
                e.set(k, _attr_str(v))
    return e


def _attr_str(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def _private(parent, type_=OC_PRIVATE_TYPE):
    """Creates `<Private type="...">` as the parent's first child --
    caller MUST call this before appending any other child to `parent`,
    since it always appends (there is nothing to reorder after the
    fact). Returns the Private element to append oc:* children to.
    """
    return etree.SubElement(parent, q("Private"), type=type_)


# --------------------------------------------------------------------
# DataTypeTemplates -- identical for every generated file, emitted once
# regardless of breaker/transformer count (mirrors switchyard.scd: every
# breaker IED reuses the same XCBR_Basic/MMXU_Basic LNodeTypes).
# --------------------------------------------------------------------

def _build_data_type_templates(root):
    dtt = _el(root, "DataTypeTemplates")

    ln0_basic = _el(dtt, "LNodeType", {"id": "LN0_Basic", "lnClass": "LLN0"})
    _el(ln0_basic, "DO", {"name": "Mod", "type": "ENC_Basic"})

    xcbr_basic = _el(dtt, "LNodeType", {"id": "XCBR_Basic", "lnClass": "XCBR"})
    _el(xcbr_basic, "DO", {"name": "Pos", "type": "DPS_Basic"})
    _el(xcbr_basic, "DO", {"name": "PosCtl", "type": "DPC_Basic"})

    mmxu_basic = _el(dtt, "LNodeType", {"id": "MMXU_Basic", "lnClass": "MMXU"})
    # Real hardware exposes one Create:EE meter block per sensing point --
    # a 3-phase circuit needs 3 independent ammeters (per-phase current)
    # and 3 independent voltmeters (per-phase-pair voltage), never one
    # meter standing in for all three. AMP_PHASES/VOL_PHASES below are the
    # single source of truth for these 6 DO names; a breaker IED
    # instantiates all 6 (see _build_breaker_ied), a transformer's HV/LV
    # CT-only MMXU instantiates only the 3 AMP_PHASES ones (see
    # _build_transformer_ied) -- SCL allows an LN to leave any DO in its
    # LNodeType un-DOI'd, so sharing one LNodeType for both is valid.
    for do_name in AMP_PHASES + VOL_PHASES:
        _el(mmxu_basic, "DO", {"name": do_name, "type": "MV_Basic"})

    rdre_basic = _el(dtt, "LNodeType", {"id": "RDRE_Basic", "lnClass": "RDRE"})
    _el(rdre_basic, "DO", {"name": "RcdMade", "type": "ACT_Basic"})

    dps = _el(dtt, "DOType", {"id": "DPS_Basic", "cdc": "DPS"})
    _el(dps, "DA", {"name": "stVal", "fc": "ST", "bType": "Dbpos"})

    dpc = _el(dtt, "DOType", {"id": "DPC_Basic", "cdc": "DPC"})
    _el(dpc, "DA", {"name": "ctlVal", "fc": "CO", "bType": "Dbpos"})

    mv = _el(dtt, "DOType", {"id": "MV_Basic", "cdc": "MV"})
    _el(mv, "DA", {"name": "mag", "fc": "MX", "bType": "FLOAT32"})

    act = _el(dtt, "DOType", {"id": "ACT_Basic", "cdc": "ACT"})
    _el(act, "DA", {"name": "general", "fc": "ST", "bType": "BOOLEAN"})

    enc = _el(dtt, "DOType", {"id": "ENC_Basic", "cdc": "ENC"})
    _el(enc, "DA", {"name": "stVal", "fc": "ST", "bType": "Enum", "type": "ModeKind"})

    enum_type = _el(dtt, "EnumType", {"id": "ModeKind"})
    _el(enum_type, "EnumVal", {"ord": 1}, text="on")


# --------------------------------------------------------------------
# Substation / topology (descriptive-only to the compiler, per
# tools/scl-compiler/scl/mapping.py's own docstring -- still built
# faithfully since it's the human-facing single-line source and feeds
# the diagram generator's same Station object).
# --------------------------------------------------------------------

def _all_voltage_levels(station: Station):
    """Every VoltageLevel this document needs an element for: the real,
    user-chosen switchyards (station.voltage_levels) plus each
    transformer's own small LV stub (xfmr.lv_vl) -- the latter is
    deliberately NOT part of station.voltage_levels itself (see
    generator/layouts/transformer_lv.py's header), so both writer-side
    concerns that need "every VL" (node-path computation, VoltageLevel
    element emission) go through this one helper instead of duplicating
    the "plus every transformer's lv_vl" logic twice.
    """
    for vl in station.voltage_levels:
        yield vl
    for xfmr in station.transformers:
        yield xfmr.lv_vl


def _compute_node_paths(station: Station) -> Dict[Node, str]:
    """Every node's full SCL pathName, keyed by the Node object itself
    (Node has eq=False -- identity hashing -- so this is a safe dict
    key even though two nodes in different bays can share a bare
    `name`).
    """
    paths: Dict[Node, str] = {}
    for vl in _all_voltage_levels(station):
        for bay in vl.bays:
            for node in bay.connectivity_nodes:
                paths[node] = "%s/%s/%s/%s" % (station.name, vl.vl_name, bay.name, node.name)
    return paths


def _build_substation(root, station: Station, node_paths: Dict[Node, str]):
    substation = _el(root, "Substation", {"name": station.name})

    for xfmr in station.transformers:
        _build_transformer_element(substation, xfmr, node_paths)

    for vl in _all_voltage_levels(station):
        _build_voltage_level(substation, vl, node_paths)


def _build_transformer_element(substation, xfmr: Transformer, node_paths):
    ptr = _el(substation, "PowerTransformer", {"name": xfmr.name, "type": "PTR"})

    hv = _el(ptr, "TransformerWinding", {"name": "HV", "type": "PTW"})
    _el(hv, "Terminal", {"connectivityNode": node_paths[xfmr.hv_tap], "cNodeName": xfmr.hv_tap.name})
    _el(hv, "TapChanger", {"name": "LTC1", "type": "LTC"})

    lv = _el(ptr, "TransformerWinding", {"name": "LV", "type": "PTW"})
    _el(lv, "Terminal", {"connectivityNode": node_paths[xfmr.lv_tap], "cNodeName": xfmr.lv_tap.name})


def _build_voltage_level(substation, vl: VoltageLevelBuild, node_paths):
    vl_elem = _el(substation, "VoltageLevel", {"name": vl.vl_name})
    _el(vl_elem, "Voltage", {"unit": "V", "multiplier": "k"}, text=_attr_str(vl.kv))
    for bay in vl.bays:
        _build_bay(vl_elem, bay, node_paths)


def _build_bay(vl_elem, bay: BayGroup, node_paths):
    bay_attrib = {"name": bay.name}
    if bay.desc:
        bay_attrib["desc"] = bay.desc
    bay_elem = _el(vl_elem, "Bay", bay_attrib)

    for breaker in bay.breakers:
        ce = _el(bay_elem, "ConductingEquipment", {"name": breaker.name, "type": breaker.equip_type})
        _el(ce, "Terminal", {"connectivityNode": node_paths[breaker.node_a], "cNodeName": breaker.node_a.name})
        _el(ce, "Terminal", {"connectivityNode": node_paths[breaker.node_b], "cNodeName": breaker.node_b.name})

    for node in bay.connectivity_nodes:
        _el(bay_elem, "ConnectivityNode", {
            "name": node.name, "pathName": node_paths[node], "desc": node.desc or None,
        })


# --------------------------------------------------------------------
# Communication
# --------------------------------------------------------------------

def _build_communication(root, station: Station, mac_appid_index: Dict[str, int]):
    comm = _el(root, "Communication")
    subnet = _el(comm, "SubNetwork", {"name": "StationBus", "type": "8-MMS",
                                       "desc": "Shared GOOSE broadcast port + MMS-lite station LAN"})
    priv = _private(subnet)
    _oc_el(priv, "transport", {"goosePort": station.network.goose_port})

    for i, breaker in enumerate(station.all_breakers(), start=1):
        _build_connected_ap_breaker(subnet, station, breaker, i)

    for i, xfmr in enumerate(station.transformers, start=1):
        _build_connected_ap_transformer(subnet, station, xfmr, mac_appid_index[xfmr.name])

    _build_connected_ap_scada(subnet, station)


def _build_connected_ap_breaker(subnet, station: Station, breaker: Breaker, index: int):
    net = station.network
    cap = _el(subnet, "ConnectedAP", {"iedName": breaker.name, "apName": "AP1"})
    gse = _el(cap, "GSE", {"ldInst": "LD0", "cbName": "gcbGoose1"})
    addr = _el(gse, "Address")
    _el(addr, "P", {"type": "MAC-Address"}, text=naming.mac_address(net.mac_prefix, index))
    _el(addr, "P", {"type": "APPID"}, text=naming.appid(net.appid_base, index))
    _el(addr, "P", {"type": "VLAN-ID"}, text=net.vlan_id)
    _el(addr, "P", {"type": "VLAN-PRIORITY"}, text=_attr_str(net.vlan_priority_breaker))
    _el(gse, "MinTime", {"unit": "s", "multiplier": "m"}, text=_attr_str(net.gse_min_time_ms))
    _el(gse, "MaxTime", {"unit": "s", "multiplier": "m"}, text=_attr_str(net.gse_max_time_ms))


def _build_connected_ap_transformer(subnet, station: Station, xfmr: Transformer, mac_appid_idx: int):
    net = station.network
    cap = _el(subnet, "ConnectedAP", {"iedName": xfmr.name, "apName": "AP1"})
    xfmr_index = station.transformers.index(xfmr) + 1
    gse = _el(cap, "GSE", {"ldInst": "LD0", "cbName": "gcbGoose1"})
    addr = _el(gse, "Address")
    _el(addr, "P", {"type": "MAC-Address"}, text=naming.mac_address(net.mac_prefix, mac_appid_idx))
    _el(addr, "P", {"type": "APPID"}, text=naming.appid(net.appid_base, mac_appid_idx))
    _el(addr, "P", {"type": "VLAN-ID"}, text=net.vlan_id)
    _el(addr, "P", {"type": "VLAN-PRIORITY"}, text=_attr_str(net.vlan_priority_transformer))
    _el(gse, "MinTime", {"unit": "s", "multiplier": "m"}, text=_attr_str(net.gse_min_time_ms))
    _el(gse, "MaxTime", {"unit": "s", "multiplier": "m"}, text=_attr_str(net.gse_max_time_ms))

    smv = _el(cap, "SMV", {"ldInst": "LD0", "cbName": "svc%s" % xfmr.name})
    smv_addr = _el(smv, "Address")
    _el(smv_addr, "P", {"type": "MAC-Address"}, text="01-0C-CD-04-00-%02d" % xfmr_index)
    _el(smv_addr, "P", {"type": "APPID"}, text="%04d" % (4000 + xfmr_index))
    _el(smv_addr, "P", {"type": "VLAN-ID"}, text=net.vlan_id)
    _el(smv_addr, "P", {"type": "VLAN-PRIORITY"}, text=_attr_str(net.vlan_priority_transformer))


def _build_connected_ap_scada(subnet, station: Station):
    _el(subnet, "ConnectedAP", {"iedName": station.scada.ied_name, "apName": "AP1"})
    # Bare <ConnectedAP/>, matching switchyard.scd -- SCADA never publishes
    # GOOSE, so it needs no GSE, and no address of any kind: every node
    # resolves peers by name at runtime (sas/proto/discovery.lua).


# --------------------------------------------------------------------
# IEDs
# --------------------------------------------------------------------

def _build_ieds(root, station: Station, interlocks_by_breaker, remote_trips_by_breaker):
    for breaker in station.all_breakers():
        _build_breaker_ied(root, station, breaker, interlocks_by_breaker.get(breaker.name, []),
                            remote_trips_by_breaker.get(breaker.name, []))
    for xfmr in station.transformers:
        _build_transformer_ied(root, station, xfmr)
    _build_scada_ied(root, station)


def _breaker_io_prefix(breaker: Breaker) -> str:
    return breaker.name.lower()


def _build_breaker_ied(root, station: Station, breaker: Breaker, interlocks, remote_trip_xfmrs):
    prot = station.protection
    ied_settings = station.ied_settings
    ied = _el(root, "IED", {"name": breaker.name})
    ap = _el(ied, "AccessPoint", {"name": "AP1"})
    server = _el(ap, "Server")
    _el(server, "Authentication")
    ld = _el(server, "LDevice", {"inst": "LD0"})

    ln0 = _el(ld, "LN0", {"lnClass": "LLN0", "inst": "", "lnType": "LN0_Basic"})
    priv = _private(ln0)
    _oc_el(priv, "iedSettings", {
        "tickIntervalSec": ied_settings.tick_interval_sec,
        "integritySec": ied_settings.integrity_sec,
        "gooseStaleAfterSec": ied_settings.goose_stale_after_sec,
        "mmsPort": ied_settings.mms_port,
    })
    for peer_name, interlock_id in interlocks:
        _oc_el(priv, "interlock", {
            "id": interlock_id, "localRef": "XCBR1.PosCtl", "blockValue": "closed",
            "peerIed": peer_name, "peerRef": "XCBR1.Pos", "condition": "eq", "peerValue": "closed",
        })
    # One ptocScheme PER PHASE (PTOC1A/B/C, each watching its own phase
    # current) rather than one scheme fed by a single aggregate reading --
    # matches real numerical relays' separate 50/51-A/B/C elements, and is
    # required for correctness here since MMXU1 only ever exposes 3
    # independent per-phase current points now (see AMP_PHASES), never one
    # combined "Amp". A single-phase-to-ground fault (the most common
    # fault type) only elevates one phase's current, so a scheme watching
    # just one phase would miss faults on the other two.
    for phase, amp_do in zip("ABC", AMP_PHASES):
        ptoc_attrib = {
            "name": "PTOC1%s" % phase, "input": "MMXU1.%s" % amp_do, "trip": "XCBR1.PosCtl",
            "pickup": prot.ptoc_pickup, "curve": prot.ptoc_curve, "resetSec": prot.ptoc_reset_sec,
            "respectInterlocks": False,
        }
        if prot.ptoc_curve == "DEFINITE_TIME":
            ptoc_attrib["definiteTimeSec"] = prot.ptoc_definite_time_sec
        else:
            ptoc_attrib["timeMultiplier"] = prot.ptoc_time_multiplier
        _oc_el(priv, "ptocScheme", ptoc_attrib)
    for xfmr in remote_trip_xfmrs:
        # One remoteTrip per phase's differential element (see
        # _build_transformer_ied's PDIF1A/B/C) -- any single phase's
        # differential operating must open this breaker, so each phase's
        # Op is its own independent rule (matches the interlocks/
        # remoteTrips list-of-independent-rules pattern already used
        # elsewhere, no "OR of refs" primitive needed).
        for phase in "ABC":
            _oc_el(priv, "remoteTrip", {
                "id": "%s_DIFF_TRIP_%s" % (xfmr.name, phase), "peerIed": xfmr.name,
                "peerRef": "PDIF1%s.Op" % phase,
                "condition": "eq", "peerValue": True, "localRef": "XCBR1.PosCtl", "tripValue": "open",
            })

    dataset = _el(ln0, "DataSet", {"name": "dsGoose1"})
    _el(dataset, "FCDA", {"lnClass": "XCBR", "lnInst": 1, "doName": "Pos", "fc": "ST"})

    rc = _el(ln0, "ReportControl", {"name": "rcbStatus1", "datSet": "dsGoose1", "confRev": 1, "bufTime": 0})
    _el(rc, "TrgOps", {"dchg": True, "qchg": True, "gi": True})
    _el(rc, "OptFields")

    _el(ln0, "GSEControl", {
        "name": "gcbGoose1", "datSet": "dsGoose1", "appID": "%s/gcbGoose1" % breaker.name,
        "type": "GOOSE", "securityEnable": "None",
    })

    prefix = _breaker_io_prefix(breaker)
    xcbr = _el(ld, "LN", {"prefix": "", "lnClass": "XCBR", "inst": 1, "lnType": "XCBR_Basic"})
    doi_pos = _el(xcbr, "DOI", {"name": "Pos"})
    pos_priv = _private(doi_pos)
    pos_point = _oc_el(pos_priv, "point", {"deadband": 0})
    _oc_el(pos_point, "redstoneIo", {
        "address": "%s-status-redstone" % prefix, "openSide": 0, "closedSide": 1,
    })
    doi_posctl = _el(xcbr, "DOI", {"name": "PosCtl"})
    posctl_priv = _private(doi_posctl)
    posctl_point = _oc_el(posctl_priv, "point")
    _oc_el(posctl_point, "redstoneIo", {
        "address": "%s-control-redstone" % prefix, "tripSide": 2, "closeSide": 3,
        "pulseMs": 250, "sboTimeoutSec": 30,
    })

    # 3 independent ammeters (per-phase current) + 3 independent
    # voltmeters (per-phase-pair voltage) -- one physical Create:EE meter
    # block, and one Adapter-bridged address, per DOI. See AMP_PHASES/
    # VOL_PHASES's definition above for why this replaced a single
    # combined "Amp"/"Vol" pair.
    mmxu = _el(ld, "LN", {"prefix": "", "lnClass": "MMXU", "inst": 1, "lnType": "MMXU_Basic"})
    for suffix, do_name in zip("abc", AMP_PHASES):
        doi = _el(mmxu, "DOI", {"name": do_name})
        point = _oc_el(_private(doi), "point", {"deadband": 0.5})
        _oc_el(point, "meterIo", {"address": "%s-ammeter-%s-adapter" % (prefix, suffix), "method": "getValue"})
    for suffix, do_name in zip("ab bc ca".split(), VOL_PHASES):
        doi = _el(mmxu, "DOI", {"name": do_name})
        point = _oc_el(_private(doi), "point", {"deadband": 2.0})
        _oc_el(point, "meterIo", {"address": "%s-voltmeter-%s-adapter" % (prefix, suffix), "method": "getValue"})


def _build_transformer_ied(root, station: Station, xfmr: Transformer):
    ied_settings = station.ied_settings
    prot = station.protection
    ied = _el(root, "IED", {
        "name": xfmr.name,
        "desc": "Dedicated transformer differential-protection IED -- HV+LV CT meters, "
                "no breaker of its own; trips the breaker(s) bounding its HV tap via "
                "remoteTrips[] on those IEDs (its LV side is disconnect-only, no IED "
                "to remotely trip)",
    })
    ap = _el(ied, "AccessPoint", {"name": "AP1"})
    server = _el(ap, "Server")
    _el(server, "Authentication")
    ld = _el(server, "LDevice", {"inst": "LD0"})

    ln0 = _el(ld, "LN0", {"lnClass": "LLN0", "inst": "", "lnType": "LN0_Basic"})
    priv = _private(ln0)
    _oc_el(priv, "iedSettings", {
        "tickIntervalSec": ied_settings.tick_interval_sec,
        "integritySec": ied_settings.integrity_sec,
        "gooseStaleAfterSec": ied_settings.goose_stale_after_sec,
        "mmsPort": ied_settings.mms_port,
    })
    # One pdifScheme PER PHASE (PDIF1A/B/C, each comparing that phase's
    # HV CT against that same phase's LV CT) -- a single scheme fed by
    # only one representative phase would both miss a single-phase
    # internal fault on either of the other two phases, and could
    # false-trip by comparing two DIFFERENT phases' currents if the
    # "representative" phase ever differed between HV and LV (e.g. a
    # Dyn11 vector group's phase rotation) -- pdif.lua is magnitude-only
    # with no such compensation (see sas/protection/pdif.lua's header),
    # so per-phase comparison is the only correct pairing here.
    for phase, amp_do in zip("ABC", AMP_PHASES):
        pdif = _oc_el(priv, "pdifScheme", {
            "name": "PDIF1%s" % phase, "minPickup": prot.pdif_min_pickup,
            "restraintSlope": prot.pdif_restraint_slope, "respectInterlocks": False,
        })
        _oc_el(pdif, "input", {"ref": "MMXU1.%s" % amp_do, "scale": xfmr.scale_hv})
        _oc_el(pdif, "input", {"ref": "MMXU2.%s" % amp_do, "scale": round(xfmr.scale_lv, 3)})
    _oc_el(priv, "pdisScheme", {
        "name": "PDIS1", "zone1ReachOhms": 12.5, "zone1DelaySec": 0,
        "zone2ReachOhms": 25, "zone2DelaySec": 0.3,
    })

    dataset = _el(ln0, "DataSet", {"name": "dsStatus1"})
    for lnInst in (1, 2):
        for amp_do in AMP_PHASES:
            _el(dataset, "FCDA", {"lnClass": "MMXU", "lnInst": lnInst, "doName": amp_do, "fc": "MX"})

    rc = _el(ln0, "ReportControl", {"name": "rcb%s" % xfmr.name, "datSet": "dsStatus1", "confRev": 1, "bufTime": 0})
    _el(rc, "TrgOps", {"dchg": True, "qchg": True, "gi": True})
    _el(rc, "OptFields")

    _el(ln0, "GSEControl", {
        "name": "gcbGoose1", "appID": "%s/gcbGoose1" % xfmr.name, "type": "GOOSE", "securityEnable": "None",
    })
    svc = _el(ln0, "SampledValueControl", {
        "name": "svc%s" % xfmr.name, "smvID": "%s/svc%s" % (xfmr.name, xfmr.name),
        "smpRate": 80, "nofASDU": 1, "securityEnable": "None",
    })
    _el(svc, "SmvOpts")

    # 3 independent ammeters per side (per-phase current) -- no voltage
    # DOIs here, unlike a breaker's MMXU: a transformer differential
    # scheme only ever needs current (see pdifScheme above), and this
    # LNodeType's VolAB/BC/CA DOs are simply left un-DOI'd, which real SCL
    # allows (see AMP_PHASES/VOL_PHASES's definition above).
    prefix = xfmr.name.lower()
    mmxu1 = _el(ld, "LN", {"prefix": "", "lnClass": "MMXU", "inst": 1, "lnType": "MMXU_Basic", "desc": "HV-side CT"})
    for suffix, amp_do in zip("abc", AMP_PHASES):
        doi = _el(mmxu1, "DOI", {"name": amp_do})
        point = _oc_el(_private(doi), "point", {"deadband": 0.5})
        _oc_el(point, "meterIo", {"address": "%s-hv-ammeter-%s-adapter" % (prefix, suffix), "method": "getValue"})

    mmxu2 = _el(ld, "LN", {"prefix": "", "lnClass": "MMXU", "inst": 2, "lnType": "MMXU_Basic", "desc": "LV-side CT"})
    for suffix, amp_do in zip("abc", AMP_PHASES):
        doi = _el(mmxu2, "DOI", {"name": amp_do})
        point = _oc_el(_private(doi), "point", {"deadband": 0.5})
        _oc_el(point, "meterIo", {"address": "%s-lv-ammeter-%s-adapter" % (prefix, suffix), "method": "getValue"})

    _el(ld, "LN", {
        "prefix": "", "lnClass": "RDRE", "inst": 1, "lnType": "RDRE_Basic",
        "desc": "Disturbance recorder -- data-model only, not wired to any event buffer",
    })


def _build_scada_ied(root, station: Station):
    scada = station.scada
    ied_settings = station.ied_settings
    ied = _el(root, "IED", {"name": scada.ied_name, "type": "SCADA"})
    ap = _el(ied, "AccessPoint", {"name": "AP1"})
    server = _el(ap, "Server")
    _el(server, "Authentication")
    ld = _el(server, "LDevice", {"inst": "LD0"})

    ln0 = _el(ld, "LN0", {"lnClass": "LLN0", "inst": "", "lnType": "LN0_Basic"})
    priv = _private(ln0)
    _oc_el(priv, "iedSettings", {
        "tickIntervalSec": ied_settings.tick_interval_sec,
        "resyncSec": ied_settings.resync_sec,
        "connectTimeoutSec": ied_settings.connect_timeout_sec,
        "reconnectIntervalSec": ied_settings.reconnect_interval_sec,
        "gooseStaleAfterSec": ied_settings.goose_stale_after_sec,
        "hmsPort": ied_settings.hms_port,
    })
    _oc_el(priv, "historian", {
        "dir": scada.historian_dir, "maxBytes": scada.historian_max_bytes,
        "maxFiles": scada.historian_max_files,
    })

    if scada.auto_undervoltage_alarms:
        for vl in station.voltage_levels:
            ref_breaker = next((b for b in vl.breakers if b.equip_type == EQUIP_CBR), None)
            if ref_breaker is None:
                continue
            threshold = vl.kv * 1000 * scada.undervoltage_ratio
            # One alarm per phase-pair -- a single-phase sag (the common
            # case for an unbalanced fault) only depresses one of the
            # three VolAB/BC/CA readings, so alarming on just one pair
            # would miss it.
            for pair, vol_do in zip("AB BC CA".split(), VOL_PHASES):
                _oc_el(priv, "alarm", {
                    "id": "%s_VOLTAGE_LOW_%s" % (vl.vl_name, pair),
                    "ref": "%s/LD0/MMXU1.%s" % (ref_breaker.name, vol_do),
                    "condition": "lt", "value": round(threshold),
                    "severity": "medium",
                    "message": "%skV bus undervoltage (%s) at %s" % (_attr_str(vl.kv), pair, ref_breaker.name),
                })

    if scada.auto_trip_alarms:
        for xfmr in station.transformers:
            for phase in "ABC":
                _oc_el(priv, "alarm", {
                    "id": "%s_DIFF_TRIP_%s" % (xfmr.name, phase),
                    "ref": "%s/LD0/PDIF1%s.Op" % (xfmr.name, phase),
                    "condition": "eq", "value": True,
                    "severity": "critical",
                    "message": "Transformer %s differential protection operated (phase %s)" % (xfmr.name, phase),
                })


# --------------------------------------------------------------------
# Derivation glue: per-breaker interlock/remote-trip lookup tables
# --------------------------------------------------------------------

def _compute_interlocks_by_breaker(station: Station) -> Dict[str, List]:
    by_breaker: Dict[str, List] = {}
    for vl in station.voltage_levels:
        for a, b in illustrative_interlocks(vl):
            by_breaker.setdefault(a.name, []).append((b.name, "%s_VS_%s" % (a.name, b.name)))
            by_breaker.setdefault(b.name, []).append((a.name, "%s_VS_%s" % (b.name, a.name)))
    return by_breaker


def _compute_remote_trips_by_breaker(station: Station) -> Dict[str, List[Transformer]]:
    by_breaker: Dict[str, List[Transformer]] = {}
    for xfmr in station.transformers:
        for breaker in remote_trips_for(xfmr):
            by_breaker.setdefault(breaker.name, []).append(xfmr)
    return by_breaker


def _compute_mac_appid_index(station: Station) -> Dict[str, int]:
    """A single continuous 1..N counter across breakers then
    transformers for MAC/APPID assignment -- deliberately simpler than
    switchyard.scd's hand-authored numbers (which happened to set
    XFMR1's MAC/APPID equal to its own mms host number, 20, rather than
    continuing the breaker sequence); this avoids any risk of collision
    without needing to reproduce that coincidence.
    """
    index: Dict[str, int] = {}
    i = 1
    for breaker in station.all_breakers():
        index[breaker.name] = i
        i += 1
    for xfmr in station.transformers:
        index[xfmr.name] = i
        i += 1
    return index


# --------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------

def write(station: Station) -> etree._ElementTree:
    """Builds the full SCL document for `station`. Returns an
    lxml ElementTree ready for etree.tostring()/write().
    """
    root = etree.Element(q("SCL"), nsmap={None: SCL_NS, "oc": OC_NS},
                          attrib={"version": "2007", "revision": "B", "release": "4"})

    header_id = "%s-generated" % naming.sanitize_identifier(station.name).lower()
    header = _el(root, "Header", {"id": header_id, "version": "1", "toolID": "oc-scl-generator"})
    _el(header, "Text", text=(
        "Generated by tools/scl-generator/scl_generate.py. See "
        "tools/scl-generator/README.md and README.md's \"SCL / Substation "
        "Configuration Language\" section for how this compiles and what's "
        "functional vs descriptive-only."
    ))

    node_paths = _compute_node_paths(station)
    _build_substation(root, station, node_paths)

    mac_appid_index = _compute_mac_appid_index(station)
    _build_communication(root, station, mac_appid_index)

    interlocks_by_breaker = _compute_interlocks_by_breaker(station)
    remote_trips_by_breaker = _compute_remote_trips_by_breaker(station)
    _build_ieds(root, station, interlocks_by_breaker, remote_trips_by_breaker)

    _build_data_type_templates(root)

    return etree.ElementTree(root)


def to_string(tree: etree._ElementTree) -> bytes:
    return etree.tostring(tree, pretty_print=True, xml_declaration=True, encoding="UTF-8")
