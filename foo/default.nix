let
  # contains
  # foo.version
  # foo.options ->  valid values, does no checking
  # foo.builder ->  combines options with provided config and pkgs
  #                 to produce final outputs, like toplevel
  foo-default = {
    version = "0.0.1";
    options = import ./options.nix;
    builder = import ./builder.nix;
  };

  buildFoo =
    {
      config ? null,
      pkgs ? null,
      foo ? foo-default,
    }:
    let
      cfgver = config.version or "<version missing>";
    in
    if config != null && cfgver != foo.version then
      throw "version mismatch: expected ${foo.version}, got ${cfgver}"
    else
      {
        inherit (foo) version;

        # contains all the outputs
        build = foo.builder { inherit config pkgs; };

        optionsMd =
          let
            walk =
              path: attrs:
              builtins.concatStringsSep "---\n\n" (
                map (
                  name:
                  let
                    value = attrs.${name};
                    fullPath = if path == "" then name else "${path}.${name}";
                  in
                  if builtins.isAttrs value && value ? _option then
                    ''
                      `${fullPath}`

                      ${value.description}
                    ''
                  else if builtins.isAttrs value then
                    walk fullPath value
                  else
                    ""
                ) (builtins.attrNames attrs)
              );
          in
          walk "" foo.options.schema;

      };
in
buildFoo
