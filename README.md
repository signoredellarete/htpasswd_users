# htpasswd_users
OpenShift HTPasswd identity provider - Users management

## Introduction
> Warning!!!
We recommend that you follow the official OpenShift Red Hat guide to configure HTPasswd identityProvider:
https://docs.openshift.com/container-platform/4.14/authentication/identity_providers/configuring-htpasswd-identity-provider.html

This script was tested on OpenShift 4.14 and works only if the identityProvider HTPasswd is enabled.

Enabling it takes two separate objects, and the order matters. The `OAuth` manifest only *references* the secret holding the htpasswd file, it does not create it, and the script expects that secret to already exist: it downloads it, edits it and writes it back. Create the secret first.

**1. Create the secret**, with a first user in it. The key inside the secret must be named `htpasswd`:
```
htpasswd -cbB users.htpasswd admin 'ChooseAPassword'
oc create secret generic htpass-secret \
  --from-file=htpasswd=users.htpasswd \
  -n openshift-config
rm -f users.htpasswd
```

If `htpasswd` is not installed on the host, the same file can be produced with `perl`, the way the script itself does it when the command is missing:
```
salt=$(perl -e 'open(my $f,"<:raw","/dev/urandom");read($f,my $b,22);
  my @a=(".","/","A".."Z","a".."z","0".."9");
  print join("",map{$a[$_%64]}unpack("C*",$b));')
printf '%s' 'ChooseAPassword' | perl -e 'my $p=do{local $/;<STDIN>};
  print "admin:", crypt($p,$ARGV[0]), "\n";' "\$2b\$10\$${salt}" > users.htpasswd
```

**2. Enable the identityProvider**, with a manifest like this one below as an example:
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

The name under `htpasswd.fileData.name` is the secret created at step 1, and it is the name the script looks up.

Creating a user grants it no permission at all. Roles are assigned separately, for example:
```
oc adm policy add-cluster-role-to-user cluster-admin admin
```

Whenever either object changes the oauth-server pods roll out again, so a new or updated user can take a minute or two before it can actually log in.

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

## Troubleshooting

**`ERROR: cannot read secret 'htpass-secret' in the openshift-config namespace.`**

The secret named by the identity provider could not be read. Either it does not exist, which is what happens when the `OAuth` manifest is applied without creating the secret first, or the account in use is not allowed to read it. To tell the two apart:
```
oc get secret htpass-secret -n openshift-config
oc auth can-i get secret htpass-secret -n openshift-config
```
`NotFound` from the first command means the secret is missing: create it as shown in the Introduction. `no` from the second means the account lacks permissions on secrets in the `openshift-config` namespace.

**`ERROR: no HTPasswd identity provider configured on the 'cluster' OAuth resource.`**

The `OAuth` resource named `cluster` exists but has no identity provider of type `HTPasswd`, so there is no secret for the script to work on. Check it with:
```
oc get oauth cluster -o yaml
```

**`ERROR: several HTPasswd identity providers found`**

More than one HTPasswd identity provider is configured, each with its own secret, and the script cannot tell which one is meant. Set `secret_name` in the script to the one to manage.

**`ERROR: no bcrypt hashing method available.`**

Neither `htpasswd` nor a `perl` able to compute bcrypt was found on the host. See Requirements.




