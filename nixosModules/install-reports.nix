{
  sops.secrets = {
    install-reports-app-id = {
      sopsFile = ../secrets/install-reports.yaml;
      key = "app_id";
    };
    install-reports-key = {
      sopsFile = ../secrets/install-reports.yaml;
      key = "private_key";
    };
  };

  oruc.autoUpgrade.issueReports = true;
}
