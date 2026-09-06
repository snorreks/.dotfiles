# nixos/pkgs/msi-perkeyrgb.nix
#
# Askannz/msi-perkeyrgb — the SteelSeries per-key RGB controller on MSI
# laptops (USB HID 1038:1122). Not in nixpkgs, so it's packaged here.
#
# Two upstream assumptions are wrong on NixOS and get patched out:
#
#   1. It locates libhidapi by regexing `ldconfig -p`. NixOS has no ldconfig
#      cache, so that always returns nothing and the tool dies with
#      "Cannot locate the hidapi library". The store path is substituted in
#      directly — note the regex it feeds is /.*libhidapi-hidraw\.so.+/, which
#      requires at least one character after ".so", so this has to be the
#      soname symlink (…so.0) and not the bare development one (…so).
#   2. It probes for the keyboard by shelling out to `lsusb`, which is not on
#      PATH here (usbutils isn't installed). Pointed at the store binary.
{
  lib,
  python3Packages,
  fetchFromGitHub,
  hidapi,
  usbutils,
}:
python3Packages.buildPythonApplication rec {
  pname = "msi-perkeyrgb";
  version = "2.1";
  format = "setuptools";

  src = fetchFromGitHub {
    owner = "Askannz";
    repo = "msi-perkeyrgb";
    rev = "v${version}";
    hash = "sha256-QG+Kchoy+kbg32EF0psnoowvmEVKnfIOsMcxR569RTg=";
  };

  postPatch = ''
    substituteInPlace msi_perkeyrgb/hidapi_wrapping.py \
      --replace-fail 's = popen("ldconfig -p").read()' \
                     's = "${hidapi}/lib/libhidapi-hidraw.so.0"' \
      --replace-fail 's = popen("lsusb").read()' \
                     's = popen("${usbutils}/bin/lsusb").read()'
  '';

  # No test suite upstream, and importing the module would try to open the
  # keyboard.
  doCheck = false;
  pythonImportsCheck = ["msi_perkeyrgb"];

  meta = {
    description = "Control per-key RGB keyboard backlighting on MSI laptops";
    homepage = "https://github.com/Askannz/msi-perkeyrgb";
    license = lib.licenses.mit;
    mainProgram = "msi-perkeyrgb";
    platforms = lib.platforms.linux;
  };
}
