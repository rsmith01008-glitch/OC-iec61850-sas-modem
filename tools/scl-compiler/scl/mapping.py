"""SCL objects -> {iedName -> cfg dict} ready for codegen.encode_top_level.

Every element/attribute name referenced here was cross-checked against the
vendored SCL2007B4 XSD (see schema/README.md) rather than assumed from
general 61850 familiarity -- in particular tFCDA (ldInst/prefix/lnClass/
lnInst/doName/daName/fc/ix), tTrgOps (dchg/qchg/dupd/period/gi, gi default
true, rest default false), tReportControl (confRev required unsignedInt,
bufTime optional unsignedInt default 0 -- IEC 61850-6 convention is
milliseconds), tGSEControl (appID required, type default "GOOSE"),
tGSE/MinTime/MaxTime (tDurationInMilliSec: decimal content, unit="s"
multiplier="m" both fixed, i.e. always milliseconds), tAnyLN (DataSet/
ReportControl/DOI all direct children of LN0 and LN alike, via a shared
base type), and tLN/tLN0 (`lnType` required attribute on both).

Substation/VoltageLevel/Bay/ConductingEquipment/Terminal/ConnectivityNode
are intentionally NOT read here -- see the plan's §3: nothing downstream
has a bay/diameter/topology concept, so the single-line geometry stays
descriptive-only (human-facing + optional --lint-topology), not consumed
for .cfg generation.
"""

from .parse import q, oc_q, children, child, find_all
from .private_ext import (
    point_private, ln0_private, subnetwork_private, report_control_private,
    scada_private, gse_timing_private,
)

CDC_TO_TYPE = {
    "SPS": "SPS",
    "DPS": "DPS",
    "SPC": "SPC",
    "DPC": "DPC",
    "MV": "MV",
}

# TrgOps' own schema defaults (tTrgOps) -- applied when a ReportControl has
# no <TrgOps> child at all (minOccurs="0" on tControlWithTriggerOpt).
_TRGOPS_DEFAULTS = {"dchg": False, "qchg": False, "dupd": False, "period": False, "gi": True}


class MappingError(Exception):
    pass


def _find_ldevice(ied_elem):
    ldevices = find_all(ied_elem, "LDevice")
    if len(ldevices) != 1:
        raise MappingError(
            "IED '%s' has %d LDevice(s); this compiler (and sas/model.lua) "
            "requires exactly 1 per IED" % (ied_elem.get("name"), len(ldevices))
        )
    return ldevices[0]


def _ln_elements(ld_elem):
    """LN0 (exactly one, required) + every LN (zero or more) under this LDevice."""
    ln0 = ld_elem.find(q("LN0"))
    if ln0 is None:
        raise MappingError("LDevice inst='%s' has no LN0" % ld_elem.get("inst"))
    return [ln0] + children(ld_elem, "LN")


def _ln_name(ln_elem):
    prefix = ln_elem.get("prefix") or ""
    return prefix + ln_elem.get("lnClass") + ln_elem.get("inst")


def _lnodetype_by_id(root_elem, lntype_id):
    dtt = root_elem.find(q("DataTypeTemplates"))
    if dtt is None:
        raise MappingError("SCL document has no DataTypeTemplates section")
    for lnt in children(dtt, "LNodeType"):
        if lnt.get("id") == lntype_id:
            return lnt
    raise MappingError("no LNodeType id='%s'" % lntype_id)


def _dotype_by_id(root_elem, dotype_id):
    dtt = root_elem.find(q("DataTypeTemplates"))
    for dot in children(dtt, "DOType"):
        if dot.get("id") == dotype_id:
            return dot
    raise MappingError("no DOType id='%s'" % dotype_id)


