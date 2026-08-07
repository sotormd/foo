`init.commands`

Commands to run in PID 1 (init). This should include everything
required to set up a system, including calling any "activation".

Type: String 

---

`initrd.commands`

Commands to run in initrd. Tasks such as mounting `/nix`
and other important directories should be done here. Should end with
`switch_root` to the real root. The initrd always exposes closure as
`$BOOTED_CLOSURE`. The init is available as `$BOOTED_CLOSURE/init`.

Type: String

---

`initrd.interpreter`

Path to POSIX-compatible shebang interpreter to use for initrd.
This is sourced from `/bin`.

Example: `"/bin/sh"`

Type: String

---

`initrd.modules`

List of kernel modules to be available in initrd.

Type: List of strings

---

`initrd.packages`

Pacakges to add to `/bin` in initrd. For example, unlocking
luks devices may require `cryptsetup`. A shell interpreter is also
required.

Example: `[ pkgs.busybox ]`

Type: List of packages

---

`kernel.packages`

Kernel packages to use.

Example: `pkgs.linuxPackages_latest`

Type: Package

---

`kernel.params`

Parameters to pass to the Linux kernel.

Example: `[ "console=ttyS0" ]`

Type: List of strings

---

`toplevel.paths`

Paths to link under `$closure`, this could be used for
things like `$closure/etc` or `$closure/sw`, as needed.
`$closure/init` is always included.

Type: List of attrs with `source` (path) and `name` (string).

