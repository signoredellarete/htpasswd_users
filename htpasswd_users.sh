#!/bin/bash

### CONF ###
file='users.htpasswd'
update_oc=true
delete_file_on_exit=true

### BINS ###
# htpasswd='/usr/bin/htpasswd'
oc='/usr/local/bin/oc'
base64='/usr/bin/base64'
jq='/usr/bin/jq'
wc='/usr/bin/wc'

### VARS ###
basepath=${PWD}
secret_name=`${oc} get oauth cluster -o=jsonpath='{.spec.identityProviders[*].htpasswd.fileData}' | ${jq} -r '.name'`
index=""
option=""
users=()
username=""
password=""
re='^[0-9]+$'

### FUNC ###
htpasswd() {
  if [ "$1" == "-bB" ]; then
    local file=$2
    local user=$3
    local pass=$4
    local hash=$(printf "%s" "$pass" | openssl dgst -binary -sha1 | openssl base64)
    grep -v "^${user}:" "$file" 2>/dev/null > "$file.tmp" || true
    echo "${user}:{SHA}${hash}" >> "$file.tmp"
    mv "$file.tmp" "$file"
  elif [ "$1" == "-D" ]; then
    local file=$2
    local user=$3
    grep -v "^${user}:" "$file" 2>/dev/null > "$file.tmp" || true
    mv "$file.tmp" "$file"
  else
    echo "Usage:"
    echo "  htpasswd -bB <file> <user> <password>"
    echo "  htpasswd -D <file> <user>"
    return 1
  fi
}


check_identity_provider(){
  if [ -z ${secret_name} ];then
    echo "No secret found for htpasswd identityProvider"
    echo "Check also if htpasswd identityProvider is configured"
    exit 1
  fi
}

get_passwd_file(){
  ${oc} get secret ${secret_name} -ojsonpath={.data.htpasswd} -n openshift-config | ${base64} --decode > ${basepath}/${file}
}

delete_passwd_file(){
  echo ${delete_file}
  if [ -f ${basepath}/${file} ] && [ ${delete_file_on_exit} == true ];then
    rm -f ${basepath}/${file}
  fi
}

update_oc_secret(){
  if [ ${update_oc} == true ];then
    ${oc} create secret generic ${secret_name} --from-file=htpasswd=${basepath}/${file} --dry-run=client -o yaml -n openshift-config | ${oc} apply -f -
  fi
}

update_passwd_file(){
  htpasswd -bB ${basepath}/${file} ${username} ${password} 
}

delete_user_from_file(){
  htpasswd -D ${basepath}/${file} ${username}
}

list_users(){
  counter=1
  echo ""
  while read riga
  do
    user=`echo $riga|cut -d ":" -f 1`
    echo ${counter}") "${user}
    users+=( $user )
    ((counter+=1))
  done < ${basepath}/${file}
  echo ""
}

check_user(){
  if [ -z $index ];then
    echo "Username NOT found"
    exit 1
  fi
  if ! [[ ${index} =~ $re ]] ; then
    echo "Username NOT found"
    exit 1
  else
    ((index-=1))
  fi
  if [ -z ${users[$index]} ];then
    echo "Username NOT found"
    exit 1
  fi
}

main_menu() {
  clear
  echo "Manage htpasswd users"
  echo ""
  echo "1) Add a user"
  echo "2) Update password for a user"
  echo "3) Delete a user"
  echo "4) Show users list"
  echo ""
  echo "q) Quit this program"
  echo ""
  read -p "Choose an option: " option
}

add_user() {
  clear
  echo "Add a user"
  echo ""
  read -p "Username: " username
  read -s -p "Password: " password
  update_passwd_file
  update_oc_secret
  delete_passwd_file
}

update_user() {
  clear
  echo "Update password for a user"
  list_users
  read -p "Choose the number corresponding to the user: " index
  check_user
  username=${users[$index]}
  read -s -p "New password for the user ${users[$index]}: " password
  update_passwd_file
  update_oc_secret
  delete_passwd_file
}

delete_user() {
  clear
  echo "Delete user"
  list_users
  read -p "Choose the number corresponding to the user: " index
  check_user
  username=${users[$index]}
  delete_user_from_file
  update_oc_secret
  delete_passwd_file
}

show_users(){
  clear
  echo "List of htpasswd users"
  list_users
  delete_passwd_file
  exit 0
}

options() {
case ${option} in
  1)
    add_user
    ;;
  2)
    update_user
    ;;
  3)
    delete_user
    ;;
  4)
    show_users
    ;;
  q)
    delete_passwd_file
    exit 0
    ;;
  *)
    main_menu
    options
    ;;
esac
}


### EXEC ###
check_identity_provider
delete_passwd_file
get_passwd_file
main_menu
options
