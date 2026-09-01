#!/bin/bash
#
# htpasswd_users.sh - Manage the users of the OpenShift HTPasswd identity provider.
#
# The htpasswd file is downloaded from the secret referenced by the HTPasswd
# identity provider, edited through an interactive menu, and written back to
# the cluster.
#
# Required commands : oc, awk, mktemp
# Password hashing  : htpasswd (httpd-tools package) or perl, whichever is
#                     available. Only bcrypt hashes are produced.

set -uo pipefail

### CONF ###
# file                : name of the local working copy of the htpasswd file
# update_oc           : whether the secret on the cluster is updated after each change
# delete_file_on_exit : whether the local working copy is removed when the script ends
# bcrypt_cost         : bcrypt work factor, 4 to 17
file='users.htpasswd'
update_oc=true
delete_file_on_exit=true
bcrypt_cost=10

### BINS ###
# Filled in by resolve_bins() with the paths found in PATH.
oc=''
htpasswd=''
perl=''

### VARS ###
basepath=${PWD}
secret_name=''
users=()
username=''
password=''

# Known-answer test vector: a bcrypt-capable crypt() hashes kat_pass with
# kat_salt into exactly kat_hash.
readonly kat_salt='$2b$05$abcdefghijklmnopqrstuu'
readonly kat_pass='openshift-htpasswd-selftest'
readonly kat_hash='$2b$05$abcdefghijklmnopqrstuuOI4DOOJUgpjN/78BtPtPHgaUOKAuajG'

### FUNC ###
# Report an error on stderr and abort.
die(){
  echo "ERROR: $*" >&2
  exit 1
}

# Discard the local htpasswd file and any leftover temporary file. Installed on
# EXIT so that it also runs when the script is interrupted.
cleanup(){
  local rc=$?
  password=''
  rm -f -- "${basepath}/.${file}."* 2>/dev/null
  if [ "${delete_file_on_exit}" = true ] && [ -f "${basepath}/${file}" ];then
    rm -f -- "${basepath}/${file}"
  fi
  return ${rc}
}

# Locate the required commands and choose the hashing backend, preferring
# htpasswd over perl. Sets $oc, $htpasswd and $perl.
resolve_bins(){
  oc=$(command -v oc) || die "'oc' client not found in PATH."
  command -v awk >/dev/null 2>&1 || die "'awk' not found in PATH."
  command -v mktemp >/dev/null 2>&1 || die "'mktemp' not found in PATH."

  htpasswd=$(command -v htpasswd) || htpasswd=''
  perl=$(command -v perl) || perl=''

  if [ -n "${perl}" ] && ! perl_supports_bcrypt;then
    perl=''
  fi

  if [ -z "${htpasswd}" ] && [ -z "${perl}" ];then
    die "no bcrypt hashing method available.
       Install 'httpd-tools' for the htpasswd command, or run this script where
       the crypt() function of perl supports bcrypt (Linux with libxcrypt)."
  fi
}

# Succeed when the crypt() of perl implements bcrypt. A crypt() that does not
# support it accepts a bcrypt salt but returns a hash in a different format, so
# the result is compared against a known vector rather than merely inspected.
perl_supports_bcrypt(){
  local out
  out=$(printf '%s' "${kat_pass}" | "${perl}" -e '
    my $p = do { local $/; <STDIN> };
    my $h = crypt($p, $ARGV[0]);
    print defined($h) ? $h : "";' "${kat_salt}" 2>/dev/null)
  [ "${out}" = "${kat_hash}" ]
}

# Reject a bcrypt_cost setting outside the range the algorithm accepts.
check_bcrypt_cost(){
  case ${bcrypt_cost} in
    ''|*[!0-9]*) die "bcrypt_cost must be an integer." ;;
  esac
  if [ "${bcrypt_cost}" -lt 4 ] || [ "${bcrypt_cost}" -gt 17 ];then
    die "bcrypt_cost must be between 4 and 17 (current value: ${bcrypt_cost})."
  fi
}

