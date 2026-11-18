# Reproduce a flaky test under load

Run the steps in order and stop at the first batch that reproduces the failure.

1. Run copies of the test file at once. A failure that comes from a resource the copies share, such as "address in use" or a name already taken, is not the reproduction, so fix it under "A test owns its resources" in `testing-discipline.md`, or run the copies one after another when the repository's testing policy lists the file as one that runs one copy at a time. Count the CPUs with `nproc` and start at most one copy for every 2 CPUs, rounded down, at least 1 (guess; the cap leaves CPU for the other sessions on the machine, which a niceness does not do across systemd scopes or under a sched_ext scheduler such as scx_lavd). On a host whose rules run one heavy suite at a time, run the copies one after another and say so.
2. When that batch does not reproduce the failure, run a second batch beside busy loops, each started as `sh -c 'while :; do :; done' &`, at most one loop for every 3 CPUs, rounded down (guess, same reason); with fewer than 3 CPUs, skip the loops. Start the loops once the test processes of a copy run, because a wrapper such as a gate lock can hold a copy in a queue while the loops use CPU.

Start the copies and the loops from one script that waits for every copy and stops the loops by PID when it exits, after an interrupt too.

The report gives the `nproc` value, the copy count, the loop count and the number of runs up to and including the first failure, and says "not reproduced at this load" when the failure stays away.
