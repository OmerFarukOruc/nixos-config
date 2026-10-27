machine.start()
machine.wait_for_unit("multi-user.target")
# --wait returns once boot ends, also when some unit failed.
machine.execute("systemctl is-system-running --wait")
dp_failed = machine.succeed("systemctl --failed --no-legend --plain | cut -d' ' -f1").split()
for dp_unit in dp_failed:
    print(f"journal of {dp_unit}:\n" + machine.succeed(f"journalctl -u {dp_unit} -b -o cat --no-pager | tail -n 40"))
assert dp_failed == [], f"units failed after boot: {dp_failed}"
