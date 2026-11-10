#!/usr/bin/env bash
echo "amp-orb-dispatch: ${ORB_OPERATION:?} orb=${ORB_ID:?} type=${ORB_TYPE-none} snapshot=${ORB_SNAPSHOT_ID-none}"

case $ORB_OPERATION in
  spawn)
    if docker container inspect "$ORB_ID" >/dev/null 2>&1; then
      docker start "$ORB_ID"
    else
      image=${ORB_IMAGE:?}
      if [[ -n ${ORB_SNAPSHOT_ID-} ]] && docker image inspect "$ORB_SNAPSHOT_ID" >/dev/null 2>&1; then
        image=$ORB_SNAPSHOT_ID
      fi
      docker run --init --platform linux/amd64 --shm-size=1g -d --name "$ORB_ID" "$image" sleep infinity
    fi
    docker exec -d --env ORB_TOKEN --env AMP_URL "$ORB_ID" amp orb bootstrap
    ;;
  pause)
    docker stop "$ORB_ID"
    if [[ -n ${ORB_SNAPSHOT_ID-} ]]; then
      docker commit "$ORB_ID" "$ORB_SNAPSHOT_ID"
    fi
    ;;
  delete)
    docker rm -f "$ORB_ID"
    ;;
  *)
    echo "amp-orb-dispatch: unknown operation $ORB_OPERATION" >&2
    exit 1
    ;;
esac
