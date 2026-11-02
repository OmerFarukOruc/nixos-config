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
}
