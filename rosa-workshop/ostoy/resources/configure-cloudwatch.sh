#!/bin/bash

#########################################
# This script is adapted from the Red Hat OpenShift Documentation
# https://docs.openshift.com/container-platform/4.15/observability/logging/cluster-logging-deploying.html#logging-loki-cli-install_cluster-logging-deploying
# https://docs.openshift.com/rosa/observability/logging/log_collection_forwarding/configuring-log-forwarding.html#rosa-cluster-logging-collector-log-forward-sts-cloudwatch_configuring-log-forwarding
# 
# The script configures the cluster to be used with AWS CloudWatch for Logging
#########################################

AWS_REGION="us-west-2" # Update the region if needed. 

# These should not be modified
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='RosaCloudWatch'].{ARN:Arn}" --output text)
OIDC_ENDPOINT=$(rosa describe cluster -c $(oc get clusterversion -o jsonpath='{.items[].spec.clusterID}{"\n"}') -o yaml | awk '/oidc_endpoint_url/ {print $2}' | cut -d '/' -f 3,4)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME=$(rosa describe cluster -c $(oc get clusterversion -o jsonpath='{.items[].spec.clusterID}{"\n"}') -o yaml | awk '/displayName|display_name/ {print $2}')

if [ -z "$OIDC_ENDPOINT" ] && [ -z "$AWS_ACCOUNT_ID" ] && [ -z "$CLUSTER_NAME" ]; then
    echo "All variables are null."
    exit 1
elif [ -z "$OIDC_ENDPOINT" ]; then
    echo "OIDC_ENDPOINT is null."
    exit 1
elif [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "AWS_ACCOUNT_ID is null."
    exit 1
elif [ -z "$CLUSTER_NAME" ]; then
    echo "CLUSTER_NAME is null."
    exit 1
elif [ -z "$AWS_REGION" ]; then
    echo "AWS_REGION is null."
    exit 1
else
    echo "Varaibles are set...ok."
fi

# Create an IAM Policy for OpenShift Log Forwarding if it doesnt already exist
if [[ -z "${POLICY_ARN}" ]]; then
cat << EOF > cw-policy.json
{
"Version": "2012-10-17",
"Statement": [
   {
         "Effect": "Allow",
         "Action": [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:DescribeLogGroups",
            "logs:DescribeLogStreams",
            "logs:PutLogEvents",
            "logs:PutRetentionPolicy"
         ],
         "Resource": "arn:aws:logs:*:*:*"
   }
]
}
EOF
POLICY_ARN=$(aws iam create-policy --policy-name "RosaCloudWatch" --policy-document file://cw-policy.json --query Policy.Arn --output text)
echo "Created policy."
else 
  echo "Policy already exists...ok."
fi

# Create an IAM Role trust policy for the cluster
cat <<EOF > cloudwatch-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
    "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ENDPOINT}:sub": "system:serviceaccount:openshift-logging:logcollector"
      }
    }
  }]
}
EOF

# Create the role
export ROLE_ARN=$(aws iam create-role --role-name "RosaCloudWatch-${CLUSTER_NAME}" \
--assume-role-policy-document file://cloudwatch-trust-policy.json \
--tags "Key=rosa-workshop,Value=true" \
--query Role.Arn --output text)

echo "Created RosaCloudWatch-${CLUSTER_NAME} role."

# Attach the IAM Policy to the IAM Role
aws iam attach-role-policy --role-name "RosaCloudWatch-${CLUSTER_NAME}" --policy-arn "${POLICY_ARN}"
echo "Attached role policy."

# Deploy the Red Hat OpenShift Logging Operator
echo "Deploying the Red Hat OpenShift Logging Operator"

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging 
annotations:
    openshift.io/node-selector: ""
labels:
    openshift.io/cluster-logging: "true"
    openshift.io/cluster-monitoring: "true" 
EOF

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: openshift-logging 
spec:
  targetNamespaces:
  - openshift-logging
EOF

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging 
spec:
  channel: stable 
  name: cluster-logging
  source: redhat-operators 
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for Red Hat OpenShift Logging Operator deployment to complete..."

sleep 10

# wait for the Red Hat OpenShift Logging Operator to install
while ! oc -n openshift-logging rollout status deployment cluster-logging-operator 2>/dev/null | grep -q "successfully"; do
    echo "Waiting for Red Hat OpenShift Logging Operator deployment to complete..."
    sleep 10
done

echo "Red Hat OpenShift Logging Operator deployed."

# create a secret containing the ARN of the IAM role that we previously created above.
cat << EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cloudwatch-credentials
  namespace: openshift-logging
stringData:
  credentials: |-
    [default]
    sts_regional_endpoints = regional
    role_arn: ${ROLE_ARN} 
    web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF

# configure the OpenShift Cluster Logging Operator by creating a Cluster Log Forwarding custom resource that will forward logs to AWS CloudWatch
cat << EOF | oc apply -f -
apiVersion: logging.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  outputs:
  - name: cw
    type: cloudwatch
    cloudwatch:
      groupBy: logType
      groupPrefix: rosa-${CLUSTER_NAME}
      region: ${AWS_REGION}
    secret:
      name: cloudwatch-credentials
  pipelines:
  - name: to-cloudwatch
    inputRefs:
    - infrastructure
    - audit
    - application
    outputRefs:
    - cw
EOF

#  create a Cluster Logging custom resource which will enable the OpenShift Cluster Logging Operator to start collecting logs
cat << EOF | oc apply -f -
apiVersion: logging.openshift.io/v1
kind: ClusterLogging
metadata:
  name: instance 
  namespace: openshift-logging 
spec:
  collection:
    type: vector
  managementState: Managed
EOF

echo "Complete."
