{ pkgs, ... }:
{
  # AMD GPU configuration
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      amdvlk
      rocmPackages.clr.icd
    ];
    extraPackages32 = with pkgs; [
      driversi686Linux.amdvlk
    ];
  };

  services.xserver.videoDrivers = [ "amdgpu" ];

  # ROCm support
  systemd.tmpfiles.rules = [
    "L+    /opt/rocm/hip   -    -    -     -    ${pkgs.rocmPackages.clr}"
  ];

  environment.variables = {
    ROC_ENABLE_PRE_VEGA = "1";
  };
}
