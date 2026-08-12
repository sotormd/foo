let
  _option = {
    scope = "foo";
  };
in
{
  schema = {
    outputs = {
      inherit _option;
      description = ''
        Additional outputs to be available under `build`. The following are
        always included:

        - `kernel`
        - `initrd`
        - `uki`
        - `toplevel`

        Type: Attrs 
      '';
    };
    toplevel = {
      init = {
        inherit _option;
        description = ''
          File to run as PID 1 (init). This should include everything required
          to set up a system. This is added to toplevel under `init` and is
          availabe as `$BOOTED_CLOSURE/init` in the initrd.

          Type: Path
        '';
      };
      paths = {
        inherit _option;
        description = ''
          Paths to link under the system closure, this could be used for
          things like `etc` or `sw`, as needed. The following are always
          included:

          - `init`, the PID 1 (init)

          Type: List of attrs with `source` (path) and `name` (string).
        '';
      };
    };
    kernel = {
      packages = {
        inherit _option;
        description = ''
          Kernel packages to use.

          Example: `pkgs.linuxPackages_latest`

          Type: Package
        '';
      };
      params = {
        inherit _option;
        description = ''
          Parameters to pass to the Linux kernel.

          Example: `[ "console=ttyS0" ]`

          Type: List of strings
        '';
      };
    };
    initrd = {
      modules = {
        inherit _option;
        description = ''
          List of kernel modules to be available in initrd.

          Type: List of strings
        '';
      };
      interpreter = {
        inherit _option;
        description = ''
          Path to POSIX-compatible shebang interpreter to use for initrd.
          This is sourced from `/bin`.

          Example: `"/bin/sh"`

          Type: String
        '';
      };
      packages = {
        inherit _option;
        description = ''
          Pacakges to add to `/bin` in initrd. For example, unlocking
          luks devices may require `cryptsetup`. A shell interpreter is also
          required.

          Example: `[ pkgs.busybox ]`

          Type: List of packages
        '';
      };
      commands = {
        inherit _option;
        description = ''
          Commands to run in initrd. Tasks such as mounting `/nix`
          and other important directories should be done here. Should end with
          `switch_root` to the real root. The initrd always exposes closure as
          `$BOOTED_CLOSURE`. The init is available as `$BOOTED_CLOSURE/init`.

          Type: String
        '';
      };
    };
  };
}
