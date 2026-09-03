# `scl/switchyard.scd`

The single source of truth for this project's switchyard: an IEC 61850-6
(SCL2007B4) document describing a minimal 1½-breaker 800kV/230kV
switchyard -- two 3-breaker diameters, one power transformer, one
incoming line, one outgoing feeder -- plus every IED's communication,
protection, and reporting configuration. `tools/scl-compiler/` compiles
it into the `.cfg` files this project's runtime actually reads (checked
in as golden reference at `etc/generated/`); see that tool's own README
for the compiler's invocation and how it maps SCL onto our config.

This particular file was hand-authored as a worked example. For a *new*
station, use `tools/scl-generator/` instead of hand-writing SCL from
scratch -- an interactive wizard that turns layout/bay/voltage answers
into a `.scd` plus a one-line diagram.

## Topology

```
800kV: BusA800 --CB1-- N1(Line1 tap) --CB2-- N2(XFMR1 HV tap) --CB3-- BusB800   [Diameter1]
230kV: BusA230 --CB4-- N3(XFMR1 LV tap) --CB5-- N4(Feed1 tap)  --CB6-- BusB230  [Diameter2]
PowerTransformer XFMR1: TransformerWinding HV (Terminal @ N2), LV (Terminal @ N3)
```

This is the textbook-minimal 1½-breaker illustration: each diameter has
exactly 2 taps / 3 breakers (the "1.5" ratio is 3 breakers : 2 bays), and
the pattern is trivially repeated for a larger station -- add another
`<Bay>` with 3 more `<ConductingEquipment type="CBR">` and 2 more
`<ConnectivityNode>`s for each additional line/feeder/transformer
diameter, plus a matching breaker IED per new `CBRn`.

Isolating the transformer fully requires opening **both** breakers
bounding each of its taps -- CB2 and CB3 on the HV side (both touch N2),
CB4 and CB5 on the LV side (both touch N3) -- not just one per side. This
is why `XFMR1`'s differential trip reaches all four via `remoteTrips[]`
on those four breaker IEDs, not two -- one `remoteTrip[]` rule per phase
per breaker (`PDIF1A/B/C.Op`; see below), not one.

## One-line diagram

`tools/scl-compiler/` also derives the HMI's one-line diagram from this
file's real topology (`ConductingEquipment`/`Terminal`/`ConnectivityNode`
connectivity -- see that tool's README's "Diagram emission" section).
Two things worth knowing about how `switchyard.scd` in particular renders:

