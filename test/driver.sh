#!/bin/bash -e

source ${0%/*}/lib.sh

FSSPEC=${TESTDIR}/fsspec.yaml

TMPD=$(mktemp -d)
trap "rm -fr $TMPD" EXIT

echo
echo "=============================================="
echo "THIS TOOL DOES NOT REBUILD THE OPERATOR IMAGE!"
echo "You have to do that yourself."
echo "I'm going to use $OPERATOR_IMAGE"
echo "=============================================="

ensure_fs_state

ensure_operator

ensure_namespaces

echo
echo "Discovering file systems and access points"
echo "=========================================="
fsinfo="$(${TESTDIR}/fsmanage --discover)"

echo
echo "Creating SharedVolume resources"
echo "==============================="
pids=
for fsap in $fsinfo; do
  fsid=${fsap%:*}
  apid=${fsap#*:}
  echo "=> FS $fsid  AP $apid"
  for ns in ${WORK_NAMESPACES[@]}; do
    echo "===> Namespace: $ns"
    create_shared_volume $ns $fsid $apid &
    pids="$pids $!"
  done
done
for pid in $pids; do wait $pid; done

echo
echo "Creating test pods"
echo "=================="
# We need to build up the lists that will go in the pod defs under
# .spec.volumes and .spec.containers[0].volumeMounts.
for fsap in $fsinfo; do
  fsid=${fsap%:*}
  apid=${fsap#*:}
  slug=$(slugify $fsid $apid)
  cat <<EOF >>$TMPD/volumes
  - name: efs-$slug
    persistentVolumeClaim:
      claimName: pvc-sv-$slug
EOF
  cat <<EOF >>$TMPD/mounts
    - mountPath: /mnt/efs-$slug
      name: efs-$slug
EOF
done
VOLUMES="$(cat $TMPD/volumes)"
MOUNTS="$(cat $TMPD/mounts)"

pids=
for ns in ${WORK_NAMESPACES[@]}; do
  echo "=> Namespace: $ns"
  create_test_pod $ns "$VOLUMES" "$MOUNTS" &
  pids="$pids $!"
done
for pid in $pids; do wait $pid; done

echo
echo "Writing..."
echo "=========="
for ns in ${WORK_NAMESPACES[@]}; do
  echo "=> Namespace: $ns"
  for fsap in $fsinfo; do
    fsid=${fsap%:*}
    apid=${fsap#*:}
    slug=$(slugify $fsid $apid)
    # Suffix with the current PID so the test is repeatable (we don't
    # keep growing the same file)
    path=/mnt/efs-$slug/data.$$
    message="$ns was here in $slug"
    echo "===> Path: $path"
    oc rsh -n $ns pod/efs-pod bash -c "echo '$message' >> $path"
    # NOTE: append
    echo "$message" >> $TMPD/expected.$slug
  done
done

echo
echo "Reading..."
echo "=========="
for ns in ${WORK_NAMESPACES[@]}; do
  echo "=> Namespace: $ns"
  for fsap in $fsinfo; do
    fsid=${fsap%:*}
    apid=${fsap#*:}
    slug=$(slugify $fsid $apid)
    path=/mnt/efs-$slug/data.$$
    echo "===> Path: $path"
    # NOTE: overwrite, and check each time
    oc rsh -n $ns pod/efs-pod bash -c "cat $path" > $TMPD/actual.$slug
    # TODO(efried): `actual` is coming back with Windows-style
    # newlines!! WTAF??
    if ! diff -w $TMPD/expected.$slug $TMPD/actual.$slug; then
      echo EXPECTED
      od -c $TMPD/expected.$slug
      echo ACTUAL
      od -c $TMPD/actual.$slug
      exit -1
    fi
  done
done

echo
echo "==================================="
echo "If you got here, everything worked!"
echo "==================================="
