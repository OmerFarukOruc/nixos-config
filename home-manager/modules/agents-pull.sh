#!/usr/bin/env bash
checkout=${1:?usage: agents-pull CHECKOUT}

github_reachable() {
  curl --silent --max-time 20 --output /dev/null https://github.com
}

if [[ ! -e $checkout/.git ]]; then
  if ! git clone --quiet https://github.com/OmerFarukOruc/nixos-config.git "$checkout"; then
    github_reachable || {
      echo "GitHub is unreachable; the next run clones $checkout"
      exit 0
    }
    exit 1
  fi
fi

git -C "$checkout" config agents.mainCheckoutEditPaths agents/

branch=$(git -C "$checkout" branch --show-current)
if [[ $branch != main ]]; then
  echo "$checkout is on '${branch:-a detached HEAD}', not main; switch it back to main so agents/ follows main" >&2
  exit 1
fi

if git -C "$checkout" pull --quiet --ff-only; then
  exit 0
fi
github_reachable || {
  echo "GitHub is unreachable; the next run pulls"
  exit 0
}
exit 1
