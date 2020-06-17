#!/bin/bash

source ${0%/*}/lib.sh

err() {
  echo "$@" >&2
  exit 1
}

declare -A CLEAN
CLEAN=(
  [pods]=0
  [sharedvolumes]=0
  [efs]=0
  [operator]=0
)

if [ -z $1 ]; then
  err "Specify at least one thing to clean up, or 'all'.
    ${!CLEAN[@]}"
  exit 1
fi

while [ "$1" ]; do
  if [[ "$1" == "all" ]]; then
    # Switch on everything
    for k in "${!CLEAN[@]}"; do
      CLEAN[$k]=1
    done
    # Ignore anything else
    break
  fi

  if ! [[ " ${!CLEAN[@]} " == *" $1 "* ]]; then
    err "Unknown cleanup target '$1'. Specify 'all', or at least one of
      ${!CLEAN[@]}"
  fi
  CLEAN[$1]=1
  shift
done

toclean=
for k in "${!CLEAN[@]}"; do
  if [[ ${CLEAN[$k]} -eq 1 ]]; then
    toclean="$toclean $k"
  fi
done
echo
echo "==========="
echo "Will clean:
  $toclean"
echo "==========="

### Pods first
if [[ ${CLEAN[pods]} -eq 1 ]]; then
  echo
  echo "Cleaning up pods..."
  echo "==================="
  for ns in "${WORK_NAMESPACES[@]}"; do
    echo "Deleting pods from namespace $ns"
    oc delete pods -n $ns --all &
  done
  wait
fi

### Then SVs
if [[ ${CLEAN[sharedvolumes]} -eq 1 ]]; then
  echo
  echo "Cleaning up sharedvolumes..."
  echo "============================"
  for ns in "${WORK_NAMESPACES[@]}"; do
    echo "Deleting SharedVolumes from namespace $ns"
    oc delete sharedvolumes -n $ns --all &
  done
  wait
fi

### Then the operator
if [[ ${CLEAN[operator]} -eq 1 ]]; then
  echo
  echo "Uninstalling operator..."
  echo "========================"
  if ! oc get project $OPERATOR_NAMESPACE; then
    echo "Assuming the operator is already gone"
  else
    oc project $OPERATOR_NAMESPACE
    # Uninstall the operator before blowing away the CRD
    /bin/ls $DEPLOYDIR/*.yaml | xargs -n1 oc delete -f
    # Today, uninstalling the operator doesn't clean up statics
    $REPO_ROOT/hack/scripts/delete_statics.sh
    oc project default
    oc delete namespace $OPERATOR_NAMESPACE
    # This will break if there's more than one *_crd.yaml
    oc delete -f $DEPLOYDIR/crds/*_crd.yaml
  fi
fi

### Finally EFS stuff
if [[ ${CLEAN[efs]} -eq 1 ]]; then
  echo
  echo "Cleaning up EFS..."
  echo "=================="
  ${TESTDIR}/fsmanage --delete-all
fi
