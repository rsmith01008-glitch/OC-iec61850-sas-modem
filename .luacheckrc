-- luacheck config for OpenComputers/OpenOS Lua code. Declares the
-- component-model globals and OpenOS library globals this codebase uses,
-- so luacheck doesn't false-positive "undefined global" on every file.
std = "lua53"

globals = {
  "component", "computer", "event", "sides", "colors", "unicode",
  "os", "io", "table", "string", "math",
  -- rc.d service files define these as bare globals, invoked by `rc`.
  "start", "stop", "status", "restart",
}

-- Program/rc.d/library files are all standalone modules or scripts;
-- unused self-arguments and shadowing are common/idiomatic in this
-- codebase's small handler closures.
unused_args = false
allow_defined_top = true
