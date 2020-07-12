#!/bin/bash

# kubectl proxy --port=8080 &
echo "Deleting the namespace anchore"
oc project anchore
oc delete --all all,secret,pvc
oc get ns anchore -o json > generated/tempfile
sed -i 's/"kubernetes"//g' generated/tempfile
curl --silent -H "Content-Type: application/json" -X PUT --data-binary @generated/tempfile http://127.0.0.1:8080/api/v1/namespaces/anchore/finalize
