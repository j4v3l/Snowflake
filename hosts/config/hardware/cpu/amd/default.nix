{ lib, ... }:
{
  # AMD CPU microcode updates
  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;

  # AMD-specific kernel parameters
  boot.kernelParams = [
    "amd_pstate=active"
  ];
}
