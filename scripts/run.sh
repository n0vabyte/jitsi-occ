#!/bin/bash
set -e
DEBUG="YES"
if [ "${DEBUG}"s == "NO" ]; then
  trap "cleanup $? $LINENO" EXIT
fi

function cleanup {
  if [ "$?" != "0" ]; then
    echo "PLAYBOOK FAILED. See /var/log/stackscript.log for details."
    rm ${HOME}/.ssh/id_ansible_ed25519{,.pub}
    destroy
    exit 1
  fi
}

# constants
readonly ROOT_PASS=$(sudo cat /etc/shadow | grep root)
readonly LINODE_PARAMS=($(curl -sH "Authorization: Bearer ${TOKEN_PASSWORD}" "https://api.linode.com/v4/linode/instances/${LINODE_ID}" | jq -r .type,.region,.image))
readonly TAGS=$(curl -sH "Authorization: Bearer ${TOKEN_PASSWORD}" "https://api.linode.com/v4/linode/instances/${LINODE_ID}" | jq -r .tags)
readonly VARS_PATH="./group_vars/jitsi/vars"

# utility functions
function destroy {
  if [ -n "${DISTRO}" ] && [ -n "${DATE}" ]; then
    ansible-playbook destroy.yml --extra-vars "instance_prefix=${DISTRO}-${DATE}"
  else
    ansible-playbook destroy.yml
  fi
}

function secrets {
  local SECRET_VARS_PATH="./group_vars/jitsi/secret_vars"
  local VAULT_PASS=$(openssl rand -base64 32)
  local TEMP_ROOT_PASS=$(openssl rand -base64 32)
  echo "${VAULT_PASS}" > ./.vault-pass
  cat << EOF > ${SECRET_VARS_PATH}
`ansible-vault encrypt_string "${TEMP_ROOT_PASS}" --name 'root_pass'`
`ansible-vault encrypt_string "${TOKEN_PASSWORD}" --name 'api_token'`
EOF
}

function ssh_key {
    ssh-keygen -o -a 100 -t ed25519 -C "ansible" -f "${HOME}/.ssh/id_ansible_ed25519" -q -N "" <<<y >/dev/null
    export ANSIBLE_SSH_PUB_KEY=$(cat ${HOME}/.ssh/id_ansible_ed25519.pub)
    export ANSIBLE_SSH_PRIV_KEY=$(cat ${HOME}/.ssh/id_ansible_ed25519)
    export SSH_KEY_PATH="${HOME}/.ssh/id_ansible_ed25519"
    chmod 700 ${HOME}/.ssh
    chmod 600 ${SSH_KEY_PATH}
    eval $(ssh-agent)
    ssh-add ${SSH_KEY_PATH}
    echo -e "\nprivate_key_file = ${SSH_KEY_PATH}" >> ansible.cfg
}

function lint {
  yamllint .
  ansible-lint
  flake8
}

# We don't need a verify right this sec.
#function verify {
#    ansible-playbook -i hosts verify.yml
#    destroy
#}

# production
function ansible:build {
  secrets
  ssh_key
  # write vars file
  sed 's/  //g' <<EOF > ${VARS_PATH}
  # linode vars
  ssh_keys: ${ANSIBLE_SSH_PUB_KEY}
  jitsi_prefix: ${INSTANCE_PREFIX}
  jitsi_type: ${LINODE_PARAMS[0]}
  jvb_prefix: jvb
  jvb_type: ${LINODE_PARAMS[0]}
  region: us-lax
  image: linode/ubuntu22.04
  linode_tags: ${TAGS}
  uuid: ${UUID}
  soa_email_address: ${soa_email_address}
  cluster_size: ${CLUSTER_SIZE}
EOF
}

function ansible:deploy {
  ansible-playbook -v provision.yml
  ansible-playbook -i hosts site.yml -v --extra-vars "root_password=${ROOT_PASS} add_keys_prompt=${ADD_SSH_KEYS} cluster_mode='${CLUSTER_MODE}'"
}

function test:deploy {
  export DISTRO="${1}"
  export DATE="$(date '+%Y-%m-%d-%H%M%S')"
  ansible-playbook provision.yml --extra-vars "ssh_keys=${HOME}/.ssh/id_ansible_ed25519.pub instance_prefix=${DISTRO}-${DATE} image=linode/${DISTRO}"
  ansible-playbook -i hosts site.yml --extra-vars "root_password=${ROOT_PASS}  add_keys_prompt=yes"
  #verify
}

# main
case $1 in
    ansible:build) "$@"; exit;;
    ansible:deploy) "$@"; exit;;
    test:build) "$@"; exit;;
    test:deploy) "$@"; exit;;
esac