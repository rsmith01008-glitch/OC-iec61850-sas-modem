"""Name validation/sanitization and sequential-address helpers.

`validate_ied_name` implements the REAL `tIEDName` restriction from the
vendored SCL2007B4 schema (`tools/scl-compiler/schema/SCL_BaseSimpleTypes.xsd`),
transcribed from its four `xs:pattern` facets (multiple pattern facets on
one restriction are OR'd together per XSD, not ANDed):

    [A-Za-z][0-9A-Za-z_]{0,2}          -- length 1-3
    [A-Za-z][0-9A-Za-z_]{4,63}         -- length 5-64
    [A-MO-Za-z][0-9A-Za-z_]{3}         -- length 4, not starting with N
    N[0-9A-Za-np-z_][0-9A-Za-z_]{2}    -- length 4, starting with N

(applies to `IED/@name` and `ConnectedAP/@iedName` alike -- every IED
name this tool produces or accepts is validated against it, not just
spot-checked, since a name that slips through only fails much later at
`--validate-xsd` with a far less useful error.)

Non-IED identifiers (VoltageLevel/Bay/ConnectivityNode/Tap names) are
only lightly constrained by real SCL (`tName` = non-empty
`xs:normalizedString`), but this tool's own `pathName` construction
joins segments with "/", so `sanitize_identifier` is deliberately
stricter than the schema requires: letters/digits/underscore only, first
character a letter or underscore -- matching every name already used in
scl/switchyard.scd (V800, BusA800, Diameter1, N1, Line1, Feed1, ...).
"""

import re

_LEN_1_3 = r"[A-Za-z][0-9A-Za-z_]{0,2}"
_LEN_5_64 = r"[A-Za-z][0-9A-Za-z_]{4,63}"
_LEN_4_NOT_N = r"[A-MO-Za-z][0-9A-Za-z_]{3}"
_LEN_4_N = r"N[0-9A-Za-np-z_][0-9A-Za-z_]{2}"
_IED_NAME_RE = re.compile(r"^(?:%s|%s|%s|%s)$" % (_LEN_1_3, _LEN_5_64, _LEN_4_NOT_N, _LEN_4_N))

_IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_IDENTIFIER_MAX_LEN = 64


class NameError_(ValueError):
    """Raised for a name that fails validation. Named with a trailing
    underscore only to avoid shadowing the builtin NameError."""


def validate_ied_name(name: str) -> None:
    """Raises NameError_ with a clear reason if `name` is not a valid
    tIEDName. Returns None (no coercion) -- callers ask the user again
    rather than silently mutating a name they typed.
    """
    if not isinstance(name, str) or not name:
        raise NameError_("IED name must be a non-empty string")
    if len(name) > 64:
        raise NameError_("IED name %r is %d characters, max is 64" % (name, len(name)))
    if not _IED_NAME_RE.match(name):
        raise NameError_(
            "IED name %r is not a valid SCL IED name -- must start with a "
            "letter, contain only letters/digits/underscore, no hyphens, "
            "1-64 characters (real SCL's tIEDName forbids hyphens: it's "
            "MMS-identifier rules, not a Lua-string 'IED-BRK1' style name)"
            % (name,)
        )


def validate_identifier(name: str) -> None:
    """Raises NameError_ for a VoltageLevel/Bay/ConnectivityNode/Tap name
    that isn't safe for this tool's pathName construction."""
    if not isinstance(name, str) or not name:
        raise NameError_("name must be a non-empty string")
    if len(name) > _IDENTIFIER_MAX_LEN:
        raise NameError_("name %r is %d characters, max is %d" % (name, len(name), _IDENTIFIER_MAX_LEN))
    if not _IDENTIFIER_RE.match(name):
        raise NameError_(
            "name %r must start with a letter or underscore and contain "
            "only letters, digits, and underscores (no spaces, slashes, or "
            "punctuation -- this becomes part of an SCL pathName)" % (name,)
        )


def sanitize_identifier(raw: str) -> str:
    """Best-effort coercion of free-typed wizard input into something
    validate_identifier() will accept: strip, replace runs of anything
    not [A-Za-z0-9_] with a single underscore, and prefix with "_" if the
    result would otherwise start with a digit. Does not guarantee
    validity by itself -- callers still run validate_identifier() on the
    result and re-prompt if it's somehow still empty.
    """
    cleaned = re.sub(r"[^A-Za-z0-9_]+", "_", raw.strip())
    cleaned = cleaned.strip("_") or cleaned
    if cleaned and cleaned[0].isdigit():
        cleaned = "_" + cleaned
    return cleaned


def mac_address(prefix: str, index: int) -> str:
    """`prefix` (e.g. "01-0C-CD-01-00-") + a 2-decimal-digit sequential
    octet -- decimal, not hex, matching switchyard.scd's exact
    "01-0C-CD-01-00-01".."01-0C-CD-01-00-06"/"...-20" values (a real MAC
    octet is technically hex, but this is a descriptive-only, entirely
    synthetic address in an OC-only namespace -- consistency with the
    existing worked example matters more here than hex correctness).
    """
    return "%s%02d" % (prefix, index)


def appid(base: int, index: int) -> str:
    """4-decimal-digit zero-padded sequential APPID, matching
    switchyard.scd's "0001".."0006"/"0020" -- decimal, not hex (the
    worked example's "0020" for a 20th/transformer address only reads
    correctly as decimal).
    """
    return "%04d" % (base + index - 1)
