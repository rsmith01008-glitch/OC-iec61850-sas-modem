#!/usr/bin/env python3
"""SCL generator: walks the user through substation layout/bay/voltage
questions and writes an IEC 61850-6 `.scd` file plus a one-line diagram
SVG. See tools/scl-generator/README.md for the full workflow; see
tools/scl-compiler/README.md for what happens to the `.scd` this
produces (it does not run on OC hardware either).

Usage:
    python3 tools/scl-generator/scl_generate.py [--out-dir scl/]
    python3 tools/scl-generator/scl_generate.py --gui [--port 8787] [--out-dir scl/]

Without `--gui`, this is the original interactive `input()` wizard.
`--gui` instead starts a local (127.0.0.1-only) web server with the same
set of questions as a form, and a one-line diagram preview that updates
live as you change layout/tap options -- opens automatically in your
browser.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir", default="scl",
        help="Directory to write the generated .scd and .svg into (default: scl/)",
    )
    parser.add_argument(
        "--gui", action="store_true",
        help="Start the local web GUI instead of the interactive terminal wizard.",
    )
    parser.add_argument(
        "--port", type=int, default=8787,
        help="Port for --gui's local web server (default: 8787).",
    )
    args = parser.parse_args(argv)

    if args.gui:
        from generator.webapp.server import run as run_gui
        run_gui(Path(args.out_dir), args.port)
        return 0

    from generator.wizard import run_wizard
    from generator.output import write_station

    station = run_wizard()
    return write_station(station, Path(args.out_dir))


if __name__ == "__main__":
    sys.exit(main())
