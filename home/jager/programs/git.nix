{
  pkgs,
  config,
  ...
}: {
  programs.git = {
    enable = true;
    package = pkgs.gitFull;

    userName = "jager";
    userEmail = "jj4v3l@gmail.com";

    signing = {
      key = config.programs.gpg.settings.default-key;
      signByDefault = true;
    };

    lfs = {
      enable = true;
      skipSmudge = true;
    };

    extraConfig = {
      credential.helper = "${pkgs.gitFull}/bin/git-credential-libsecret";

      init.defaultBranch = "main";
      branch.autosetupmerge = "true";
      pull.ff = "only";
      color.ui = "auto";

      push = {
        default = "current";
        followTags = true;
        autoSetupRemote = true;
      };

      merge = {
        conflictstyle = "diff3";
        stat = "true";
      };

      rebase = {
        autoSquash = true;
        autoStash = true;
      };

      rerere = {
        enabled = true;
        autoupdate = true;
      };
    };

    aliases = {
      # Semantic commit message aliases
      chore = "!f() { git commit -m \"chore($1): $2\"; }; f";
      docs = "!f() { git commit -m \"docs($1): $2\"; }; f";
      feat = "!f() { git commit -m \"feat($1): $2\"; }; f";
      fix = "!f() { git commit -m \"fix($1): $2\"; }; f";
      refactor = "!f() { git commit -m \"refactor($1): $2\"; }; f";
      style = "!f() { git commit -m \"style($1): $2\"; }; f";
      test = "!f() { git commit -m \"test($1): $2\"; }; f";
    };

    ignores = [
      "*~"
      "*.swp"
      "*result*"
      ".direnv"
      "node_modules"
    ];
  };
}
