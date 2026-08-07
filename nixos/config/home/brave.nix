# In nixos/config/home/brave.nix
{pkgs, ...}: {
  programs.chromium = {
    enable = true;
    package = pkgs.brave;
    extensions = [
      {id = "fjcldmjmjhkklehbacihaiopjklihlgg";} # news-feed-eradicator
      {id = "khncfooichmfjbepaaaebmommgaepoid";} # unhook-remove-youtube
      {id = "jiaopdjbehhjgokpphdfgmapkobbnmjp";} # youtube-shorts-block
    ];
  };
}