# Read the name of the secret holding the htpasswd file from the OAuth resource
# of the cluster. Sets $secret_name. The jsonpath filter keeps only the HTPasswd
# providers, ignoring any other identity provider configured alongside them.
check_identity_provider(){
  secret_name=$("${oc}" get oauth cluster \
    -o jsonpath='{.spec.identityProviders[?(@.type=="HTPasswd")].htpasswd.fileData.name}' 2>/dev/null) \
    || die "cannot read the 'cluster' OAuth resource. Are you logged in to the cluster?"

  if [ -z "${secret_name}" ];then
    die "no HTPasswd identity provider configured on the 'cluster' OAuth resource."
  fi

  # More than one name means more than one HTPasswd provider is configured and
  # there is no way to tell which one is meant.
  case ${secret_name} in
    *[[:space:]]*)
      die "several HTPasswd identity providers found (secrets: ${secret_name}).
       Set secret_name in this script to choose the one to manage." ;;
  esac
}

# Download the htpasswd file from the secret into the working directory. The
# file holds password hashes, hence the owner-only permissions.
get_passwd_file(){
  local content
  content=$("${oc}" get secret "${secret_name}" -n openshift-config \
    -o go-template='{{if .data.htpasswd}}{{index .data "htpasswd" | base64decode}}{{end}}' 2>/dev/null) \
    || die "cannot read secret '${secret_name}' in the openshift-config namespace."

  (
    umask 077
    if [ -n "${content}" ];then
      printf '%s\n' "${content}" > "${basepath}/${file}"
    else
      : > "${basepath}/${file}"
    fi
  ) || die "cannot write ${basepath}/${file}"
}

# Write the local htpasswd file back into the secret on the cluster.
update_oc_secret(){
  if [ "${update_oc}" != true ];then
    echo "update_oc=false: changes applied to the local file only."
    return 0
  fi

  if "${oc}" create secret generic "${secret_name}" \
       --from-file=htpasswd="${basepath}/${file}" \
       --dry-run=client -o yaml -n openshift-config | "${oc}" apply -f - ;then
    echo "Secret '${secret_name}' updated on the cluster."
  else
    echo "ERROR: could not update secret '${secret_name}'." >&2
    return 1
  fi
}

