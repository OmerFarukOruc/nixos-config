{
  config,
  lib,
  ...
}:
let
  cfg = config.oruc.machine;
in
lib.mkIf (cfg.kind == "workstation") {
  environment.etc."brave/policies/recommended/oruc.json".text = builtins.toJSON {
    BookmarkBarEnabled = true;
    ShowHomeButton = true;
    HomepageIsNewTabPage = false;
    HomepageLocation = "http://google.com/";
    RestoreOnStartup = 5;
    ShowFullUrlsInAddressBar = true;
    DefaultSearchProviderEnabled = true;
    DefaultSearchProviderName = "Google";
    DefaultSearchProviderKeyword = ":g";
    DefaultSearchProviderSearchURL = "https://www.google.com/search?q={searchTerms}";
  };

  # Teams' setting "Keep my current status when I'm active outside of Teams on
  # the web" needs the Idle Detection API. Brave blocks it on every site, and
  # --enable-features=IdleDetection only shows the site setting on the
  # settings page. This permission does not sync, so a policy can own it.
  environment.etc."brave/policies/managed/oruc.json".text = builtins.toJSON {
    IdleDetectionAllowedForUrls = [
      "https://teams.cloud.microsoft"
      "https://teams.microsoft.com"
    ];
  };
}