def _resolve_cdc(root_elem, ln_type_id, do_name, ln_label):
    """LN/@lnType -> LNodeType[@id] -> DO[@name=do_name]/@type -> DOType[@id]/@cdc."""
    lnt = _lnodetype_by_id(root_elem, ln_type_id)
    do_elem = None
    for do in children(lnt, "DO"):
        if do.get("name") == do_name:
            do_elem = do
            break
    if do_elem is None:
        raise MappingError(
            "%s: DOI name='%s' has no matching DO in LNodeType id='%s'"
            % (ln_label, do_name, ln_type_id)
        )
    dotype_id = do_elem.get("type")
    dotype = _dotype_by_id(root_elem, dotype_id)
    cdc = dotype.get("cdc")
    our_type = CDC_TO_TYPE.get(cdc)
    if our_type is None:
        raise MappingError(
            "%s: DOI name='%s' has CDC '%s' (DOType id='%s'), which this "
            "compiler does not support -- only SPS/DPS/SPC/DPC/MV pass "
            "through" % (ln_label, do_name, cdc, dotype_id)
        )
    return our_type


def _goose_published_refs(ln0_elem):
    """Every "LN.doName" ref covered by any GSEControl's DataSet on this LN0."""
    refs = set()
    for gc in children(ln0_elem, "GSEControl"):
        ds_name = gc.get("datSet")
        if not ds_name:
            continue
        for ds in children(ln0_elem, "DataSet"):
            if ds.get("name") != ds_name:
                continue
            for fcda in children(ds, "FCDA"):
                ln = (fcda.get("prefix") or "") + (fcda.get("lnClass") or "") + (fcda.get("lnInst") or "")
                do_name = fcda.get("doName")
                if ln and do_name:
                    refs.add("%s.%s" % (ln, do_name))
    return refs


def _collect_points(root_elem, ld_elem):
    ln0 = ld_elem.find(q("LN0"))
    goose_refs = _goose_published_refs(ln0)
    points = []
    for ln_elem in _ln_elements(ld_elem):
        ln_name = _ln_name(ln_elem)
        lntype_id = ln_elem.get("lnType")
        for doi in children(ln_elem, "DOI"):
            do_name = doi.get("name")
            our_type = _resolve_cdc(root_elem, lntype_id, do_name, ln_name)
            entry = {"ln": ln_name, "doName": do_name, "type": our_type}
            entry["goose"] = ("%s.%s" % (ln_name, do_name)) in goose_refs
            entry.update(point_private(doi))
            points.append(entry)
    return points


def _find_subnetwork_and_ap(root_elem, ied_name):
    comm = root_elem.find(q("Communication"))
    if comm is None:
        raise MappingError("SCL document has no Communication section")
    for sn in children(comm, "SubNetwork"):
        for ap in children(sn, "ConnectedAP"):
            if ap.get("iedName") == ied_name:
                return sn, ap
    raise MappingError("IED '%s' has no ConnectedAP in any SubNetwork" % ied_name)


def _duration_to_seconds(elem):
    """tDurationInMilliSec content (decimal, unit="s" multiplier="m" both
    fixed by schema) -> seconds as a float."""
    if elem is None or elem.text is None:
        return None
    return float(elem.text) / 1000.0


def _map_goose(root_elem, ied_elem, ied_name, ld_inst, ln0_elem):
    gse_controls = children(ln0_elem, "GSEControl")
    if not gse_controls:
        return None
    if len(gse_controls) > 1:
        raise MappingError(
            "IED '%s': %d GSEControl blocks found; this compiler maps at "
            "most 1 per IED (one goose={} block per sas-ied.cfg)"
            % (ied_name, len(gse_controls))
        )
    gc = gse_controls[0]
    if not gc.get("appID"):
        raise MappingError("IED '%s': GSEControl '%s' missing required appID" % (ied_name, gc.get("name")))

    sn_elem, ap_elem = _find_subnetwork_and_ap(root_elem, ied_name)
    transport = subnetwork_private(sn_elem)
    if "goosePort" not in transport:
        raise MappingError(
            "SubNetwork '%s' has no Private/oc:transport/@goosePort" % sn_elem.get("name")
        )
    goose_cfg = {"port": transport["goosePort"]}

    gse_elem = None
    for gse in children(ap_elem, "GSE"):
        if gse.get("ldInst") == ld_inst and gse.get("cbName") == gc.get("name"):
            gse_elem = gse
            break
    if gse_elem is None:
        raise MappingError(
            "IED '%s': no GSE ldInst='%s' cbName='%s' under its ConnectedAP "
            "(GSEControl/GSE join must resolve)" % (ied_name, ld_inst, gc.get("name"))
        )

    min_sec = _duration_to_seconds(child(gse_elem, "MinTime"))
    max_sec = _duration_to_seconds(child(gse_elem, "MaxTime"))
    if max_sec is not None:
        goose_cfg["heartbeatSec"] = max_sec

    override = gse_timing_private(gse_elem)
    if "burstIntervalsSec" in override:
        goose_cfg["burstIntervalsSec"] = override["burstIntervalsSec"]
    elif min_sec is not None:
        ladder = []
        step = min_sec
        cap = max_sec if max_sec is not None else min_sec * 16
        while len(ladder) < 4 and step < cap:
            ladder.append(round(step, 3))
            step *= 2.5
        goose_cfg["burstIntervalsSec"] = ladder or [round(min_sec, 3)]

    return goose_cfg


