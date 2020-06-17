REPO_ROOT=$(git rev-parse --show-toplevel)
export TESTDIR="${REPO_ROOT}/test"
DEPLOYDIR="${REPO_ROOT}/deploy"
OPERATOR_NAMESPACE=test-openshift-aws-efs
WORK_NAMESPACES=(myns1 myns2)

# TODO(efried): This isn't very nice for consumers who aren't me.
if [ -z "$IMAGE_REPOSITORY" ]; then
  export IMAGE_REPOSITORY=2uasimojo
fi
if [ -z "$OPERATOR_TAG" ]; then
  OPERATOR_TAG=latest
fi

OPERATOR_IMAGE=quay.io/${IMAGE_REPOSITORY}/aws-efs-operator:${OPERATOR_TAG}

awscreds() {
  export AWS_DEFAULT_REGION=us-east-1
  SECRETS=$(oc get secrets -n kube-system aws-creds -o json)
  export AWS_ACCESS_KEY_ID=$(echo "$SECRETS" | jq -r .data.aws_access_key_id | base64 -d)
  export AWS_SECRET_ACCESS_KEY=$(echo "$SECRETS" | jq -r .data.aws_secret_access_key | base64 -d)
}


err() {
  echo "$@" >&2
  exit 1
}

slugify() {
  local fsid=$1
  local apid=$2
  echo "${fsid#*-}-${apid#*-}"
}

create_shared_volume() {
  local ns=$1
  local fsid=$2
  local apid=$3
  local svname=sv-$(slugify $fsid $apid)
  local spec=$TMPD/$ns-$svname.yaml
  cat <<EOF>$spec
apiVersion: aws-efs.managed.openshift.io/v1alpha1
kind: SharedVolume
metadata:
  name: $svname
  namespace: $ns
spec:
  accessPointID: $apid
  fileSystemID: $fsid
EOF
  oc apply -f $spec

  echo "Waiting for sv/$svname in namespace $ns to have Ready status"
  while [[ $(oc get sv/$svname -n $ns -o jsonpath={.status.phase}) != Ready ]]; do
    sleep 1
  done

  echo "Waiting for pvc/pvc-$svname in namespace $ns to be Bound"
  while [[ $(oc get pvc/pvc-$svname -n $ns -o jsonpath={.status.phase}) != Bound ]]; do
    sleep 1
  done
}

create_test_pod() {
  local ns=$1
  local volumes="$2"
  local mounts="$3"
  local spec=$TMPD/pod-$ns.yaml
  cat <<EOF>$spec
apiVersion: v1
kind: Pod
metadata:
  name: efs-pod
  namespace: $ns
spec:
  volumes:
${volumes}
  containers:
  - name: efs-container
    image: centos:latest
    command: [ "/bin/bash", "-c", "--" ]
    args: [ "while true; do sleep 30; done" ]
    volumeMounts:
${mounts}
EOF
  oc apply -f $spec

  echo "Waiting for the Pod in namespace $ns to be Running"
  while [[ $(oc get pod/efs-pod -n $ns -o jsonpath={.status.phase}) != Running ]]; do
    sleep 1
  done

  echo "Waiting for the container in namespace $ns to be started"
  while [[ $(oc get pod/efs-pod -n $ns -o jsonpath={.status.containerStatuses[0].started}) != 'true' ]]; do
    sleep 1
  done
}

ensure_fs_state() {
  echo
  echo "Ensuring file system state"
  echo "=========================="
  awscreds
  ${TESTDIR}/fsmanage --spec ${TESTDIR}/fsspec.yaml
}

ensure_operator() {
  echo
  echo "Installing operator..."
  echo "======================"
  echo "=> Ensuring operator namespace $OPERATOR_NAMESPACE"
  oc get namespace $OPERATOR_NAMESPACE || oc create namespace $OPERATOR_NAMESPACE
  oc project $OPERATOR_NAMESPACE
  echo "=> Applying CRD"
  # This will break if there's more than one *_crd.yaml.
  oc apply -f $DEPLOYDIR/crds/*_crd.yaml
  echo "=> Deploying operator stuffs"
  # These `sed`s are because:
  # - We need to set the image name in the operator deployment.
  # - Due to webhooks denying use of `openshift-*`, we have to hack the
  #   operator namespace :(
  #   This relies on that namespace only being set where we expect it (the
  #   ServiceAccount subject in the ClusterRoleBinding). If it's set
  #   anywhere else, and needs to be something other than the operator
  #   namespace, this will break.
  pids=
  for f in $(/bin/ls $DEPLOYDIR/*.yaml); do
    spec=$TMPD/$(basename $f)
    sed "s/namespace: .*/namespace: $OPERATOR_NAMESPACE/; s,REPLACE_IMAGE,$OPERATOR_IMAGE," $f > $spec
    oc apply -f $spec &
    pids="$pids $!"
  done
  for pid in $pids; do wait $pid; done
}

ensure_namespaces() {
  echo
  echo "Ensuring work namespaces..."
  echo "==========================="
  pids=
  for ns in ${WORK_NAMESPACES[@]}; do
    oc get namespace $ns || oc create namespace $ns &
    pids="$pids $!"
  done
  for pid in $pids; do wait $pid; done
}

############################################
echo
echo "Building fsmanage"
echo "================="
# No-op if already built, because make
make -f ${TESTDIR}/Makefile fsmanage
