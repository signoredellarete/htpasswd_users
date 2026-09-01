# htpasswd_users
OpenShift HTPasswd identity provider - Users management

## Introduction
> Warning!!!
We recommend that you follow the official OpenShift Red Hat guide to configure HTPasswd identityProvider:
https://docs.openshift.com/container-platform/4.14/authentication/identity_providers/configuring-htpasswd-identity-provider.html

This script was tested on OpenShift 4.14 and works only if the identityProvider HTPasswd is enabled.

Enabling it takes two separate objects, and the order matters. The `OAuth` manifest only *references* the secret holding the htpasswd file, it does not create it, and the script expects that secret to already exist: it downloads it, edits it and writes it back. Create the secret first.

**1a. Build the htpasswd file** with a first user in it. With `htpasswd` available, one command is enough, and it asks for the password twice without echoing it:
```
htpasswd -cB users.htpasswd admin
```

Where `htpasswd` is not installed, `perl` produces the same file, the way the script itself does when the command is missing. Paste the whole block, closing brace included, and type the password when prompted:
```
{
  read -r -s -p 'Password: ' pw; echo
  if [ -z "$pw" ]; then
    echo 'ERROR: empty password, nothing written'
  else
    salt=$(perl -e 'open(my $f, "<:raw", "/dev/urandom") or die "urandom: $!";
      read($f, my $b, 22) == 22 or die "short read from urandom";
      my @a = (".", "/", "A".."Z", "a".."z", "0".."9");
      print join("", map { $a[$_ % 64] } unpack("C*", $b));')
    hash=$(printf '%s' "$pw" | perl -e 'my $p = do { local $/; <STDIN> };
      my $h = crypt($p, $ARGV[0]);
      print defined($h) ? $h : "";' "\$2y\$10\$${salt}")
    if [ ${#hash} -eq 60 ]; then
      printf '%s:%s\n' admin "$hash" > users.htpasswd
      echo 'users.htpasswd written'
    else
      echo 'ERROR: this perl cannot compute bcrypt hashes'
    fi
  fi
  unset pw
}
```

The braces are not decoration. Pasted text reaches the shell through the same input the `read` builtin reads from, so without them the prompt would take the next pasted line as the password and store the hash of something nobody typed. Grouping the commands makes the shell parse the whole block before running any of it, leaving the prompt to wait for the keyboard.

The block writes nothing unless it holds a 60 character bcrypt hash of a non-empty password, so a `perl` without bcrypt support stops here instead of producing an unusable file.

The `$2y$` tag is the one `htpasswd` emits and the one the identity provider accepts. The `$2a$`, `$2b$` and `$2y$` variants of bcrypt carry the same digest and differ by that tag alone, so the tag is not interchangeable here even though the cryptography is.

**1b. Create the secret** from that file. This step is needed whichever of the two commands above was used, and the key inside the secret must be named `htpasswd`:
```
oc create secret generic htpass-secret \
  --from-file=htpasswd=users.htpasswd \
  -n openshift-config
rm -f users.htpasswd
```

Check that the secret is there before going on:
```
oc get secret htpass-secret -n openshift-config
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

**`Unrecognized hash type` in the oauth-server logs**

Authentication fails with a line such as `Error authenticating "admin" with provider "htpasswd_provider": Unrecognized hash type`. The stored hash carries a tag the identity provider does not accept, `$2b$` being the usual one. Inspect what is stored with:
```
oc get secret htpass-secret -n openshift-config \
  -o go-template='{{index .data "htpasswd" | base64decode}}'
```
Set the password again for every user whose hash starts with `$2b$`, either through the script or by rebuilding the file as shown in the Introduction. Both write `$2y$`.

**`ERROR: no bcrypt hashing method available.`**

Neither `htpasswd` nor a `perl` able to compute bcrypt was found on the host. See Requirements.




