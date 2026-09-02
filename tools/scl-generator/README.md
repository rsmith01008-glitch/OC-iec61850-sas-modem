# SCL generator

An interactive Python wizard that turns answers about substation layout
into an IEC 61850-6 SCL `.scd` file, plus a one-line diagram (SVG) --
so a new switchyard never requires hand-writing SCL's dense XML naming
conventions and non-obvious schema-ordering rules by hand. This is the
companion to `tools/scl-compiler/` (which *compiles* a `.scd` into this
project's `sas-ied.cfg`/`sas-scada.cfg` format): the generator *produces*
a `.scd`, the compiler *consumes* one. Offline, build-time only, never
runs on OC hardware -- same as the compiler.

`scl/switchyard.scd` (the existing worked example) stays hand-authored;
use this tool for a *new* station, or as a starting point you then
hand-edit -- the generated `.scd` is a normal SCL file, not a
compiler-owned artifact you must regenerate on every change.

**Architecture note:** a transformer taps into exactly *one* real
switchyard (its HV side, built by whichever layout you chose for that
voltage level, same as any line/feeder tap); its LV side is always a
small, fixed, disconnect-only output stub -- never a second
independently-laid-out switchyard. This matches real substation
practice: redundant double-bus switching infrastructure (1½-breaker,
ring bus, etc.) belongs on the transmission side, shared by multiple
lines and any transformers tapping it; a transformer's LV side doesn't
typically get a matching double-bus arrangement at the *same* site,
because the next step-down happens closer to the point of use, at a
different substation. It also keeps transformer differential protection
(PDIF) honest: that zone is bounded by the transformer's HV-side CT (at
the breaker(s) bounding its HV tap) and its own LV-side CT, right at its
output -- not spanning a second switchyard. See
`generator/layouts/transformer_lv.py`'s header for the full reasoning.
(`scl/switchyard.scd` itself still predates this fix and uses the older
two-switchyard-joined-by-transformer shape -- it's hand-authored and out
of this tool's scope, so it hasn't been updated to match.)

**Isolating disconnects are real modeled devices, not diagram
decoration:** every breaker in every switchyard (including a
main-and-transfer layout's tie breaker) gets a real
`ConductingEquipment type="DIS"` on each of its 2 sides, and every
line/feeder tap gets one more `DIS` on its own outward side before it
actually leaves the station -- 3 breakers x 2 + up to 2 tap exits = up
to 8 disconnects per breaker-and-half diameter, matching the reference
one-line's "Disc. switch -> Circuit breaker -> Line" pattern exactly.
Like the transformer LV stub's own outputs, these disconnects get no
IED, no `ConnectedAP`, no GOOSE -- descriptive topology only, matching
real "manual/local, not remotely monitored" disconnect practice. See
`generator/layouts/common.py`'s `add_isolating_disconnects`/
`add_exit_disconnect` for how every layout builder gets this uniformly,
with no per-layout special-casing.

## Install

```
pip3 install -r tools/scl-generator/requirements.txt
```

(Only dependency: `lxml`, reused from `tools/scl-compiler/` for
`--validate-xsd` and pretty-printing.)

## Run

```
python3 tools/scl-generator/scl_generate.py [--out-dir scl/]
```

Pure interactive `input()` session -- no CLI flags or answers file in
this version. Every prompt with a default shown in `[brackets]` accepts
a blank line to take it, so a minimal single-diameter station is a short
session. Writes `<substation>.scd` and `<substation>-oneline.svg` into
`--out-dir` (default `scl/`), XSD-validates the `.scd` against the
vendored schema, and offers to compile it immediately via the real
`tools/scl-compiler/scl_compile.py`.

## Example session (abridged)

One 1½-breaker 800kV switchyard with a transformer tapping one diameter
-- its LV side is a simple 230kV disconnect-gated output, asked inline
the moment the tap is marked "transformer," not a second switchyard:

```
=== OC-IEC61850-SAS SCL generator ===
Substation name: Switchyard1

--- Voltage level 1 ---
Voltage level name [V1]: V800
Nominal kV: 800
Layout kind for this voltage level?
  *1) 1½-breaker
   2) Single/main bus
   3) Main-and-transfer bus
   4) Ring bus
Choice [1]:
  Tap 1 name (blank to finish this voltage level): Line1
  Tap kind? Choice [1]:                  # 1 = line
  Tap 2 name (blank to finish this voltage level): XfmrHV
  Tap kind? Choice [1]: 3                # 3 = transformer
    -- this transformer's LV side (a simple output, not another switchyard) --
    Transformer name [XFMR1]:
    LV nominal kV: 230
    Number of simple LV outputs (disconnect-gated exits) [1]:
      Output 1 name [Feed1]:
      Output 1 kind? Choice [1]:         # 1 = feeder
  Tap 3 name (blank to finish this voltage level): Line2
  Tap kind? Choice [1]:
  Tap 4 name (blank to finish this voltage level):
  XFMR1: HV scale 1.000, LV scale 3.478
Add another voltage level? [y/N]:

--- Protection defaults (applied to every breaker/transformer) ---
PTOC pickup (amps) [1.2]:
PTOC curve? Choice [1]:                  # IEC_VERY_INVERSE
...

--- Summary ---
Substation: Switchyard1
  V800: 800 kV, breaker_and_half, 4 tap(s), 6 breaker(s), 15 disconnect(s)
Transformers: 1
  XFMR1: HV tap in V800 (800kV) -> LV 230kV, 1 simple output(s)
Total breaker IEDs: 6
Total isolating disconnects (descriptive only, no IED): 15
SCADA IED: SCADA1

Generate now? [Y/n]:
wrote scl/switchyard1.scd
wrote scl/switchyard1-oneline.svg
XSD validation: OK

Compile now via tools/scl-compiler? [Y/n]:
Compile output directory [etc/generated]:
wrote etc/generated/sas-ied-cb1.cfg
...
```

## What the wizard asks, in order

1. Substation name.
2. **Per voltage level** (repeat until done): name, kV, layout kind (see
   below), then a **tap loop** (name + line/feeder/transformer kind,
   repeat until blank). Marking a tap "transformer" immediately asks a
   few nested questions right there -- transformer name, LV kV, and one
   or more simple LV outputs (name + line/feeder kind) -- there is no
   separate "Transformers" step afterward, since a transformer's LV side
   is never paired up with another voltage level's tap (see the
   Architecture note above). The whole voltage level (taps + any inline
   transformer LV specs) is validated and built immediately on
   finishing, so a bad tap count (see Scoping decisions) is caught and
   re-asked right away, not at the very end.
