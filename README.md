# htpasswd_users
OpenShift htpasswd identity provider - users management

## Introduction
> Warning!!!
We recommend that you follow the official OpenShift Red Hat guide to configure HTPasswd identityProvider:
https://docs.openshift.com/container-platform/4.14/authentication/identity_providers/configuring-htpasswd-identity-provider.html

This script was tested on OpenShift 4.14 and works only if the identityProvider HTPasswd is enabled.
To enable the HTPasswd identityProvider you can use a manifest like this one below as an example:
```
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd_provider
    challenge: true
    login: true
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
```

## Install
```
git clone https://github.com/signoredellarete/htpasswd_users.git
cd htpasswd_users
chmod +x htpasswd_users.sh
```

## Usage
Run the script and follow the instructions
```
./htpasswd_users.sh
```
