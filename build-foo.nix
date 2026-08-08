let
  # contains
  # foo.version
  # foo.options ->  valid values, does no checking
  # foo.builder ->  combines options with provided config and pkgs
  #                 to produce final targets, like toplevel
  foo-default = import ./foo;

  buildFoo =
    {
      config,
      pkgs,
      foo ? foo-default,
    }:
    let
      cfgver = config.version or "<version missing>";
    in
    if cfgver != foo.version then
      throw "version mismatch: expected ${foo.version}, got ${cfgver}"
    else
      {
        inherit (foo) version;

        # contains all the targets
        build = foo.builder { inherit config pkgs; };

        # options doc
        optionsMd =
          let
            inherit (pkgs) lib;

            walk =
              path: attrs:
              lib.concatMapStringsSep "---\n\n" (
                name:
                let
                  value = attrs.${name};
                  fullPath = if path == "" then name else "${path}.${name}";
                in
                if lib.isAttrs value && value ? _option then
                  ''
                    `${fullPath}`

                    ${value.description}
                  ''
                else if lib.isAttrs value then
                  walk fullPath value
                else
                  ""
              ) (lib.attrNames attrs);

          in
          walk "" foo.options.schema;
      };
in
buildFoo