def _map_report_control(ln0_elem, rc_elem, ied_name):
    ds_name = rc_elem.get("datSet")
    dataset = []
    if ds_name:
        ds_elem = None
        for ds in children(ln0_elem, "DataSet"):
            if ds.get("name") == ds_name:
                ds_elem = ds
                break
        if ds_elem is None:
            raise MappingError(
                "IED '%s': ReportControl '%s' references datSet='%s', "
                "which has no matching DataSet" % (ied_name, rc_elem.get("name"), ds_name)
            )
        for fcda in children(ds_elem, "FCDA"):
            if fcda.get("fc") is None:
                raise MappingError(
                    "IED '%s': DataSet '%s' FCDA missing required fc" % (ied_name, ds_name)
                )
            ln = (fcda.get("prefix") or "") + (fcda.get("lnClass") or "") + (fcda.get("lnInst") or "")
            do_name = fcda.get("doName")
            dataset.append("%s.%s" % (ln, do_name))

    trg_elem = child(rc_elem, "TrgOps")
    trg_ops = dict(_TRGOPS_DEFAULTS)
    if trg_elem is not None:
        for k in trg_ops:
            v = trg_elem.get(k)
            if v is not None:
                trg_ops[k] = v.strip().lower() == "true"

    conf_rev = rc_elem.get("confRev")
    if conf_rev is None:
        raise MappingError(
            "IED '%s': ReportControl '%s' missing required confRev" % (ied_name, rc_elem.get("name"))
        )

    entry = {
        "name": rc_elem.get("name"),
        "dataset": dataset,
        "trgOps": trg_ops,
        "bufTime": int(rc_elem.get("bufTime") or "0") / 1000.0,
        "confRev": int(conf_rev),
    }
    settings = report_control_private(rc_elem)
    if "periodSec" in settings:
        entry["periodSec"] = settings["periodSec"]
    elif trg_ops["period"]:
        raise MappingError(
            "IED '%s': ReportControl '%s' has TrgOps/period=true but no "
            "Private/oc:reportSettings/@periodSec" % (ied_name, rc_elem.get("name"))
        )
    return entry


def map_ied(root_elem, ied_elem):
    """Map one non-SCADA <IED> element to its sas-ied.cfg dict."""
    ied_name = ied_elem.get("name")
    ld_elem = _find_ldevice(ied_elem)
    ln0 = ld_elem.find(q("LN0"))

    priv = ln0_private(ln0)
    settings = priv["iedSettings"]

    cfg = {"iedName": ied_name, "logicalDevice": ld_elem.get("inst")}
    cfg["mms"] = {"port": settings.get("mmsPort", 8102)}

    goose_cfg = _map_goose(root_elem, ied_elem, ied_name, ld_elem.get("inst"), ln0)
    if goose_cfg is not None:
        cfg["goose"] = goose_cfg

    if "tickIntervalSec" in settings:
        cfg["tickIntervalSec"] = settings["tickIntervalSec"]
    if "integritySec" in settings:
        cfg["integritySec"] = settings["integritySec"]
    if "gooseStaleAfterSec" in settings:
        cfg["gooseStaleAfterSec"] = settings["gooseStaleAfterSec"]

    cfg["points"] = _collect_points(root_elem, ld_elem)

    if priv["interlocks"]:
        cfg["interlocks"] = priv["interlocks"]

    protection = priv["protection"]
    if protection["ptoc"] or protection["pdif"] or protection["pdis"]:
        cfg["protection"] = protection

    if priv["remoteTrips"]:
        cfg["remoteTrips"] = priv["remoteTrips"]

    reports = [
        _map_report_control(ln0, rc, ied_name)
        for rc in children(ln0, "ReportControl")
    ]
    if reports:
        cfg["reports"] = reports

    return cfg


