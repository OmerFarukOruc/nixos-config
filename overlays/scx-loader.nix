# scx_loader runs the scheduler as a child process and, after a failed start,
# retries 5 times in total and then leaves the scheduler stopped while the
# loader keeps running. A scheduler that exits cleanly is not restarted at
# all. This makes the loader exit with the scheduler's exit code, so systemd
# restarts both and its start limit stops a crash loop, as the removed
# services.scx unit did. Stopping the scheduler through scxctl is not
# affected. The build fails when the replaced line is missing from the source.
# Source: crates/scx_loader/src/main.rs, scx-loader 1.1.3
# https://github.com/sched-ext/scx-loader
_final: prev: {
  scx-loader = prev.scx-loader.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace crates/scx_loader/src/main.rs \
        --replace-fail 'log::debug!("Child process exited with status: {status:?}");' \
        'log::error!("Scheduler exited with status: {status:?}"); std::process::exit(status.code().unwrap_or(1));'
    '';
  });
}