3. Protection defaults (PTOC pickup/curve/time-multiplier-or-definite-
   time/reset, PDIF min-pickup/restraint-slope) -- asked **once** for
   the whole station, not per breaker/transformer. The differential-
   protection turns-ratio `scale` is always computed automatically
   (`HV_kV / LV_kV`) -- never asked.
4. GOOSE/network defaults (broadcast port, MAC/APPID/VLAN, GOOSE timing).
5. IED settings defaults (tick interval, integrity, GOOSE stale-after,
   ports).
6. SCADA settings (IED name, historian, auto-generated alarms).
7. A summary, then final confirmation before anything is written.

## Auto-derived, not asked

- **Remote trips**: every transformer's differential protection (one
  `remoteTrip[]` rule per phase, `PDIF1A/B/C.Op`) automatically trips
  every breaker bounding its HV tap --
  mechanically derived from the topology graph, not a judgment call
  (`generator/derive.py`'s `remote_trips_for`). "Bounding" walks straight
  through any isolating disconnects to find the real breaker on each
  side (`generator/layouts/common.py`'s `breakers_bounding`) -- a manual
  disconnect never changes which breaker actually has to open to clear a
  fault, so its presence never changes remote-trip/interlock derivation.
  The LV side is deliberately never considered: tripping the HV-side
  breaker(s) fully de-energizes the transformer, and the LV outputs are
  plain `DIS` disconnects with no IED of their own to receive a remote
  trip in the first place.
- **Illustrative interlocks**: one mutual interlock pair per diameter/
  ring junction (matching `scl/switchyard.scd`'s one-per-diameter
  pattern) -- a placeholder proving the cross-IED mechanism works, *not*
  a real site-specific interlock philosophy. Single-bus and
  main-and-transfer layouts never produce any (see below), and neither
  does a transformer's LV stub -- every LV output is bounded by exactly
  one `DIS`, never two breakers, so it can never qualify as a junction.

## Scoping decisions

- **Four supported layout kinds**: 1½-breaker, single/main bus,
  main-and-transfer bus, ring bus. The original request also mentioned
  "low rise" and "in-line," which aren't standard electrical-topology
  names and weren't clarified further when asked -- this is a documented
  scoping decision, not a silent drop. Real "low/high profile"
  substation design is a civil/structural-height choice, not something
  SCL's `Substation`/`Bay`/`ConductingEquipment` model represents, so
  there's no separate topology to add for it here.
- **1½-breaker requires an even tap count** (3 breakers : 2 bays per
  diameter) -- an odd count is a hard error, not silently padded or
  dropped.
- **Ring bus requires at least 3 taps** to close a sensible loop.
- **Main-and-transfer does not model the per-bay transfer-bus bypass
  disconnect** that gives this layout its real maintenance-switching
  capability in an actual substation -- only the transfer bus rail and
  one tie breaker are represented, for topological/diagram fidelity to
  the layout's *name*. This is a different, specific disconnect from the
  generic isolating ones every breaker gets (see above) -- it's the
  extra bypass path around each tap breaker that lets a tap stay in
  service while its own breaker is pulled for maintenance, and it's the
  one piece of switching this layout is scoped out of. Consequence: a
  transformer landing on a main-and-transfer bay is bounded by only its
  one main breaker (not a bug -- see
  `generator/layouts/main_and_transfer.py`'s header).
- **Illustrative interlocks never appear on single-bus or
  main-and-transfer** layouts, at any tap count -- every tap in those
  two layouts has exactly one bounding breaker by construction, and only
  a tap with *exactly two* bounding breakers ever qualifies (see
  `generator/derive.py`'s `illustrative_interlocks` docstring for the
  exact rule and why it generalizes cleanly across all four layouts with
  no per-layout branching).
- **The diagram is schematic, not IEC 60617-symbol-library-exact** --
  not to scale, coordinates chosen for legibility, not standards
  compliance. A 1½-breaker diameter is drawn as ONE vertical string
  between the two buses (Bus1 -- CB_a -- tap0 -- CB_mid -- tap1 -- CB_b
  -- Bus2, each tap branching sideways between its two neighboring
  breakers), matching the reference one-line's single-string diameter --
  not two separate columns joined by a horizontal jumper, which visually
  read as if each tap attached to CB_mid instead of to its own bus-side
  breaker (see `generator/diagram/draw_breaker_and_half.py`'s header).
  Every transformer's symbol and LV output fan is drawn in
  one shared horizontal band below the bottom of all real switchyard
  strips (never as a second strip of its own) -- if a transformer's HV
  tap lives in a strip above another real strip, its connector is simply
  a longer vertical line down to that shared band, and multiple
  transformers close together in x are not collision-avoided beyond
  that (see `generator/diagram/draw_transformer.py`'s header).
- **No CLI-flag/answers-file scripting mode in this version** -- pure
  interactive `input()` only.

## Output files

- `<substation>.scd` -- the generated SCL document. A normal file you
  may hand-edit afterward; re-running the wizard always starts fresh, it
  never merges into an existing `.scd`.
- `<substation>-oneline.svg` -- the one-line diagram, viewable in any
  browser.

Both existing-file overwrite prompts, the XSD validation step, and the
optional immediate compile all reuse `tools/scl-compiler/` directly
(`scl.validate.validate_xsd`, `scl_compile.compile_scd`) rather than
reimplementing any of it.

## Testing

```
python3 -m unittest discover -s tools/scl-generator/tests -v
```

Plain `unittest`, matching `tools/scl-compiler/tests`' own convention
(no pytest in this environment). The topology/layout/derivation math
(`generator/topology.py`, `generator/layouts/*.py`, `generator/derive.py`)
and the diagram's coordinate math (`generator/diagram/layout_geometry.py`)
are pure Python with no XML or `input()` dependency, so they're
genuinely unit-tested with exact terminal-identity/breaker-count
assertions, not just smoke-checked. `tests/test_scl_writer.py` is the
strongest correctness signal: it builds `Station` objects directly (no
`input()`), then runs the generated SCL through the **real**
`tools/scl-compiler/scl/validate.py`'s `validate_xsd()` and the **real**
`tools/scl-compiler/scl_compile.py`'s `compile_scd()` -- proving
generated output isn't just schema-valid but actually compiles cleanly
through the existing pipeline, directly parallel to how
`scl/switchyard.scd` itself was verified.
