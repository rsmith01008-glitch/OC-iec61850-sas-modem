"""Pure domain model for a generated switchyard -- no XML, no `input()`,
no filesystem I/O. Every layout builder (`generator/layouts/*.py`)
produces a `VoltageLevelBuild`; `generator/wizard.py` assembles a full
`Station`; `generator/scl_writer.py` and `generator/diagram/*` are the
two independent renderers of a `Station`.

Node/Breaker naming mirrors real SCL directly on purpose: a `Node` is a
`ConnectivityNode`, a `Breaker` is a `ConductingEquipment type="CBR"`
with exactly 2 terminals, a `BayGroup` is a `Bay`. Keeping these 1:1 with
their SCL counterparts is what makes `scl_writer.py` a nearly mechanical
translation rather than a second modeling layer.
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import List, Optional


class TapKind(Enum):
    LINE = "line"
    FEEDER = "feeder"
    TRANSFORMER = "transformer"


class LayoutKind(Enum):
    BREAKER_AND_HALF = "breaker_and_half"
    SINGLE_BUS = "single_bus"
    MAIN_AND_TRANSFER = "main_and_transfer"
    RING_BUS = "ring_bus"
    # Not user-selectable -- generator/layouts/transformer_lv.py's fixed,
    # non-redundant shape for a transformer's LV side (see that module's
    # header for why this deliberately isn't one of the 4 layouts above).
    TRANSFORMER_LV = "transformer_lv"


@dataclass
class Tap:
    """One bay's worth of intent, before any layout has turned it into
    breakers/nodes: "there is a line/feeder/transformer connection here,
    named X." A `TapKind.TRANSFORMER` tap's HV side is built by the same
    layout builder as every other tap in its switchyard; its LV side is
    built separately and immediately (see generator/wizard.py) via
    generator/layouts/transformer_lv.py -- there is no "unclaimed pool
    pairing" step anymore (a transformer's LV side is never another
    independently-laid-out switchyard; see that module's header for why).
    """
    name: str
    kind: TapKind


@dataclass(eq=False)
class Node:
    """A `ConnectivityNode`. `name` is the local (bay-scoped) name;
    `pathName`/full addressing is scl_writer.py's concern, not this
    model's -- this layer only needs enough to build the breaker graph
    and label the diagram.

    `eq=False` is deliberate: two distinct nodes can share a `name`
    across different voltage levels (every VL has its own "Bus"-ish
    names), so identity, not field equality, is what "is this the same
    node" must mean -- also what makes Node hashable for use in sets
    (`breakers_bounding`'s `node is ...` checks, interlock dedup sets).
    """
    name: str
    desc: str = ""


@dataclass(eq=False)
class BusNode(Node):
    """A bare bus rail connectivity point -- no tap of its own, never
    has an oc:point/DOI (nothing to measure or control on a bus itself).
    """


@dataclass(eq=False)
class TapNode(Node):
    """A connectivity point that terminates a real Tap (line/feeder/
    transformer winding). `tap` has a dataclass default only to satisfy
    field-ordering after Node's own defaulted `desc` field -- every
    TapNode must actually have one, enforced in __post_init__.
    """
    tap: Optional[Tap] = None

    def __post_init__(self):
        if self.tap is None:
            raise ValueError("TapNode requires a tap")


#: Real SCL tCommonConductingEquipmentEnum values this tool emits.
#: CBR = circuit breaker (gets a full protection/control IED). DIS =
#: disconnect switch (descriptive topology only -- no IED, no remote
#: control/monitoring; matches real "manual/local" disconnect practice
#: and this tool's transformer-LV-output convention specifically).
EQUIP_CBR = "CBR"
EQUIP_DIS = "DIS"


@dataclass(eq=False)
class Breaker:
    """A `ConductingEquipment` with exactly two terminals -- real SCL's
    own `Terminal` cardinality limit (0..2), never more. Despite the
    name (kept for historical/API-stability reasons -- most instances
    really are breakers), `equip_type` may also be `EQUIP_DIS` for a
    disconnect switch; see EQUIP_CBR/EQUIP_DIS above. Identity equality
    (`eq=False`), same reasoning as Node.
    """
    name: str
    node_a: Node
    node_b: Node
    equip_type: str = EQUIP_CBR

    def other_node(self, node: Node) -> Node:
        if node is self.node_a:
            return self.node_b
        if node is self.node_b:
            return self.node_a
        raise ValueError("%r is not a terminal of breaker %r" % (node, self.name))


@dataclass
class BayGroup:
    """A `Bay`: the SCL grouping unit for a set of breakers + the
    connectivity nodes owned by this bay (real SCL requires every
    ConnectivityNode to live inside exactly one Bay).
    """
    name: str
    desc: str = ""
    breakers: List[Breaker] = field(default_factory=list)
    connectivity_nodes: List[Node] = field(default_factory=list)


@dataclass
class VoltageLevelBuild:
    """One layout builder's full output for one voltage level -- the
    (nodes, breakers, bays) graph, plus the inputs that produced it.
    """
    vl_name: str
    kv: float
    layout_kind: LayoutKind
    taps: List[Tap]
    nodes: List[Node] = field(default_factory=list)
    breakers: List[Breaker] = field(default_factory=list)
    bays: List[BayGroup] = field(default_factory=list)

    def tap_node_for(self, tap: Tap) -> TapNode:
        for node in self.nodes:
            if isinstance(node, TapNode) and node.tap is tap:
                return node
        raise ValueError("no TapNode found for tap %r" % (tap.name,))


@dataclass
class Transformer:
    """A tap into exactly one real switchyard (`hv_vl`/`hv_tap`, built by
    whichever layout the user chose for that switchyard -- same as any
    Line/Feeder tap) whose LV side is a small, fixed, non-redundant
    structure (`lv_vl`/`lv_tap`, built by
    generator/layouts/transformer_lv.py, never a second independently-
    laid-out switchyard -- see that module's header for the real-
    substation reasoning). `lv_vl` still has the shape of a
    VoltageLevelBuild so scl_writer.py/diagram code can treat it
    uniformly for node-path/coordinate purposes, but its `layout_kind` is
    the non-selectable `LayoutKind.TRANSFORMER_LV` sentinel and it is
    NEVER added to `Station.voltage_levels` (see generator/wizard.py).

    `scale_lv`/`scale_hv` are the PDIF differential turns-ratio inputs --
    always derived from HV/LV kV, never asked in the wizard (matches
    scl/switchyard.scd's XFMR1: HV scale 1.0, LV scale 800/230 = 3.478).
    """
    name: str
    hv_vl: VoltageLevelBuild
    hv_tap: TapNode
    lv_vl: VoltageLevelBuild
    lv_tap: Node

    def __post_init__(self):
        if self.hv_vl.kv <= self.lv_vl.kv:
            raise ValueError(
                "Transformer %r: hv_vl (%skV) must be strictly higher than "
                "its LV side (%skV)" % (self.name, self.hv_vl.kv, self.lv_vl.kv)
            )

    @property
    def scale_hv(self) -> float:
        return 1.0

    @property
    def scale_lv(self) -> float:
        return self.hv_vl.kv / self.lv_vl.kv


@dataclass
class ProtectionDefaults:
    ptoc_pickup: float = 1.2
    ptoc_curve: str = "IEC_VERY_INVERSE"
    ptoc_time_multiplier: float = 0.3
    ptoc_definite_time_sec: float = 0.5
    ptoc_reset_sec: float = 0.1
    pdif_min_pickup: float = 0.2
    pdif_restraint_slope: float = 0.4


@dataclass
class NetworkDefaults:
    goose_port: int = 8104
    mac_prefix: str = "01-0C-CD-01-00-"
    appid_base: int = 1
    vlan_id: str = "000"
    vlan_priority_breaker: int = 4
    vlan_priority_transformer: int = 6
    gse_min_time_ms: int = 100
    gse_max_time_ms: int = 5000


@dataclass
class IedSettingsDefaults:
    tick_interval_sec: float = 0.2
    integrity_sec: int = 30
    goose_stale_after_sec: int = 15
    mms_port: int = 8102
    hms_port: int = 8103
    resync_sec: int = 60
    connect_timeout_sec: int = 5
    reconnect_interval_sec: int = 10


@dataclass
class ScadaDefaults:
    ied_name: str = "SCADA1"
    historian_dir: str = "/var/log/sas-scada"
    historian_max_bytes: int = 262144
    historian_max_files: int = 5
    auto_undervoltage_alarms: bool = True
    undervoltage_ratio: float = 0.9
    auto_trip_alarms: bool = True


@dataclass
class Station:
    name: str
    voltage_levels: List[VoltageLevelBuild] = field(default_factory=list)
    transformers: List[Transformer] = field(default_factory=list)
    protection: ProtectionDefaults = field(default_factory=ProtectionDefaults)
    network: NetworkDefaults = field(default_factory=NetworkDefaults)
    ied_settings: IedSettingsDefaults = field(default_factory=IedSettingsDefaults)
    scada: ScadaDefaults = field(default_factory=ScadaDefaults)

    def all_breakers(self):
        """Every real (`EQUIP_CBR`) breaker across every voltage level,
        in station order (VL entry order, breaker order within each VL)
        -- the order breaker IEDs are named/numbered in, matching
        switchyard.scd's CB1..CB3 (V800) then CB4..CB6 (V230) convention.
        Isolating `EQUIP_DIS` disconnects (every breaker's own pair, plus
        each line/feeder tap's exit switch -- see
        generator/layouts/common.py) are deliberately excluded: they get
        no IED, no ConnectedAP, no GOOSE of their own, same as the
        transformer LV stub's own DIS outputs.
        """
        for vl in self.voltage_levels:
            for breaker in vl.breakers:
                if breaker.equip_type == EQUIP_CBR:
                    yield breaker

    def find_vl(self, vl_name: str) -> VoltageLevelBuild:
        for vl in self.voltage_levels:
            if vl.vl_name == vl_name:
                return vl
        raise KeyError(vl_name)
