# Brave's settings as recommended policies: a new profile starts with these
# values, and its settings page can still change them. Brave Origin reads
# /etc/brave/policies. Notification permissions and the theme colour are
# managed-only policies, so they stay in the profile and Brave Sync.
{
  environment.etc."brave/policies/recommended/oruc.json".text = builtins.toJSON {
    BookmarkBarEnabled = true;
    ShowHomeButton = true;
    HomepageIsNewTabPage = false;
    HomepageLocation = "http://google.com/";
    # 5 opens the new tab page.
    RestoreOnStartup = 5;
    ShowFullUrlsInAddressBar = true;
    DefaultSearchProviderEnabled = true;
    DefaultSearchProviderName = "Google";
    DefaultSearchProviderKeyword = ":g";
    DefaultSearchProviderSearchURL = "https://www.google.com/search?q={searchTerms}";
  };
}
