# foo

A simple Nix-based operating system.

foo, pronounced /fuː/, is an operating system designed around
[Nix](https://github.com/nixos/nix) and
[Nixpkgs](https://github.com/nixos/nixpkgs). It provides a small set of
primitives for constructing Linux systems with Nix. A full example system
[foobar](#foobar) is also provided.

foo is mainly intended for my own personal use.

foo does not provide a module system. Instead, it exposes a single function,
`buildFoo`, which takes a configuration attrset. Composition and merging are
intentionally left to the caller and can be implemented using normal Nix
expressions.

The configuration options provided by foo are intentionally primitive:

1. Kernel packages.
2. Kernel modules to include in the initrd.
3. Commands to run in the initrd.
4. Commands to run as init (PID 1).
5. Paths and artifacts to include in the system closure.

Anything beyond these primitives has to be built on top of foo. For example, foo
has no concept of "activation" or system "generations", but the
[foobar](#foobar) example system adds these features.

foo produces a UKI containing the provided kernel and initrd, and exposes a
toplevel closure containing the init script and any additional artifacts. By
default, only the init script is included. The foo build outputs are:

1. Kernel, `build.kernel`
2. Initrd, `build.initrd`
3. UKI, `build.uki`
4. Toplevel, `build.toplevel`

Additional build outputs can be added using the `outputs` option. For example,
foo has no "disk image" output, but the [foobar](#foobar) example system adds
this output.

To produce an options doc (markdown):

```bash
nix eval -f foo optionsMd --raw
```

This is also available in [options.md](./options.md). Options are not validated
or checked.

# foobar

An example system, "foobar", is provided which uses foo to build a minimal
system with:

1. Activation and system closure with familiar `sw` and `etc`
2. `/etc` as an overlay with an immutable erofs lower and writable tmpfs upper
3. Impermanence (tmpfs) with persistent `/nix`, `/var`, `/home`
4. Multi-user Nix with read-only `/nix/store` and `nix-daemon` in a private
   mount namespace
5. System generations using Nix Profiles, and switching with `foobar-rebuild`
6. Basic networking and SSL certificates
7. Disk image with `systemd-repart` and `systemd-boot` bootloader

To build the example:

```bash
nix build -f foobar build.diskImage
```

This can be booted with QEMU.
