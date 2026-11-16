Zup
===

A extremely simple Zig+ZLS version manager. Do not use if you are not me.


Install
-------

~~~~
curl -fsSL https://raw.githubusercontent.com/sudo-rushil/zup/main/install.sh | bash
~~~~

This puts `zup` in `~/.zig/bin` and adds that directory to your `PATH`. Apple
Silicon macOS only, for now.


Versions
--------

zup keeps every installed version on disk, in `~/.zig/zup/<version>/`, with
`zig/zig` and `zls/zls` inside. There is no separate install step: `use`
downloads a version the first time you ask for it, then points
`~/.zig/bin/zig` and `~/.zig/bin/zls` at that version.

~~~~
zup use 0.17.0     # fetch if missing, then activate
zup use stable     # newest release in Zig's index, stored under its real version
zup list           # versions you can use
zup rm 0.17.0      # delete a version; links that pointed at it are removed
~~~~

`list` shows versions on disk, so it shows what `use` can activate without a
download.
