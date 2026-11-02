# shellcheck shell=bash disable=SC2034 # the scripts that source this file read SSH_OPTS
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
