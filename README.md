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

## Configuration
This script has only a few configurations that can be changed directly within the `htpasswd-users.sh` file:
```
#!/bin/bash

### CONF ###
file='users.htpasswd' #The name of the support file that is created by downloading data from the secret
update_oc=true #If true changes will be apply to OpenShift
delete_file_on_exit=true #If true the support file (htpasswd file) will be delete on exit. if you need to change file manually you can set it to false and the file will be available on working directory until the next execution of the script
```

## Usage
Run the script and follow the instructions
```
./htpasswd_users.sh
```
