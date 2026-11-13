{
  config,
  lib,
  pkgs,
  ...
}:
let
  run = pkgs.writeShellApplication {
    name = "inbox-browser-tests";
    runtimeInputs = [ config.programs.git.package ];
    text = ''
      today=$(date +%F)
      attempted=$STATE_DIRECTORY/attempted
      script=$STATE_DIRECTORY/nightly-browser-tests.sh
      fetched=false

      if [[ -f $attempted ]] && read -r day result < "$attempted" && [[ $day == "$today" ]]; then
        exit "$result"
      fi

      cd "$HOME/Desktop/workspace/inbox"

      if git fetch --quiet origin main && git show origin/main:scripts/nightly-browser-tests.sh > "$script.new"; then
        mv "$script.new" "$script"
        fetched=true
      elif [[ ! -s $script ]]; then
        echo "origin/main could not be fetched and no earlier copy of the script exists" >&2
        exit 1
      fi

      result=0
      bash "$script" || result=$?

      if $fetched && ((result != 2)); then
        echo "$today $result" > "$attempted"
      fi

      exit "$result"
    '';
  };
  scheduledUnit = import ../../home-manager/modules/scheduled-unit.nix { inherit config lib pkgs; };
in
{
  config = lib.mkMerge [
    (scheduledUnit {
      name = "inbox-browser-tests";
      description = "Run the inbox browser tests on origin/main";
      timerDescription = "Hourly try of the day's run of the inbox browser tests";
      execStart = "${run}/bin/inbox-browser-tests";
      timeout = "3h";
      onCalendar = "hourly";
      randomizedDelay = "5min";
      hint = "see the open issue \"Browser tests fail on main\" in StatusLantern/inbox and run.log under ~/.local/state/inbox-browser-tests";
    })
    { systemd.user.services.inbox-browser-tests.Unit.ConditionACPower = true; }
  ];
}
