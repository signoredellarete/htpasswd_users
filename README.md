# htpasswd_users
OpenShift HTPasswd identity provider - Users management

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

## Requirements
- `oc`, the OpenShift client, logged in to the cluster with permissions on the `oauth/cluster` resource and on secrets in the `openshift-config` namespace.
- A way to compute **bcrypt** hashes, either of:
  - `htpasswd` (RHEL/Fedora package `httpd-tools`), used when available; or
  - `perl`, whose `crypt()` supports bcrypt on Linux systems using libxcrypt.

The script detects at startup which one is available and says so in the menu header. The `perl` fallback is validated against a known-answer test, so a `crypt()` that does not implement bcrypt (for example on macOS, where it only provides DES) is rejected instead of silently producing a weaker hash. If neither method is usable the script stops: it never falls back to MD5 or SHA-1.

`jq` is not required.

## Configuration
This script has only a few configurations that can be changed directly within the `htpasswd_users.sh` file:
```
...
### CONF ###
file='users.htpasswd'
update_oc=true
delete_file_on_exit=true
bcrypt_cost=10
...
```
- **file**: The name of the support file that is created by downloading data from the secret
- **update_oc**: If true, changes will be apply to OpenShift. If false, only the support file will be changed.
- **delete_file_on_exit**: If true, the support file (htpasswd file) will be delete on exit. if you need to change file manually you can set it to false and the file will be available on working directory. The file is always created with `0600` permissions and is removed on exit, including when the script is interrupted with Ctrl+C.
- **bcrypt_cost**: The bcrypt work factor (4-17). Higher is slower to compute and slower to attack.

## Usage
Run the script and follow the interactive menu
```
./htpasswd_users.sh
```




