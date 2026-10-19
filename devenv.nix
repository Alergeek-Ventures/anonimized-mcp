{ pkgs, config, ... }:

{
  packages = with pkgs; [
    beam29Packages.elixir_1_20
    beam29Packages.erlang
    postgresql
    podman
    podman-compose
    jq
    gcc
    gnumake
    # Ortex builds its ONNX Runtime NIF from source.
    cargo
    rustc
    glibcLocales
    inotify-tools
  ];

  env.MIX_ARCHIVES = "${config.devenv.state}/mix-archives";
  env.MIX_HOME = "${config.devenv.state}/mix";
  env.HEX_HOME = "${config.devenv.state}/hex";

  enterShell = ''
    mix local.hex --force --if-missing >/dev/null
    mix local.rebar --force --if-missing >/dev/null
  '';
}
