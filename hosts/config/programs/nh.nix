{
  programs.nh = {
    enable = true;
    flake = "/home/jager/.yuki";
    clean = {
      enable = true;
      extraArgs = "--keep-since 1w";
    };
  };
}
