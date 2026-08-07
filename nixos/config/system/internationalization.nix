{...}: {
  # Select internationalisation properties
  i18n = {
    defaultLocale = "en_US.UTF-8";
    supportedLocales = ["en_US.UTF-8/UTF-8" "nb_NO.UTF-8/UTF-8"];
    extraLocaleSettings = {
      LC_ADDRESS = "en_US.UTF-8";
      LC_IDENTIFICATION = "en_US.UTF-8";
      LC_MEASUREMENT = "en_US.UTF-8";
      LC_MONETARY = "en_US.UTF-8";
      LC_NAME = "en_US.UTF-8";
      LC_NUMERIC = "en_US.UTF-8";
      LC_PAPER = "en_US.UTF-8";
      LC_TELEPHONE = "en_US.UTF-8";
      LC_TIME = "en_US.UTF-8";
    };
  };

  console.keyMap = "us";

  time.hardwareClockInLocalTime = true;
  # services.automatic-timezoned.enable = true;
  # https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
  time.timeZone = "Europe/Oslo";
}