- **Zero disconnect symbols.** Every `ConductingEquipment` here is
  `type="CBR"` (a breaker) -- there is no `type="DIS"` equipment anywhere
  in this file, so the compiled diagram has an empty `disconnects[]`.
  Disconnects are drawn as static/neutral tick symbols when present (no
  live status data exists for them anywhere in this codebase); a `.scd`
  produced by `tools/scl-generator/` with isolating disconnects added
  (`generator/layouts/common.py`'s `add_isolating_disconnects`) will show
  them.
- **Line/feeder tap glyphs need an extra hint.** N1 (`Line1` tap) and N4
  (`Feed1` tap) render with a neutral "unknown" tap glyph here, because
  this file predates the `ConnectivityNode/Private/oc:tap kind="line"|
  "feeder"` extension `tools/scl-compiler/scl/private_ext.py` reads --
  tap kind is never guessed from `desc` text (same "not guessed from
  content" rule as every other `Private` extension in this project).
  Adding `<Private type="oc-iec61850-sas"><oc:tap kind="line"/></Private>`
  under N1's `ConnectivityNode` (and `kind="feeder"` under N4's) would
  enable the filled/hollow-triangle glyph distinction for this file, same
  as `tools/scl-generator/`-produced `.scd`s already get via their own
  writer convention. Transformer taps (N2/N3) need no such hint -- they're
  always identified structurally, from `PowerTransformer/
  TransformerWinding/Terminal/@connectivityNode`.

## IEDs

- `CB1`..`CB6`: one per breaker. Own `XCBR1.Pos`/`PosCtl` (redstone),
  local `MMXU1.AmpA/B/C`/`VolAB/BC/CA` (6 independent Create:EE meters --
  one per phase current, one per phase-to-phase voltage; a 3-phase
  circuit needs 3 of each, never one meter standing in for all three), 3
  real-trip `PTOC1A/B/C` overcurrent schemes (one per phase, matching
  real numerical relays' separate 50/51-A/B/C elements -- a single-phase-
  to-ground fault only elevates one phase's current), a GOOSE-published
  `XCBR1.Pos`, and an `rcbStatus1` report. `CB2`/`CB3`/`CB4`/`CB5`
  additionally carry 3 `remoteTrip[]` rules (one per `XFMR1` phase's
  `PDIF1A/B/C.Op` -- any single phase's differential trip must open the
  breaker). `CB1`/`CB2` and `CB4`/`CB5` each carry one illustrative
  `interlock[]` (not a complete substation interlock philosophy -- just
  proof the cross-IED mechanism works).
- `XFMR1`: dedicated transformer-protection IED. No breaker of its own --
  its job needs simultaneous HV+LV CT readings (`MMXU1.AmpA/B/C`/
  `MMXU2.AmpA/B/C` -- current only, no voltage, unlike a breaker's MMXU),
  which only makes sense co-located on one IED (this codebase's "one IED
  owns its own equipment" pattern, extended here to "protection reads only
  its own IED's meters"). Runs 3 real-trip `PDIF1A/B/C` schemes
  (magnitude-restrained differential, one per phase -- each compares that
  phase's own HV CT against that same phase's own LV CT; pdif.lua has no
  vector/phase-shift compensation, so pairing anything other than the
  same phase on both sides would risk a false trip) and an inert `PDIS1`
  (distance -- config-modeled only, see `sas/protection/pdis.lua`'s
  header for why: no phase-angle data source). Also carries a bare
  `RDRE1` (disturbance recorder) LN -- SCL data-model completeness only,
  not wired to any event-capture code.
- `SCADA1` (`IED type="SCADA"`): the SCADA concentrator, itself modeled as
  an `IED` per this project's `Private` conventions (see
  `tools/scl-compiler/scl/mapping.py`'s `map_scada`). `ieds[]` is derived
  automatically from every other IED sharing its `SubNetwork`.

## What's real vs. descriptive-only here

- **Real / compiled / enforced**: topology-derived point types (CDC
  resolution), GOOSE dataset membership (`goose=true` per point),
  interlocks, remote trips, PTOC/PDIF trip logic, ReportControl/TrgOps
  filtering.
- **Descriptive-only** (present in the SCL for schema-completeness and
  human documentation, not consumed by the compiler or enforced by any
  runtime code): `GSE/Address` MAC-Address/APPID/VLAN-ID/VLAN-PRIORITY
  (the built-in OpenComputers modem transport underneath -- see
  `sas/proto/netmsg.lua` -- has no 802.1Q/priority-queue concept), the
  `SampledValueControl`/`SMV` on `XFMR1`
  (no process-bus streaming transport exists), `GSEControl@securityEnable`
  (always `"None"` -- no GOOSE authentication/encryption is implemented),
  and `RDRE1` (no oscillography capture exists).
- **Out of scope, not modeled at all**: synchrocheck (`RSYN`) -- same
  hardware limitation as `PDIS1` (Create:EE's `getValue()` gives magnitude
  only, no phase angle, and a synchrocheck fundamentally needs to compare
  phase across an open breaker); IEC 61850's "Sim"/test-mode flag and MMS
  file-transfer services -- both are runtime protocol behaviors in real
  61850, not SCL configuration items, and neither exists in this
  project's MMS-lite protocol.
