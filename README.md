
# Anchore

https://github.com/anchore/anchore-engine

This Repo demonstrates how to deploy the anchore-engine and uses kubernetes admission controller webhook to controle which images are allowed to run.
you can follows this teps to deploy on you own cluster or a local k3d cluster or on OpenShift 3.11...

The example used in this repo is based on https://anchore.com/blog/dynamic-policy-mappings-and-modes-in-the-anchore-kubernetes-admission-controller/ 

# k3d local cluster

you can use your own cluster or you can create a local kubernetes cluster using [k3d + k3s](https://k3d.io/).

So here is the command to create a simple cluster with only one node:
```
k3d create cluster anchore --switch --api-port 6553 -p 8083:80@loadbalancer
```


# Anchore Engine installation on kubernetes:
the official documentation: https://docs.anchore.com/current/docs/installation/helm/

* if you use a kubernetes version < 1.16
  * classic deployment with default helm chart values

    ```
    kubectl create namespace anchore
    helm install anchore stable/anchore-engine
    ```

  * deploy with openshift 3.11
    
    with openshift 3.11 you can still use the chart without generating the template before:
    ```
    oc new-project anchore
    helm install anchore -f helm_ocp_anchore_values.yaml stable/anchore-engine
    ```
    Notice the file [helm_ocp_anchore_values.yaml](./helm_ocp_anchore_values.yaml)

* if you use a kubernetes version >= 1.16
  
  * In this situation you will need to generate the template helm chart because this helm chart contains old apiVersion for kubernetes deployment which has been removed since kubernetes 1.16
    ```
    kubectl create namespace anchore
    helm repo add stable https://kubernetes-charts.storage.googleapis.com
    helm repo add anchore-stable http://charts.anchore.io/stable
    help repo update
    helm template anchore stable/anchore-engine -n anchore > generated/anchore-engine.yaml
    ```

  * update file anchore.yaml: In the anchore-postgresql Deployment do the following:
    
    replace "apiVersion: extensions/v1beta1" by "apiVersion: apps/v1"

  * deploy the anchore engine:
    ```
    kubectl apply -n anchore -f generated/anchore-engine.yaml
    ```


# configure the anchore cli

* anchore-cli installation

  see https://github.com/anchore/anchore-cli

  ```
  pip install --user --upgrade anchorecli
  export ANCHORE_CLI_URL=http://localhost:8228/v1
  export ANCHORE_CLI_USER=admin
  export ANCHORE_CLI_PASS=$(kubectl get secret --namespace anchore anchore-anchore-engine -o jsonpath="{.data.ANCHORE_ADMIN_PASSWORD}" | base64 --decode; echo)
  ```

  instead of installing the anchor-cli with python you can use the dedicated docker image:
  ```
  docker run -e ANCHORE_CLI_URL=https://anchore.mydomain.com:8228/v1/ -e ANCHORE_CLI_USER=admin -e ANCHORE_CLI_PASS=foobar -e ANCHORE_CLI_SSL_VERIFY=n -it --rm anchore/engine-cli
  ```

* in a separate shell forward engine api port on your local host
  ```
  kubectl --namespace anchore port-forward svc/anchore-anchore-engine-api 8228:8228
  ```
  so that you will be able to reach the anchore engine api on localhost:8228

* Configuration with the cli

  Create a user account and 2 policies:
  * [policy_testing_bundle](./policy_testing_bundle.json): checks that vulnerabilities < medium and 'HEALTHCHECK' instruction exist: with a WARN action only
  * [policy_production_bundle](./policy_production_bundle.json): checks that vulnerabilities < medium and 'HEALTHCHECK' instruction exist: with a STOP action
  
  ```
  anchore-cli account add testing
  anchore-cli account user add --account testing testuser testuserpassword
  anchore-cli --u testuser --p testuserpassword image add alpine
  anchore-cli --u testuser --p testuserpassword image add nginx 

  anchore-cli --u testuser --p testuserpassword policy add policy_testing_bundle.json
  anchore-cli --u testuser --p testuserpassword policy add policy_production_bundle.json
  ```

  wait and validate that alpine and nginx images are scanned, then evaluate the result:
  ```
  anchore-cli --u testuser --p testuserpassword image list

  anchore-cli --u testuser --p testuserpassword evaluate check nginx --policy policy_testing_bundle --detail
  anchore-cli --u testuser --p testuserpassword evaluate check nginx --policy policy_production_bundle  --detail

  anchore-cli --u testuser --p testuserpassword image content nginx
  anchore-cli --u testuser --p testuserpassword image vuln nginx all
  ```




# Anchore Admission Controller:

* URL: https://github.com/anchore/kubernetes-admission-controller
* Chart: https://github.com/anchore/anchore-charts/tree/master/stable/anchore-admission-controller

The Anchor Admission Controller allows to create containers depending on a policy rule.

## Anchore Admission Controller installation on kubernetes:

* if you use a kubernetes version < 1.16
  * classic deployment with default helm chart values

    ```
    ```

  * deploy with openshift 3.11
    
    before installing the admission controller and if you use minishift you will need to activate the admissions-webhook addons:
    ```
    minishift addons enable admissions-webhook
    minishift addons apply admissions-webhook   
    ```
    
    For openshift you will need to authorize anyuid to execute the container for the dedicated ServiceAccount
    with openshift 3.11 you can still use the chart without generating the template before:
    ```
    oc adm policy add-scc-to-user anyuid system:serviceaccount:anchore:controller-anchore-admission-controller-init-ca
    kubectl -n anchore create secret generic anchore-credentials --from-file=credentials.json=anchore_creds.json
    helm install controller anchore-stable/anchore-admission-controller -f helm_admission_controller.yaml -n anchore
    ```
    See the file [helm_admission_controller](./helm_admission_controller.yaml)

* if you use a kubernetes version >= 1.16

  * In this situation you will need to generate the template helm chart because this helm chart contains old apiVersion for kubernetes deployment which has been removed since kubernetes 1.16

  ```
  kubectl -n anchore create secret generic anchore-credentials --from-file=credentials.json=anchore_creds.json
  helm template controller anchore-stable/anchore-admission-controller -f helm_admission_controller.yaml -n anchore > generated/anchore-webhook.yaml
  ```

  * update file generated/anchore-webhook.yaml:

    In the controller-anchore-admission-controller Deployment do the following:
    * replace "apiVersion: extensions/v1beta1" by "apiVersion: apps/v1"
    * add the missing selector in the spec section
    ```
        selector:
          matchLabels:
            app: anchore-admission-controller
            release: controller
    ```

    * deploy the Admission Controller:
    ```
    kubectl config set-context --current --namespace=anchore
    kubectl apply -f generated/anchore-webhook.yaml
    ```

## Create the validating webhook configuration

```
KUBE_CA=$(kubectl config view --minify=true --flatten -o json | jq '.clusters[0].cluster."certificate-authority-data"' -r)

cat > generated/anchore-webhook-configuration.yaml <<EOF
apiVersion: admissionregistration.k8s.io/v1beta1
kind: ValidatingWebhookConfiguration
metadata:
  name: controller-anchore-admission-controller.admission.anchore.io
webhooks:
- name: controller-anchore-admission-controller.admission.anchore.io
  clientConfig:
    service:
      namespace: default
      name: kubernetes
      path: /apis/admission.anchore.io/v1beta1/imagechecks
    caBundle: $KUBE_CA
  rules:
  - operations:
    - CREATE
    apiGroups:
    - ""
    apiVersions:
    - "*"
    resources:
    - pods
  failurePolicy: Fail
# Uncomment this and customize to exclude specific namespaces from the validation requirement
#  namespaceSelector:
#    matchExpressions:
#      - key: exclude.admission.anchore.io
#        operator: NotIn
#        values: ["true"]
EOF

kubectl -n anchore apply -f generated/anchore-webhook-configuration.yaml
```

# test
```
kubectl create namespace testing
kubectl -n testing run -it --rm nginx --restart=Never --image nginx /bin/sh
```
=> should create the pod


```
kubectl create namespace production
kubectl -n production run -it --rm nginx --restart=Never --image nginx /bin/sh
```
=> should deny the pod creation with the following message:

```
Error from server: admission webhook "controller-anchore-admission-controller.admission.anchore.io" denied the request: Image alpine with digest sha256:a15790640a6690aa1730c38cf0a440e2aa44aaca9b0e8931a9f2b0d7cc90fd65 failed policy checks for policy bundle production_bundle
```


# Image not analysed before

Notes that if you try to run an image not analysed before then you will get this error
```
kubectl run curl --image curlimages/curl:7.69 --restart Never -it --rm -- sh
> Error from server: admission webhook "controller-anchore-admission-controller.admission.anchore.io" denied the request: Image curlimages/curl:7.69 is not analyzed.
```

on kubernetes you will find the error in the event:

```
kubectl get events
> 0s          Warning   FailedCreate        replicaset/my-todo-deployment-9fbd74bb6   Error creating: admission webhook "controller-anchore-admission-controller.admission.anchore.io" denied the request: Image sokubedocker/simple-todo:3.0 is not analyzed. Cannot evaluate policy
> 0s          Warning   FailedCreate        replicaset/my-todo-deployment-9fbd74bb6   Error creating: admission webhook "controller-anchore-admission-controller.admission.anchore.io" denied the request: Image sokubedocker/simple-todo:3.0 with digest sha256:a645937ee0dab91d413c3f4464535308f15fec1572a6e3fb1208f515ebc1b4c3 failed policy checks for policy bundle production_bundle
```
