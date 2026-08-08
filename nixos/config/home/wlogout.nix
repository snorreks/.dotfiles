{pkgs, ...}: {
  programs.wlogout = {
    enable = true;

    # 1. Define the layout with plain text (No icons here)
    layout = [
      {
        label = "lock";
        action = "swaylock-runtime";
        text = "Lock";
        keybind = "l";
      }
      {
        label = "reboot";
        action = "systemctl reboot";
        text = "Reboot";
        keybind = "r";
      }
      {
        label = "shutdown";
        action = "systemctl poweroff";
        text = "Shutdown";
        keybind = "p";
      }
      {
        label = "logout";
        action = "pkill mango";
        text = "Logout";
        keybind = "o";
      }
      {
        label = "suspend";
        action = "systemctl suspend";
        text = "Suspend";
        keybind = "s";
      }
      {
        label = "cancel";
        action = "wlogout -c";
        text = "Cancel";
        keybind = "c";
      }
    ];

    # 2. Define the Style using background-images for big icons
    style = ''
      window {
          font-family: "JetBrainsMono Nerd Font";
          background-color: rgba(26, 27, 38, 0.85); /* Tokyo Night */
      }

      button {
          background-color: rgba(36, 40, 59, 0.4);
          color: #c0caf5;
          border: 2px solid #1a1b26;
          border-radius: 20px;
          margin: 15px;
          background-repeat: no-repeat;
          background-position: center;
          background-size: 25%; /* Controls how big the icon is */
          transition: all 0.3s ease-in-out;
      }

      button:hover {
          background-color: rgba(122, 162, 247, 0.2);
          border: 2px solid #7aa2f7;
          color: #7aa2f7;
      }

      /* Push the text label down so it's under the icon */
      button label {
          font-size: 20px;
          margin-top: 120px; /* Adjust this to move text further down */
      }

      /* Desktop Icons from the Nix Store */
      #lock {
          background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/lock.png"));
      }
      #reboot {
          background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/reboot.png"));
      }
      #shutdown {
          background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/shutdown.png"));
      }
      #logout {
          background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/logout.png"));
      }
      #suspend {
          background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/suspend.png"));
      }
      #cancel {
          background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/hibernate.png"));
      }
    '';
  };
}
