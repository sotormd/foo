# foo

A simple Nix-based operating system ~ a small set of primitives for constructing
Linux systems with Nix.

foo, pronounced /fuː/, is an operating system designed around
[Nix](https://github.com/nixos/nix) and
[Nixpkgs](https://github.com/nixos/nixpkgs).

foo does not provide a module system. Instead, it exposes a single function,
`buildFoo`, which takes a configuration attrset containing a set of well-known
attributes. Composition and merging are intentionally left to the caller and can
be implemented using normal Nix expressions. Furthermore, foo has no concept of
"activation" or "generations", those have to be implemented separately (see the
example system).

foo is mainly intended for my own personal use.

The configuration options provided by foo are intentionally primitive:

1. Kernel packages.
2. Kernel modules to include in the initrd.
3. Commands to run in the initrd.
4. Commands to run as init (PID 1).
5. Paths and artifacts to include in the system closure.

Anything beyond these primitives is built on top of foo.

foo produces a UKI containing the provided kernel and initrd, and exposes a
toplevel closure containing the init script and any additional artifacts. By
default, only the init script is included. The foo build outputs are:

1. Kernel, `build.kernel`
2. Initrd, `build.initrd`
3. UKI, `build.uki`
4. Toplevel, `build.toplevel`

Disk images and any other outputs can be built on top of foo, like the
`build.diskImage` in the example.

To produce an options doc (markdown):

```bash
nix eval -f example.nix optionsMd --raw
```

This is also available in [options.md](./options.md). Options are not validated
or checked.

## Example system

An example is provided which uses foo to build a minimal system with:

1. Activation and system closure with familiar `sw` and `etc`
2. `/etc` as an overlay with an immutable EROFS lower and writable tmpfs upper
3. Impermanence (tmpfs) with persistent `/nix`, `/var`, `/home`
4. Multi-user Nix with read-only `/nix/store` and `nix-daemon` in a private
   mount namespace
5. System generations using Nix Profiles, and switching with `foo-rebuild`
6. Basic networking and SSL certificates
7. Disk image with `systemd-repart` and `systemd-boot` bootloader

To build the example:

```bash
nix build -f example.nix build.diskImage
```

This can be booted with QEMU.

![example](./example.png)
