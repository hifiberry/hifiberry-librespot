# librespot patches

Fixes applied on top of the librespot release checked out by `debian/rules`
(`LIBRESPOT_VERSION`), in file name order, until they are released upstream.
Each one is a `git format-patch` export, so its message says what it fixes and
why.

When `LIBRESPOT_VERSION` moves, drop the patches the new release already
contains, and check that the others still apply.