# Print a bcrypt hash of the password passed as $1.
# The password reaches the hashing command through stdin: as an argument it
# would appear in the process table and be readable by any local user.
hash_password(){
  local pass=$1
  local hash='' salt=''

  if [ -n "${htpasswd}" ];then
    # -n prints the result instead of editing a file, -i reads the password
    # from stdin. The output is 'user:hash', of which only the hash is kept.
    hash=$(printf '%s' "${pass}" | "${htpasswd}" -niB -C "${bcrypt_cost}" placeholder 2>/dev/null)
    hash=${hash#*:}
  else
    # A bcrypt salt is exactly 22 characters drawn from './A-Za-z0-9'. Mapping
    # each random byte onto those 64 symbols is unbiased, 256 being a multiple
    # of 64.
    salt=$("${perl}" -e '
      open(my $fh, "<:raw", "/dev/urandom") or die "cannot open /dev/urandom";
      read($fh, my $bytes, 22) == 22 or die "short read from /dev/urandom";
      my @alpha = (".", "/", "A".."Z", "a".."z", "0".."9");
      print join("", map { $alpha[$_ % 64] } unpack("C*", $bytes));' 2>/dev/null)

    if [ ${#salt} -ne 22 ];then
      echo "ERROR: could not generate a salt." >&2
      return 1
    fi

    hash=$(printf '%s' "${pass}" | "${perl}" -e '
      my $p = do { local $/; <STDIN> };
      my $h = crypt($p, $ARGV[0]);
      print defined($h) ? $h : "";' "$(printf '$2b$%02d$%s' "${bcrypt_cost}" "${salt}")" 2>/dev/null)
  fi

  # A malformed hash stored in the file would lock the user out with no visible
  # error, so nothing but a valid bcrypt hash is allowed through.
  if ! is_valid_bcrypt "${hash}";then
    echo "ERROR: the generated hash is not a valid bcrypt hash, aborting." >&2
    return 1
  fi

  printf '%s' "${hash}"
}

# Succeed when $1 is a bcrypt hash: 60 characters, a $2a$/$2b$/$2y$ prefix and
# a two-digit cost.
is_valid_bcrypt(){
  local h=${1-}
  [ ${#h} -eq 60 ] || return 1
  case ${h} in
    \$2[aby]\$[0-9][0-9]\$*) return 0 ;;
    *) return 1 ;;
  esac
}

# Reject usernames the htpasswd format cannot represent: a colon separates the
# username from the hash, and whitespace would make the line ambiguous.
validate_username(){
  local u=${1-}
  if [ -z "${u}" ];then
    echo "The username cannot be empty." >&2
    return 1
  fi
  case ${u} in
    *:*)
      echo "The username cannot contain ':', the htpasswd field separator." >&2
      return 1 ;;
    *[[:space:]]*|*[[:cntrl:]]*)
      echo "The username cannot contain whitespace or control characters." >&2
      return 1 ;;
  esac
  return 0
}

# Set or remove the line of user $1 in the htpasswd file. With a hash in $2 the
# user is added, or updated where it already appears; without it the user is
# removed. awk matches the first field as a literal string, so a username
# holding regular expression metacharacters cannot affect other lines. The new
# content is assembled in a temporary file and moved over the original, so an
# interrupted run cannot leave the htpasswd file truncated.
write_passwd_file(){
  local user=$1
  local hash=${2-}
  local tmp

  tmp=$(mktemp "${basepath}/.${file}.XXXXXX") || return 1

  if ! awk -F: -v u="${user}" -v h="${hash}" '
        $1 == u { if (h != "") { print u ":" h; found = 1 } ; next }
        { print }
        END { if (h != "" && !found) print u ":" h }
      ' "${basepath}/${file}" > "${tmp}";then
    rm -f -- "${tmp}"
    return 1
  fi

  mv -f -- "${tmp}" "${basepath}/${file}" || { rm -f -- "${tmp}"; return 1; }
}

# Succeed when user $1 has a line in the htpasswd file.
user_exists(){
  [ -f "${basepath}/${file}" ] || return 1
  awk -F: -v u="${1}" '$1 == u { found = 1 } END { exit !found }' "${basepath}/${file}"
}

# Fill $users with the usernames in the htpasswd file, keeping the file order.
# Blank and commented lines carry no user.
load_users(){
  local line user
  users=()
  [ -f "${basepath}/${file}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ];do
    case ${line} in
      ''|\#*) continue ;;
    esac
    user=${line%%:*}
    [ -n "${user}" ] && users+=("${user}")
  done < "${basepath}/${file}"
}

# Print the users as a numbered list. The numbers shown are the $users indexes
# that select_user expects.
list_users(){
  local i
  load_users
  echo ""
  if [ ${#users[@]} -eq 0 ];then
    echo "No users in the htpasswd file."
    echo ""
    return 0
  fi
  i=0
  while [ ${i} -lt ${#users[@]} ];do
    echo "$((i + 1))) ${users[${i}]}"
    i=$((i + 1))
  done
  echo ""
}

# Ask for a user from the list printed by list_users. Sets $username, and fails
# when the answer is empty or out of range.
select_user(){
  local index
  username=''

  if [ ${#users[@]} -eq 0 ];then
    return 1
  fi

  read -r -p "Choose the number corresponding to the user (empty to cancel): " index
  if [ -z "${index}" ];then
    echo "Cancelled."
    return 1
  fi

  case ${index} in
    ''|*[!0-9]*)
      echo "Invalid selection." >&2
      return 1 ;;
  esac

  if [ "${index}" -lt 1 ] || [ "${index}" -gt ${#users[@]} ];then
    echo "Invalid selection: choose a number between 1 and ${#users[@]}." >&2
    return 1
  fi

  username=${users[$((index - 1))]}
  return 0
}

# Read a password twice without echoing it, so that a typo cannot silently lock
# the user out. Sets $password.
prompt_password(){
  local prompt=$1
  local pass1 pass2
  password=''

  read -r -s -p "${prompt}: " pass1
  echo ""
  if [ -z "${pass1}" ];then
    echo "The password cannot be empty." >&2
    return 1
  fi

  read -r -s -p "Confirm the password: " pass2
  echo ""
  if [ "${pass1}" != "${pass2}" ];then
    echo "The passwords do not match." >&2
    return 1
  fi

  password=${pass1}
  return 0
}

# Ask the question in $1 and succeed only on an explicit yes.
confirm(){
  local answer
  read -r -p "$1 [y/N]: " answer
  case ${answer} in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# Hold the screen so the outcome of an action stays readable before the menu is
# drawn again.
pause(){
  echo ""
  read -r -p "Press ENTER to return to the menu..." _
}

### ACTIONS ###
# Hash a password for a new user and store it in the htpasswd file.
add_user(){
  local hash
  clear
  echo "Add a user"
  echo ""

  read -r -p "Username: " username
  validate_username "${username}" || return 1

  if user_exists "${username}";then
    echo "User '${username}' already exists. Use option 2 to change the password." >&2
    return 1
  fi

  prompt_password "Password" || return 1

  hash=$(hash_password "${password}") || return 1
  password=''

  write_passwd_file "${username}" "${hash}" || { echo "ERROR: could not write the file." >&2; return 1; }
  echo "User '${username}' added to the file."
  update_oc_secret
}

# Replace the hash of an existing user with the one of a new password.
update_user(){
  local hash
  clear
  echo "Update password for a user"
  list_users
  select_user || return 1

  prompt_password "New password for user '${username}'" || return 1

  hash=$(hash_password "${password}") || return 1
  password=''

  write_passwd_file "${username}" "${hash}" || { echo "ERROR: could not write the file." >&2; return 1; }
  echo "Password updated for user '${username}'."
  update_oc_secret
}

# Drop a user from the htpasswd file, after confirmation.
delete_user(){
  clear
  echo "Delete user"
  list_users
  select_user || return 1

  if ! confirm "Permanently delete user '${username}'?";then
    echo "Cancelled."
    return 1
  fi

  write_passwd_file "${username}" || { echo "ERROR: could not write the file." >&2; return 1; }
  echo "User '${username}' removed from the file."
  update_oc_secret
}

show_users(){
  clear
  echo "List of htpasswd users"
  list_users
}

# Draw the menu, along with the secret being edited and the hashing backend in
# use.
main_menu(){
  local method
  if [ -n "${htpasswd}" ];then
    method="htpasswd (bcrypt, cost ${bcrypt_cost})"
  else
    method="perl crypt() (bcrypt, cost ${bcrypt_cost})"
  fi

  clear
  echo "Manage htpasswd users"
  echo "Secret: ${secret_name}   Hashing: ${method}"
  if [ "${update_oc}" != true ];then
    echo "WARNING: update_oc=false, changes will NOT be applied to the cluster."
  fi
  echo ""
  echo "1) Add a user"
  echo "2) Update password for a user"
  echo "3) Delete a user"
  echo "4) Show users list"
  echo ""
  echo "q) Quit this program"
  echo ""
}

### EXEC ###
# The signal handlers exit rather than clean up themselves, so that the local
# htpasswd file is removed by the single EXIT handler on every path out.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

resolve_bins
check_bcrypt_cost
check_identity_provider
get_passwd_file

# A failed action reports its own error and must not end the session, hence the
# '|| true' before pausing and drawing the menu again.
while true;do
  main_menu
  read -r -p "Choose an option: " option
  case ${option} in
    1) add_user || true; pause ;;
    2) update_user || true; pause ;;
    3) delete_user || true; pause ;;
    4) show_users; pause ;;
    q|Q) exit 0 ;;
    *) ;;
  esac
done
