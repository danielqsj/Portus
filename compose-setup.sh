#!/bin/bash

set -e

check_version() {
    VER=$(docker-compose version | head -n1 | sed s/,//g | awk '{ print $3 }')
    if [ "$VER" = $(echo -e "$VER\n1.6" | sort -V | head -n1) ]; then
        echo "You have to use docker-compose 1.6 or later."
        exit 1
    fi
}

check_mandatory_flags() {
  if [ -z "$EXTERNAL_IP" ]; then
    echo "external ip not set, use the -e flag." >&2
    usage
    exit 1
  fi
}

create_configuration_files() {
  # registry config
  sed -e "s|EXTERNAL_IP|${EXTERNAL_IP}|g" compose/registry/config.yml.template > compose/registry/config.yml

  # compose setup
  sed -e "s|EXTERNAL_IP|${EXTERNAL_IP}|g" compose/docker-compose.yml.template > docker-compose.yml
}

setup_database() {
  set +e

  TIMEOUT=90
  COUNT=0
  RETRY=1

  while [ $RETRY -ne 0 ]; do
    if [ "$COUNT" -ge "$TIMEOUT" ]; then
      printf " [FAIL]\n"
      echo "Timeout reached, exiting with error"
      exit 1
    fi
    echo "Waiting for mariadb to be ready in 5 seconds"
    sleep 5
    COUNT=$((COUNT+5))

    printf "Portus: configuring database..."
    docker-compose run --rm web rake db:migrate:reset > /dev/null
    docker-compose run --rm web rake db:seed > /dev/null

    RETRY=$?
    if [ $RETRY -ne 0 ]; then
        printf " failed, will retry\n"
    fi
  done
  printf " [SUCCESS]\n"
  set -e
}

clean() {
  echo "The setup will destroy the containers used by Portus, removing also their volumes."
  if [ $FORCE -ne 1 ]; then
    while true; do
      read -p "Are you sure to delete all the data? (Y/N) [Y] " yn
      case $yn in
        [Yy]* ) break;;
        [Nn]* ) exit 1;;
        "" ) break;;
        * ) echo "Please answer yes or no.";;
      esac
    done
  fi

  docker-compose kill
  docker-compose rm -fv
}

usage() {
  echo "Usage: $0 [-fo] -e EXTERNAL_IP"
  echo "  -f force removal of data"
  echo "  -e EXTERNAL_IP - the IP or FQDN used to publish Portus and the Docker registry"
}

# Force the current directory to be named "portus". It's known that other
# setups will make docker-compose fail.
#
# See: https://github.com/docker/compose/issues/2092
if [ "${PWD##*/}" != "portus" ] && [ "${PWD##*/}" != "Portus" ]; then
    cat <<HERE
ERROR: docker-compose is not able to tag built images. Since our compose setup
expects the built image be named "portus_web", the current directory has to be
named "portus" in order to work.
HERE
    exit 1
fi

FORCE=0
while getopts "foe:h" opt; do
  case "${opt}" in
    f)
      FORCE=1
      ;;
    e)
      EXTERNAL_IP=$OPTARG
      ;;
    h)
      usage
      exit 0
      ;;
    *)
      echo "Invalid option: -$OPTARG" >&2
      usage
      exit 1
      ;;
  esac
done

cat <<EOM

###########
# WARNING #
###########

This deployment method is intended for testing/development purposes.
To deploy Portus on production please take a look at: http://port.us.org/documentation.html

EOM
sleep 2

check_mandatory_flags
check_version
create_configuration_files
clean
docker-compose up -d

setup_database

cat <<EOM

###################
#     SUCCESS     #
###################

EOM

echo "Make sure port 3000 and 5000 are open on host ${EXTERNAL_IP}"
printf "\n"

echo "Open http://${EXTERNAL_IP}:3000 with your browser and perform the following steps:"
printf "\n"
echo "  1. Create an admin account"
echo "  2. You will be redirected to a page where you have to register the registry. In this form:"
echo "    - Choose a custom name for the registry."
echo "    - Enter ${EXTERNAL_IP}:5000 as the hostname."
echo "    - Do *not* check the \"Use SSL\" checkbox, since this setup is not using SSL."
printf "\n"

echo "Perform the following actions on the docker hosts that need to interact with your registry:"
printf "\n"
echo "  - Ensure the docker daemon is started with the '--insecure-registry ${EXTERNAL_IP}:5000'"
echo "  - Perform the docker login."
printf "\n"
echo "To authenticate against your registry using the docker cli do:"
printf "\n"
echo "  $ docker login -u <portus username> -p <password> -e <email> ${EXTERNAL_IP}:5000"
printf "\n"

echo "To push an image to the private registry:"
printf "\n"
echo "  $ docker pull busybox"
echo "  $ docker tag busybox ${EXTERNAL_IP}:5000/<username>busybox"
echo "  $ docker push ${EXTERNAL_IP}:5000/<username>busybox"
