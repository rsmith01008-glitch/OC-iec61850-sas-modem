# SCL compiler

Offline, build-time compiler: takes an authored IEC 61850-6 SCL document
(`scl/switchyard.scd`) and produces the `sas-ied-<name>.cfg`/`sas-scada.cfg`
Lua-table-literal files this project's runtime (`sas/ied/engine.lua`,
`sas/scada/engine.lua`) actually reads. It does **not** run on OC
hardware — it's plain Python 3 + `lxml`, run once at deployment/design
time on a real computer; the generated `.cfg` files are what gets copied
onto the in-game OC computers.

Why SCL at all: real IEC 61850 engineering describes a substation once, in
one standards-based file, covering single-line topology, GOOSE/report
control blocks, and protection function instances together. This compiler
lets that stay true for us too — `scl/switchyard.scd` is the single source
of truth, and `etc/generated/*.cfg` is disposable, regenerable output.

## Install

```
pip3 install -r tools/scl-compiler/requirements.txt
```

## Compile

```
python3 tools/scl-compiler/scl_compile.py \
  --scd scl/switchyard.scd --out-dir etc/generated/ \
  --validate-xsd
```

Writes one `sas-ied-<iedname>.cfg` per non-SCADA `<IED>` element and one
`sas-scada.cfg` for the `<IED type="SCADA">` element (there must be
exactly one). `--validate-xsd` checks `scl/switchyard.scd` against the
vendored schema (`schema/SCL.xsd`) before mapping — catches malformed SCL
early, with real line numbers, rather than an obscure mapping error.

A deployer then copies `etc/generated/sas-ied-<name>.cfg` /
`sas-scada.cfg` onto the matching in-game OC computer as
`/etc/sas-ied.cfg` / `/etc/sas-scada.cfg` — that last copy step stays
manual, since OC computers don't run Python.

## CI / golden-file check

```
python3 tools/scl-compiler/scl_compile.py \
  --scd scl/switchyard.scd --out-dir etc/generated/ --check
```

Compiles in memory and diffs against whatever's already checked into
`etc/generated/`, without writing anything. Nonzero exit + a unified diff
means the checked-in output is stale — someone edited `scl/switchyard.scd`
(or this compiler) without regenerating. Also flags any `etc/generated/
*.cfg` with no corresponding IED anymore (a renamed/removed IED left a
stale file behind).

## Tests

```
python3 -m unittest discover -s tools/scl-compiler/tests -v
```

Plain `unittest` (not pytest — this environment doesn't have it
installed, and there's no reason to add a second test-runner dependency
for a Python-side test suite this small). `tests/fixtures/single_breaker.scd`
is a minimal, schema-valid, hand-authored SCL document exercising every
mapping path (redstone DPS/DPC, meter MV, GOOSE dataset membership,
interlock, PTOC, ReportControl/TrgOps, and the SCADA `ieds[]` derivation)
without pulling in the full worked example.

## How SCL maps to `.cfg` (see `scl/mapping.py`'s module docstring for the
exact schema element/attribute names this was cross-checked against)

- **Substation/VoltageLevel/Bay/ConductingEquipment/Terminal/ConnectivityNode
  are NOT read by this compiler.** Nothing in `sas/model.lua` or the
  runtime engines has a bay/diameter/topology concept — that part of SCL
  stays purely descriptive (the human-facing single-line diagram), not
  something the compiler consumes. There is no `--lint-topology` flag
  (would need genuine consumers of that data to be worth building).
- One `<IED>` → one LDevice, asserted (errors otherwise — matches
  `sas/model.lua`'s hardcoded single-LDevice-per-IED assumption).
- Points: every `DOI` under every `LN`/`LN0` in that LDevice, with its CDC
  resolved via the real chain `LN/@lnType → LNodeType[@id] →
  DO[@name]/@type → DOType[@id]/@cdc`, mapped `SPS/DPS/SPC/DPC/MV` → our
  point types 1:1 (anything else is a hard compiler error — this
  compiler does not attempt to support CDCs our runtime has no concept
  of). Per-point I/O binding, deadband, and SBO timeout come from
  `DOI/Private/oc:point`. A point's `goose` publish flag comes from real
  SCL, not `Private`: true iff that `LN.doName` appears in the
  `DataSet/FCDA[]` referenced by the LDevice's `GSEControl@datSet`.
- GOOSE transport (`goose.port` -- the OpenComputers modem port every IED
  broadcasts/listens for GOOSE on; the port number itself is the "group",
  so there's no separate group address to resolve): resolved once per IED
  via its `SubNetwork/Private/oc:transport`, joined to that IED's own
  `GSEControl` through the real `GSEControl@name`+`ldInst` ↔
  `ConnectedAP/GSE@cbName`+`@ldInst` relationship. `heartbeatSec` comes
  from `GSE/MaxTime`; `burstIntervalsSec` comes from
  `GSE/Private/oc:gooseTiming` when present, else a geometric ladder
  derived from `GSE/MinTime`.
- `ReportControl`/`DataSet`/`TrgOps` → `reports[]`, with `TrgOps/period`
  needing a `ReportControl/Private/oc:reportSettings/@periodSec` (real
  SCL's `TrgOps/period` is a boolean; the interval length has no standard
  61850 home).
- `Private type="oc-iec61850-sas"` (`xmlns:oc="urn:oc-iec61850-sas:v1"`)
  carries everything else this codebase needs that real SCL has no home
  for: redstone/meter I/O bindings, SBO timeouts, `interlocks[]`,
  `remoteTrips[]`, `protection[]` scheme parameters, per-IED tick/
  integrity/stale-after settings, and (on the SCADA IED) historian config
  and alarm definitions. See `scl/private_ext.py`'s module docstring and
  `tests/fixtures/single_breaker.scd` for the concrete element shapes.

## A real-SCL constraint worth knowing before authoring `scl/switchyard.scd`

`tIEDName` (the real SCL type for `IED/@name` and `ConnectedAP/@iedName`)
does not allow hyphens — it's restricted to `[A-Za-z][0-9A-Za-z_]*`
(MMS-identifier rules). This project's hand-written `etc/sas-ied.cfg.example`
uses hyphenated names like `"IED-BRK1"` purely as a Lua string in our own
MMS-lite protocol, which has no such constraint — but a compiler-generated
IED name comes directly from `IED/@name`, so `scl/switchyard.scd` (and
this compiler's own test fixture) use hyphen-free names instead
(`BRK1`, `XFMR1`, `SCADA1`, ...).
