{
  description = "Home Manager module: a Claude Code Remote Control server per project directory";

  outputs = _: {
    homeModules.claude-remote-control = ./module.nix;
    homeModules.default = ./module.nix;
  };
}