def map_scada(root_elem, ied_elem):
    """Map the <IED type="SCADA"> element to its sas-scada.cfg dict.

    `ieds[]` is derived from every OTHER IED sharing a SubNetwork with this
    one -- just its `name` (see sas/proto/discovery.lua: SCADA resolves
    each configured IED's modem address/port at runtime, so nothing else
    needs to be carried through from SCL).
    """
    ld_elem = _find_ldevice(ied_elem)
    ln0 = ld_elem.find(q("LN0"))
    priv = ln0_private(ln0)
    settings = priv["iedSettings"]
    scada_ext = scada_private(ln0)

    cfg = {}
    cfg["scadaName"] = ied_elem.get("name")
    cfg["hms"] = {"port": settings.get("hmsPort", 8103)}

    # SCADA never publishes GOOSE (no GSEControl of its own -- it only
    # subscribes), so unlike a breaker/protection IED it can't go through
    # _map_goose (which resolves the port via a GSEControl<->GSE join). It
    # only needs the port, read directly off its SubNetwork.
    sn_elem, _ = _find_subnetwork_and_ap(root_elem, ied_elem.get("name"))
    transport = subnetwork_private(sn_elem)
    if "goosePort" not in transport:
        raise MappingError(
            "SubNetwork '%s' has no Private/oc:transport/@goosePort" % sn_elem.get("name")
        )
    cfg["goose"] = {"port": transport["goosePort"]}

    for key in (
        "tickIntervalSec", "resyncSec", "connectTimeoutSec",
        "reconnectIntervalSec", "gooseStaleAfterSec",
    ):
        if key in settings:
            cfg[key] = settings[key]

    ieds = []
    for ap in children(sn_elem, "ConnectedAP"):
        peer_name = ap.get("iedName")
        if peer_name == ied_elem.get("name"):
            continue
        peer_ied = None
        for candidate in find_all(root_elem, "IED"):
            if candidate.get("name") == peer_name:
                peer_ied = candidate
                break
        if peer_ied is None or peer_ied.get("type") == "SCADA":
            continue
        # Just the name -- sas/proto/discovery.lua resolves it to a modem
        # address/port at runtime, so no ConnectedAP address/port needs to
        # be carried through from SCL at all.
        ieds.append({"name": peer_name})
    cfg["ieds"] = ieds

    if scada_ext["historian"]:
        cfg["historian"] = scada_ext["historian"]
    if scada_ext["alarms"]:
        cfg["alarms"] = scada_ext["alarms"]

    return cfg


def map_document(root_elem):
    """Whole SCL document -> {iedName -> cfg dict}. Exactly one IED may
    carry `type="SCADA"` (maps to sas-scada.cfg); every other IED maps to
    its own sas-ied-<name>.cfg via map_ied.
    """
    out = {}
    scada_seen = False
    for ied_elem in find_all(root_elem, "IED"):
        name = ied_elem.get("name")
        if ied_elem.get("type") == "SCADA":
            if scada_seen:
                raise MappingError("more than one IED has type=\"SCADA\"")
            scada_seen = True
            out[name] = {"role": "scada", "cfg": map_scada(root_elem, ied_elem)}
        else:
            out[name] = {"role": "ied", "cfg": map_ied(root_elem, ied_elem)}
    return out
