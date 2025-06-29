#!/bin/bash
set -e

# WARNING!!! THIS SCRIPT SHOULD NOT BE MODIFIED,
# PLEASE CONFIGURE YOUR INSTALLATION ONLY USING THE DOCUMENTED PARAMETERS.

# ECE version
CLOUD_ENTERPRISE_VERSION=4.0.1
# Default Docker registry
DOCKER_REGISTRY=docker.elastic.co

# Default Docker namespace
LATEST_VERSIONS_DOCKER_NAMESPACE="cloud-release"
LATEST_STACK_PRE_RELEASE=""

PREVIOUS_VERSIONS_DOCKER_NAMESPACE="cloud-release"
PREVIOUS_STACK_PRE_RELEASE=""

# Default Docker repository for ECE image
ECE_DOCKER_REPOSITORY=cloud-enterprise

# Default host storage path
HOST_STORAGE_PATH=/mnt/data/elastic

# Get from the client or assume a default location
HOST_DOCKER_HOST=${DOCKER_HOST:-/var/run/docker.sock}

# Enables bootstrapping a client forwarder that uses a tag for the observers
CLIENT_FORWARDER_OBSERVERS_TAG=${CLIENT_FORWARDER_OBSERVERS_TAG:-}

# This flag allows to skip the validation of ECE - OS - Docker/Podman versions in situations where the ECE image uses a non-standard version tag.
SKIP_CLOUD_ENTERPRISE_VERSION_CHECK=${SKIP_CLOUD_ENTERPRISE_VERSION_CHECK:-false}

# Colour codes
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Exit codes
GENERAL_ERROR_EXIT_CODE=1         # General errors. All errors other than the ones related to either argument or command
UNKNOWN_COMMAND_EXIT_CODE=2       # Unknown command
INVALID_ARGUMENT_EXIT_CODE=3      # Unknown argument or argument's value is not specified
NON_VALID_USER_EXIT_CODE=4        # When starting the installer with a non-valid uid, gid, or group membership
PRECONDITION_NOT_MET_EXIT_CODE=5  # Pre-condition checks that error

# Resource mounting optiong - for SELinux compatibility (RHEL / Podman).
RESOURCE_MOUNTING_OPTIONS=""
USE_SELINUX=false

# Flag to use when we want the prerequisites to run but not exit when fail
FORCE_INSTALL=false

# Helper flag to indicate that there were failed prerequisites at the host level
HOST_PREREQ_FAILED=false

# Use docker by default, podman if specified
CONTAINER_ENGINE=docker

# By default, when upgrading the platform, upgrader will fail if there are any in flight.
SKIP_PENDING_PLAN_CHECK=false

ENABLE_DEBUG_LOGGING=false

OVERWRITE_EXISTING_IMAGE=false

FORCE_UPGRADE=false

TIMEOUT_FACTOR=1.0

SECRETS_RELATIVE_PATH="/bootstrap-state/bootstrap-secrets.json"

COMMAND=""

COMMAND=help
if [ $# -gt 0 ]; then
    COMMAND=$1
fi

case $COMMAND in
  install )                         shift
                                    ;;
  reset-adminconsole-password )     shift
                                    ;;
  add-stack-version )               shift
                                    ;;
  upgrade )                         shift
                                    ;;
  configure-selinux-settings )      shift
                                    ;;
  --help|help )
      echo "================================================================================================"
      echo " Elastic Cloud Enterprise Installation Script v$CLOUD_ENTERPRISE_VERSION"
      echo "================================================================================================"
      echo ""
      echo "${0##*/} [COMMAND] {OPTIONS}"
      echo ""
      echo "Available commands:"
      echo "  install                        Installs Elastic Cloud Enterprise on the host"
      echo "                                 This is the default command"
      echo ""
      echo "  upgrade                        Upgrades the Elastic Cloud Enterprise installation to $CLOUD_ENTERPRISE_VERSION"
      echo ""
      echo "  reset-adminconsole-password    Resets the password for an administration console user"
      echo ""
      echo "  add-stack-version              Make a new Elastic Stack version available"
      echo ""
      echo "  configure-selinux-settings     Prepares the host for SELinux"
      echo ""
      echo "For available arguments run command with '--help' argument"
      echo "================================================================================================"
      exit 0
      ;;
  *)
    if [[ $1 == --* ]]; then
      COMMAND="install"
    else
      echo -e "${RED}Unknown command '$COMMAND'${NC}"
      exit $UNKNOWN_COMMAND_EXIT_CODE
    fi
    ;;
esac

# Checks 3rd parameter (argument' value) for empty string or a string that starts with '--'
# if the string meet the conditions, the function forces the script to exit with code 3
# Otherwise, it assigns the argument's value to a variable whose name is passed as the first parameter
# Parameters:
#  $1 - a name of variable to assign the argument's value to
#  $2 - a name of the argument
#  $3 - argument's value
setArgument() {
  if [[ $3 == --* ]] || [[ -z "${3}" ]]; then
    echo -e "${RED}Argument '$2' does not have a value${NC}"
    exit $INVALID_ARGUMENT_EXIT_CODE
  else
    local  __resultvar=$1
    eval $__resultvar="'$3'"
  fi
}

# Same as the setArgument but perform some filtering on the input value before
# doing any assignment
setArgumentWithFilter() {
  local _value=$3
  if [[ "${_value}" == *"unix://"* ]]; then
    local _value=${_value:7}
  fi
  setArgument $1 $2 ${_value}
}

# Verify that the running user has an allowable UID (not in the
# reserved range of 0-999) in order to avoid UID collision with the
# internal docker image's users. Additionally, verify that the user is
# a member of the docker group (or can run docker commands).
validateRunningUser(){
  local uuid=$(id -ru)
  local guid=$(id -rg)
  if [[ $uuid -lt 1000 || $guid -lt 1000 ]]; then
    # Only stating the problem. Don't want to suggest the user modifies UIDs or GIDs
    echo -e "${RED}The UID or GID must not be smaller than 1000.${NC}"
    exit $NON_VALID_USER_EXIT_CODE
  fi

  # check whether they can successfully run a trivial docker command
  local can_run_docker=false
  if docker ps > /dev/null 2>&1; then
    can_run_docker=true
  fi

  # check whether they're actually in the literal docker group
  local docker_group=$(id -nG | grep -E '(^|\s)docker($|\s)')
  local is_in_docker_group=false
  if [ -n "$docker_group" ]; then
    is_in_docker_group=true
  fi

  if [[ "$can_run_docker" == "false" ]]; then
    if [[ "$is_in_docker_group" == "false" ]]; then
      echo -e "${YELLOW}The user is not a member of the docker group.${NC}"
    fi

    if [[ "${FORCE_INSTALL}" == "false" ]]; then
      echo -e "${RED}To resolve the issue, add the user to the docker group or install as a different user.${NC}"
      exit $NON_VALID_USER_EXIT_CODE
    fi
  fi
}

dockerCmdViaSocket() {
    case "$CONTAINER_ENGINE" in
        docker )  docker -H "unix://${HOST_DOCKER_HOST}" "$@"
                  ;;
        podman )  podman-remote --url "unix://${HOST_DOCKER_HOST}" "$@"
                  ;;
        *)        echo -e "${RED}Unknown argument '$1'${NC}"
                  exit $INVALID_ARGUMENT_EXIT_CODE
                  ;;
    esac
}

parseInstallArguments() {
  while [ "$1" != "" ]; do
    case $1 in
      --coordinator-host )            setArgument COORDINATOR_HOST $1 $2
                                      shift
                                      ;;
      --host-docker-host )            setArgumentWithFilter HOST_DOCKER_HOST $1 $2
                                      shift
                                      ;;
      --host-storage-path )           setArgument HOST_STORAGE_PATH $1 $2
                                      shift
                                      ;;
      --cloud-enterprise-version )    if [[ $(compareVersions $2 $CLOUD_ENTERPRISE_VERSION) -eq 1 ]]
                                      then
                                        echo "Can't use a --cloud-enterprise-version value greater than $CLOUD_ENTERPRISE_VERSION. In order to install a higher version of ECE, download the latest installation script."
                                        exit 1
                                      fi
                                      setArgument CLOUD_ENTERPRISE_VERSION $1 $2
                                      shift
                                      ;;
      --debug )                       ENABLE_DEBUG_LOGGING=true
                                      ;;
      --docker-registry )             setArgument DOCKER_REGISTRY $1 $2
                                      shift
                                      ;;
      --latest-stack-pre-release )    setArgument LATEST_STACK_PRE_RELEASE $1 $2
                                      if [[ ${LATEST_STACK_PRE_RELEASE::1} != "-" ]]
                                      then
                                        LATEST_STACK_PRE_RELEASE="-"$LATEST_STACK_PRE_RELEASE; fi
                                      shift
                                      ;;
      --previous-stack-pre-release )  setArgument PREVIOUS_STACK_PRE_RELEASE $1 $2
                                      if [[ ${PREVIOUS_STACK_PRE_RELEASE::1} != "-" ]]
                                      then
                                      PREVIOUS_STACK_PRE_RELEASE="-"$PREVIOUS_STACK_PRE_RELEASE; fi
                                      shift
                                      ;;
      --ece-docker-repository )       setArgument ECE_DOCKER_REPOSITORY $1 $2
                                      shift
                                      ;;
      --overwrite-existing-image )    OVERWRITE_EXISTING_IMAGE=true
                                      ;;
      --runner-id )                   setArgument RUNNER_ID $1 $2
                                      shift
                                      ;;
      --roles )                       setArgument RUNNER_ROLES $1 $2
                                      shift
                                      ;;
      --roles-token )                 setArgument RUNNER_ROLES_TOKEN $1 $2
                                      shift
                                      ;;
      --host-ip )                     setArgument HOST_IP $1 $2
                                      shift
                                      ;;
      --external-hostname )           setArgument RUNNER_EXTERNAL_HOSTNAME $1 $2
                                      shift
                                      ;;
      --availability-zone )           setArgument AVAILABILITY_ZONE $1 $2
                                      shift
                                      ;;
      --capacity )                    setArgument CAPACITY $1 $2
                                      shift
                                      ;;
      --memory-settings )             setArgument MEMORY_SETTINGS $1 $2
                                      shift
                                      ;;
      --environment-metadata )        setArgument RUNNER_ENVIRONMENT_METADATA_JSON $1 $2
                                      shift
                                      ;;
      --config-file )                 setArgument CONFIG_FILE $1 $2
                                      shift
                                      ;;
      --client-forwarder-observers-tag )              setArgument CLIENT_FORWARDER_OBSERVERS_TAG $1 $2
                                      shift
                                      ;;
      --allocator-tags )              setArgument ALLOCATOR_TAGS $1 $2
                                      shift
                                      ;;
      --proxy-tags )                  setArgument PROXY_TAGS $1 $2
                                      shift
                                      ;;
      --timeout-factor )              setArgument TIMEOUT_FACTOR $1 $2
                                      shift
                                      ;;
      --force )                       FORCE_INSTALL=true
                                      ;;
      --api-base-url )                setArgument API_BASE_URL $1 $2
                                      shift
                                      ;;
      --podman )                      CONTAINER_ENGINE=podman
                                      ;;
      --skip-cloud-enterprise-version-check ) SKIP_CLOUD_ENTERPRISE_VERSION_CHECK=true
                                      ;;
      --selinux )                     USE_SELINUX=true
                                      ;;
      --help|help)
                        echo "Installs Elastic Cloud Enterprise according to the specified parameters, "
                        echo "both to start a new installation and to add hosts to an existing installation."
                        echo "Can be used to automate installation or to customize how you install platform."
                        echo ""
                        echo "elastic-cloud-enterprise.sh install [--coordinator-host C_HOST_IP]"
                        echo "[--host-docker-host HOST_DOCKER_HOST] [--host-storage-path PATH_NAME]"
                        echo "[--cloud-enterprise-version VERSION_NAME] [--debug] [--docker-registry DOCKER_REGISTRY]"
                        echo "[--overwrite-existing-image] [--runner-id ID] [--host-ip HOST_IP]"
                        echo "[--availability-zone ZONE_NAME] [--capacity MB_VALUE] [--memory-settings JVM_SETTINGS]"
                        echo "[--roles-token TOKEN] [--roles \"ROLES\"] [--force] [--api-base-url API_BASE_URL] [--podman]"
                        echo "[--selinux]"
                        echo ""
                        echo "Arguments:"
                        echo "--coordinator-host         Specifies the IP address of the first host used to"
                        echo "                           start a new Elastic Cloud Enterprise installation."
                        echo "                           Must be specified when installing on additional"
                        echo "                           hosts to add them to an existing installation."
                        echo ""
                        echo "--host-docker-host         Set the docker's docker-host location"
                        echo "                           Defaults to /var/run/docker.sock"
                        echo ""
                        echo "--host-storage-path        Specifies the host storage path used by "
                        echo "                           the installation."
                        echo "                           Defaults to '$HOST_STORAGE_PATH'"
                        echo ""
                        echo "--cloud-enterprise-version Specifies the version of Elastic Cloud Enterprise "
                        echo "                           to install."
                        echo "                           Defaults to '$CLOUD_ENTERPRISE_VERSION'"
                        echo ""
                        echo "--debug                    Outputs debugging information during installation."
                        echo "                           Defaults to false."
                        echo ""
                        echo "--allocator-tags           Specifies a comma delimited string of tags that are assigned"
                        echo "                           to this allocator."
                        echo "                           The format for ALLOCATOR_TAGS is tag_name:tag_value,tag_name:tag_value"
                        echo "                           Defaults to ''."
                        echo ""
                        echo "--timeout-factor           Multiplies timeouts used during installation by this number."
                        echo "                           Use if installation fails due to timeout."
                        echo "                           Defaults to $TIMEOUT_FACTOR."
                        echo ""
                        echo "--docker-registry          Specifies the Docker registry for the Elastic "
                        echo "                           Cloud Enterprise assets."
                        echo "                           Defaults to '$DOCKER_REGISTRY'"
                        echo ""
                        echo "--overwrite-existing-image Overwrites any existing local image when retrieving"
                        echo "                           the Elastic Cloud Enterprise installation image from"
                        echo "                           the Docker repository."
                        echo "                           Defaults to false."
                        echo ""
                        echo "--runner-id                Assigns an arbitrary ID to the host (runner) that you"
                        echo "                           are installing Elastic Cloud Enterprise on."
                        echo "                           Defaults to 'host-ip'"
                        echo ""
                        echo "--host-ip                  Specifies an IP address for the host that you are"
                        echo "                           installing Elastic Cloud Enterprise on. Used for"
                        echo "                           internal communication within the cluster. This must"
                        echo "                           be a routable IP in your network."
                        echo "                           Defaults to the IP address for the network interface"
                        echo ""
                        echo "--availability-zone        Specifies an availability zone for the host that you"
                        echo "                           are installing Elastic Cloud Enterprise on."
                        echo "                           Defaults to 'ece-zone-1'"
                        echo ""
                        echo "--capacity                 Specifies the amount of RAM in megabytes this runner"
                        echo "                           makes available for Elasticsearch clusters."
                        echo "                           Must be at least 8192 MB."
                        echo "                           Defaults to 85% of available RAM, if the remaining 15%"
                        echo "                           is less than 28GB. Otherwise, 28GB is subtracted from the"
                        echo "                           total and the remainder is used."
                        echo "                           if you specified --roles allocator 12GB is subtracted "
                        echo "                           instead of 28GB"
                        echo ""
                        echo "--memory-settings          Specifies a custom JVM setting for a service, such as"
                        echo "                           heap size. Settings must be specified in JSON format."
                        echo ""
                        echo "--roles-token              Specifies a token that enables the host to join an"
                        echo "                           existing Elastic Cloud Enterprise installation."
                        echo "                           Required when '--coordinator-host' is also specified."
                        echo ""
                        echo "--roles                    Assigns a comma-separated list of runner roles to the"
                        echo "                           host during installation."
                        echo "                           Supported: director, coordinator, allocator, proxy"
                        echo ""
                        echo "--force                    Checks the installation requirements, but does not "
                        echo "                           exit the installation process if a check fails. "
                        echo "                           If not specified, a failed installation check "
                        echo "                           causes the installation process to exit"
                        echo ""
                        echo "--external-hostname        Comma separated list of names to include in the SAN"
                        echo "                           extension of the self generated TLS certificates for HTTP. "
                        echo ""
                        echo "--api-base-url             Specifies the base URL for the API. Used for determining"
                        echo "                           the ServiceProvider-initiated login redirect endpoint"
                        echo "                           This must be externally accessible."
                        echo "                           Defaults to 'https://api-docker-host-ip:12300'"
                        echo ""
                        echo "--podman                   Use podman as container engine instead of docker"
                        echo ""
                        echo "--selinux                  Setup ECE to run with SELinux enabled (only valid when used with --podman)"
                        echo ""
                        echo "For the full description of every command see documentation"
                        echo ""
                        exit 0
                        ;;
       *)  echo -e "${RED}Unknown argument '$1'${NC}"
           exit $INVALID_ARGUMENT_EXIT_CODE
           ;;
    esac
    shift
  done
}

parseResetAdminconsolePasswordArguments() {
  SOURCE_CONTAINER_NAME="frc-runners-runner"
  ZK_ROOT_PASSWORD=""
  USER=""
  NEW_PWD=""

  while [ "$1" != "" ]; do
    case $1 in
        --host-docker-host )          setArgumentWithFilter HOST_DOCKER_HOST $1 $2
                                      shift
                                      ;;
        --podman )                    CONTAINER_ENGINE=podman
                                      ;;
        --secrets )                   setArgument BOOTSTRAP_SECRETS $1 $2
                                      BOOTSTRAP_SECRETS=$(cd "$(dirname "$BOOTSTRAP_SECRETS")"; pwd)/$(basename "$BOOTSTRAP_SECRETS")
                                      shift
                                      ;;
        --pwd )                       setArgument NEW_PWD $1 $2
                                      NEW_PWD="--pwd $NEW_PWD"
                                      shift
                                      ;;
        --user )                      setArgument USER $1 $2
                                      USER="--user $USER"
                                      shift
                                      ;;
        --host-storage-path )         setArgument HOST_STORAGE_PATH $1 $2
                                      shift
                                      ;;
        --podman )                    CONTAINER_ENGINE=podman
                                      ;;
        --help|help )     echo "============================================================================================="
                          echo "Reset the password for an administration console user."
                          echo "The script should be run on either the first host you installed Elastic Cloud"
                          echo "Enterprise on or a host that holds the director role."
                          echo ""
                          echo "${0##*/} reset-adminconsole-password [--host-docker-host HOST_DOCKER_HOST] [--user USER_NAME]"
                          echo "[--pwd NEW_PASSWORD] [--host-storage-path PATH_NAME] [--secrets PATH_TO_SECRETS_FILE] [--podman]"
                          echo "[[--]help]"
                          echo ""
                          echo "Arguments:"
                          echo ""
                          echo "--host-docker-host   Set the docker's docker-host location"
                          echo "                     Defaults to /var/run/docker.sock"
                          echo ""
                          echo "--user               Specifies the name of a user whose password needs to be"
                          echo "                     changed. Defaults to 'admin'"
                          echo ""
                          echo "--pwd                Specifies a new password for the selected user. If it is"
                          echo "                     not specified, a new password will be generated"
                          echo ""
                          echo "--host-storage-path  Specifies the host storage path used by the Elastic Cloud"
                          echo "                     Enterprise installation. It is used for calculating"
                          echo "                     a location of the default file with secrets as well as"
                          echo "                     location of a log file."
                          echo "                     Defaults to '$HOST_STORAGE_PATH'"
                          echo ""
                          echo "--secrets            Specifies a path to a file with secrets. The file will be"
                          echo "                     updated with a new password."
                          echo "                     Defaults to '\$HOST_STORAGE_PATH$SECRETS_RELATIVE_PATH'"
                          echo ""
                          echo "--podman             Use podman as container engine instead of docker"
                          echo ""
                          echo "Example:"
                          echo "${0##*/} reset-adminconsole-password --user admin --pwd new-very-strong-password"
                          echo ""
                          exit 0
                          ;;
       *)  echo -e "${RED}Unknown argument '$1'${NC}"
           exit $INVALID_ARGUMENT_EXIT_CODE
           ;;
    esac
    shift
  done

  DEFAULT_BOOTSTRAP_SECRETS="$HOST_STORAGE_PATH$SECRETS_RELATIVE_PATH"

  if [[ -z "$BOOTSTRAP_SECRETS" ]]; then
      # if neither bootstrap secrets file nor root password are specified, try find secrets file by the default path
      if [[ -e "$DEFAULT_BOOTSTRAP_SECRETS" ]]; then
        echo -e "A bootstrap secrets file was found using the default path${NC}"
        BOOTSTRAP_SECRETS=$DEFAULT_BOOTSTRAP_SECRETS
      fi
  else
      if [[ ! -e "$BOOTSTRAP_SECRETS" ]]; then
        echo -e "${RED}A bootstrap secrets file was not found using path '$BOOTSTRAP_SECRETS'${NC}"
        exit $INVALID_ARGUMENT_EXIT_CODE
      fi

      if [[ ! -r ${BOOTSTRAP_SECRETS} ]]; then
        echo -e "${RED}Secrets file '${BOOTSTRAP_SECRETS}' doesn't have read permissions for the current user.${NC}"
        exit $INVALID_ARGUMENT_EXIT_CODE
      fi
  fi

  if [[ -z "$BOOTSTRAP_SECRETS" ]]; then
      # pull password for zookeeper from director's container
      ZK_ROOT_PASSWORD=$(dockerCmdViaSocket exec frc-directors-director bash -c 'echo -n $FOUND_ZK_READWRITE' 2>/dev/null | cut -d: -f 2)
      if [[ -z "$ZK_ROOT_PASSWORD" ]]; then
        echo -e "${RED}Failed to get access to Elastic Cloud Enterprise.${NC}"
        echo -e "Please meet at least one of the following requirements:"
        echo -e " - Run the script on the first host you installed Elastic Cloud Enterprise on"
        echo -e "   using either default or custom path to secrets file"
        echo -e " - Run the script on an Elastic Cloud Enterprise host that holds"
        echo -e "   the director role"
        exit $INVALID_ARGUMENT_EXIT_CODE
      else
        echo -e "Use director's settings to access Elastic Cloud Enterprise environment"
      fi
  fi
}

ensureUserPasswordOrSecretsFile() {
  DEFAULT_BOOTSTRAP_SECRETS="$HOST_STORAGE_PATH$SECRETS_RELATIVE_PATH"

  if [[ -z "$BOOTSTRAP_SECRETS" ]]; then
      # if neither bootstrap secrets file nor root password are specified, try find secrets file by the default path
      if [[ -e "$DEFAULT_BOOTSTRAP_SECRETS" ]] && [[ -z "$PASS" ]]; then
        echo -e "${YELLOW}A bootstrap secrets file was found using the default path${NC}"
        BOOTSTRAP_SECRETS=$DEFAULT_BOOTSTRAP_SECRETS
      fi
  else
      if [[ ! -e "$BOOTSTRAP_SECRETS" ]]; then
        echo -e "${RED}A bootstrap secrets file was not found using path '$BOOTSTRAP_SECRETS'${NC}"
        exit $INVALID_ARGUMENT_EXIT_CODE
      fi

      if test ! -r ${BOOTSTRAP_SECRETS}; then
        echo -e "${RED}Secrets file '${BOOTSTRAP_SECRETS}' doesn't have read permissions for the current user.${NC}"
        exit $INVALID_ARGUMENT_EXIT_CODE
      fi

      PASS=""
  fi

  if [[ -z "$PASS" ]] && [[ -z "$BOOTSTRAP_SECRETS" ]]; then
      echo -e "${RED}No password specified, and could not source a secrets file.${NC}"
      exit $INVALID_ARGUMENT_EXIT_CODE
  fi
}


parseUpgradeArguments() {
  OVERWRITE_EXISTING_IMAGE=false
  USER="admin"
  PASS=""

  while [ "$1" != "" ]; do
    case $1 in
        --debug )                     ENABLE_DEBUG_LOGGING=true
                                      ;;
        --host-docker-host )          setArgumentWithFilter HOST_DOCKER_HOST $1 $2
                                      shift
                                      ;;
        --docker-registry )           setArgument DOCKER_REGISTRY $1 $2
                                      shift
                                      ;;
        --ece-docker-repository )     setArgument ECE_DOCKER_REPOSITORY $1 $2
                                      shift
                                      ;;
        --latest-stack-pre-release )  setArgument LATEST_STACK_PRE_RELEASE $1 $2
                                      if [[ ${LATEST_STACK_PRE_RELEASE::1} != "-" ]]
                                      then
                                        LATEST_STACK_PRE_RELEASE="-"$LATEST_STACK_PRE_RELEASE; fi
                                      shift
                                      ;;
      --previous-stack-pre-release )  setArgument PREVIOUS_STACK_PRE_RELEASE $1 $2
                                      if [[ ${PREVIOUS_STACK_PRE_RELEASE::1} != "-" ]]
                                      then
                                      PREVIOUS_STACK_PRE_RELEASE="-"$PREVIOUS_STACK_PRE_RELEASE; fi
                                      shift
                                      ;;
        --overwrite-existing-image )  OVERWRITE_EXISTING_IMAGE=true
                                      ;;
        --skip-pending-plan-check )   SKIP_PENDING_PLAN_CHECK=true
                                      ;;
        --cloud-enterprise-version )  if [[ $(compareVersions $2 $CLOUD_ENTERPRISE_VERSION) -eq 1 ]]
                                      then
                                        echo "Can't use a --cloud-enterprise-version value greater than $CLOUD_ENTERPRISE_VERSION. In order to install a higher version of ECE, download the latest installation script."
                                      fi
                                      setArgument CLOUD_ENTERPRISE_VERSION $1 $2
                                      shift
                                      ;;
        --timeout-factor )            setArgument TIMEOUT_FACTOR $1 $2
                                      shift
                                      ;;
        --api-base-url )              setArgument API_BASE_URL $1 $2
                                      shift
                                      ;;
        --user )                      setArgument USER $1 $2
                                      shift
                                      ;;
        --secrets )                   setArgument BOOTSTRAP_SECRETS $1 $2
                                      BOOTSTRAP_SECRETS=$(cd "$(dirname "$BOOTSTRAP_SECRETS")"; pwd)/$(basename "$BOOTSTRAP_SECRETS")
                                      shift
                                      ;;
        --pass )                      setArgument PASS $1 $2
                                      shift
                                      ;;
        --podman )                    CONTAINER_ENGINE=podman
                                      ;;
        --selinux )                   USE_SELINUX=true
                                      ;;
        --force-upgrade )             FORCE_UPGRADE=true
                                      ;;
        --skip-cloud-enterprise-version-check ) SKIP_CLOUD_ENTERPRISE_VERSION_CHECK=true
                                              ;;
        --help|help )     echo "=========================================================================================="
                          echo "Upgrades current Elastic Cloud Installation to version $CLOUD_ENTERPRISE_VERSION."
                          echo "The script should be run on either the first host you installed Elastic Cloud"
                          echo "Enterprise on or a host that holds the director role."
                          echo ""
                          echo "${0##*/} upgrade [--host-docker-host HOST_DOCKER_HOST] [--docker-registry DOCKER_REGISTRY]"
                          echo "[--overwrite-existing-image]  [--skip-pending-plan-check] [--debug] [--api-base-url API_BASE_URL]"
                          echo "[--podman] [--selinux] [[--]help]"
                          echo ""
                          echo "Arguments:"
                          echo ""
                          echo ""
                          echo "--host-docker-host         Set the docker's docker-host location"
                          echo "                           Defaults to /var/run/docker.sock"
                          echo ""
                          echo "--docker-registry          Specifies the Docker registry for the Elastic "
                          echo "                           Cloud Enterprise assets."
                          echo "                           Defaults to '$DOCKER_REGISTRY'"
                          echo ""
                          echo "--overwrite-existing-image If specified, overwrites any existing local image when"
                          echo "                           retrieving the Elastic Cloud Enterprise installation"
                          echo "                           image from the repository."
                          echo ""
                          echo "--skip-pending-plan-check  Forces upgrade to proceed if there are pending plans found before install."
                          echo "                           Defaults to false."
                          echo ""
                          echo "--debug                    If specified, outputs debugging information during"
                          echo "                           upgrade"
                          echo ""
                          echo "--timeout-factor           Multiplies timeouts used during upgrade by this number."
                          echo "                           Use if upgrade fails due to timeout."
                          echo "                           Defaults to $TIMEOUT_FACTOR."
                          echo ""
                          echo "--api-base-url             Specifies the base URL for the API. Used for determining"
                          echo "                           the ServiceProvider-initiated login redirect endpoint"
                          echo "                           This must be externally accessible."
                          echo "                           Defaults to 'https://api-docker-host-ip:12300'"
                          echo ""
                          echo "--podman                   Use podman as container engine instead of docker."
                          echo ""
                          echo "--selinux                  Set ECE to run with SELinux enabled (only relevant when used with --podman)."
                          echo ""
                          echo "--force-upgrade            Makes the ECE upgrader overwrite any remaining status from "
                          echo "                           ongoing previous upgrades. If not specified, the ECE upgrader "
                          echo "                           will re-attach to the existing upgrade process. "
                          echo "                           Useful e.g. in cases when previous upgrades got stuck due to "
                          echo "                           infrastructure problems and can't be resumed."
                          echo ""
                          echo "--secrets                  Specifies a path to a file with secrets."
                          echo "                           Defaults to '$HOST_STORAGE_PATH$SECRETS_RELATIVE_PATH'"
                          echo ""
                          echo "--user                     The user to authenticate to the adminconsole."
                          echo "                           Defaults to 'admin'"
                          echo ""
                          echo "--pass                     Password to auth as to the adminconsole. If it is"
                          echo "                           not specified, the password is sourced from the secrets file."
                          echo ""
                          echo "Example:"
                          echo "${0##*/} upgrade"
                          echo ""
                          exit 0
                          ;;
       *)  echo -e "${RED}Unknown argument '$1'${NC}"
           exit $INVALID_ARGUMENT_EXIT_CODE
           ;;
    esac
    shift
  done

  SOURCE_CONTAINER_NAME="frc-runners-runner"
  HOST_STORAGE_PATH=$(dockerCmdViaSocket exec $SOURCE_CONTAINER_NAME bash -c 'echo -n $HOST_STORAGE_PATH' 2>/dev/null | cut -d: -f 2)
  if [[ -z "${HOST_STORAGE_PATH}" ]]; then
      echo -e "${RED}Container $SOURCE_CONTAINER_NAME was not found -- is the environment running?${NC}"
      exit $GENERAL_ERROR_EXIT_CODE
  fi

  SOURCE_CONTAINER_NAME="frc-directors-director"
  ZK_ROOT_PASSWORD=$(dockerCmdViaSocket exec $SOURCE_CONTAINER_NAME bash -c 'echo -n $FOUND_ZK_READWRITE' 2>/dev/null | cut -d: -f 2)
  if [[ -z "${ZK_ROOT_PASSWORD}" ]]; then
      echo -e "${RED}Container $SOURCE_CONTAINER_NAME was not found -- does the current host have a role 'director'?${NC}"
      exit $GENERAL_ERROR_EXIT_CODE
  fi

  ensureUserPasswordOrSecretsFile
}

resetAdminconsolePassword() {
  CLOUD_IMAGE=$(dockerCmdViaSocket inspect -f '{{ .Config.Image }}' $SOURCE_CONTAINER_NAME)

  if [[ ! -z "${BOOTSTRAP_SECRETS}" ]]; then
    SECRETS_FILE_NAME="/secrets.json"
    MNT="-v ${BOOTSTRAP_SECRETS}:${SECRETS_FILE_NAME}:rw"
    SECRETS_ARG="--secrets ${SECRETS_FILE_NAME}"
  fi

  if [[ ! -z "${CLOUD_IMAGE}" ]]; then
    dockerCmdViaSocket run \
        --env ZK_AUTH=$ZK_ROOT_PASSWORD \
        $(dockerCmdViaSocket inspect -f '{{ range .HostConfig.ExtraHosts }} --add-host {{.}} {{ end }}' $SOURCE_CONTAINER_NAME) \
        $MNT \
        -v "$HOST_STORAGE_PATH/logs":"/app/logs${RESOURCE_MOUNTING_OPTIONS}" \
        --rm $CLOUD_IMAGE \
        /elastic_cloud_apps/bootstrap/reset_adminconsole_password/reset-adminconsole-password.sh $USER $NEW_PWD $SECRETS_ARG # run directly, bypass runit
  else
      echo -e "${RED}Container $SOURCE_CONTAINER_NAME was not found -- is the environment running?${NC}"
      exit $GENERAL_ERROR_EXIT_CODE
  fi
}

addStackVersion() {
  # We expect metadata in the stackpack to indicate whether it's compatible with this version of ECE
  # It's also the adminconsole's responsibility to do any verification of signatures etc. in the future

  CLOUD_IMAGE=$(dockerCmdViaSocket inspect -f '{{ .Config.Image }}' $SOURCE_CONTAINER_NAME)

  if [[ ! -z "${BOOTSTRAP_SECRETS}" ]]; then
    SECRETS_FILE_NAME="/secrets.json"
    MNT="-v ${BOOTSTRAP_SECRETS}:${SECRETS_FILE_NAME}:ro"
  fi

  if [[ ! -z "${CLOUD_IMAGE}" ]]; then
    if [[ -e "${VERSION}.zip" ]]; then
      # Local stack pack zip exists, let's process that
      echo -e "Found a local ${VERSION}.zip stack pack. This will be used in processing the stack pack."

      ADD_STACKPACK_RESULTS=$(dockerCmdViaSocket run \
        --env USER=$USER \
        --env PASS=$PASS \
        --env SECRETS_FILE_NAME=$SECRETS_FILE_NAME \
        --env VERSION=$VERSION \
        $(dockerCmdViaSocket inspect -f '{{ range .HostConfig.ExtraHosts }} --add-host {{.}} {{ end }}' $SOURCE_CONTAINER_NAME) \
        $MNT \
        -v "$HOST_STORAGE_PATH/logs":"/app/logs${RESOURCE_MOUNTING_OPTIONS}" \
        -v "${PWD}/${VERSION}.zip":"/tmp/${VERSION}.zip${RESOURCE_MOUNTING_OPTIONS}" \
        --rm $CLOUD_IMAGE \
        bash -c 'wget -q -O - --content-on-error --auth-no-challenge \
                   --header "Content-Type: application/zip" \
                   --user $USER \
                   --password ${PASS:-$(jq -r .adminconsole_root_password $SECRETS_FILE_NAME)} \
                   --post-file=/tmp/${VERSION}.zip \
                   http://containerhost:12400/api/v1/stack/versions') \
        && echo "Stack version ${VERSION} added from local stack pack" \
        || echo -e "${RED}Could not add stack version ${VERSION} from local stack pack${ADD_STACKPACK_RESULTS:+\n$ADD_STACKPACK_RESULTS}${NC}"
    else
      # Local stack pack zip doesn't exist, we'll attempt to download the file

      # Let's check that we can access the stack pack
      if wget -q --spider --timeout=60 "https://download.elastic.co/cloud-enterprise/versions/${VERSION}.zip"; then
        ADD_STACKPACK_RESULTS=$(dockerCmdViaSocket run \
          --env USER=$USER \
          --env PASS=$PASS \
          --env SECRETS_FILE_NAME=$SECRETS_FILE_NAME \
          --env VERSION=$VERSION \
          $(dockerCmdViaSocket inspect -f '{{ range .HostConfig.ExtraHosts }} --add-host {{.}} {{ end }}' $SOURCE_CONTAINER_NAME) \
          $MNT \
          -v "$HOST_STORAGE_PATH/logs":"/app/logs${RESOURCE_MOUNTING_OPTIONS}" \
          --rm $CLOUD_IMAGE \
          bash -c 'wget -qO /tmp/${VERSION}.zip --timeout=120 https://download.elastic.co/cloud-enterprise/versions/${VERSION}.zip \
                   && wget -q -O - --content-on-error --auth-no-challenge \
                        --header "Content-Type: application/zip" \
                        --user $USER \
                        --password ${PASS:-$(jq -r .adminconsole_root_password $SECRETS_FILE_NAME)} \
                        --post-file=/tmp/${VERSION}.zip \
                        http://containerhost:12400/api/v1/stack/versions') \
          && echo "Stack version ${VERSION} added" \
          || echo -e "${RED}Could not add stack version ${VERSION}${ADD_STACKPACK_RESULTS:+\n$ADD_STACKPACK_RESULTS}${NC}"
      else
        echo -e "${RED}Could not download stack pack https://download.elastic.co/cloud-enterprise/versions/${VERSION}.zip, please check the version and network connectivity${NC}"
        exit $GENERAL_ERROR_EXIT_CODE
      fi
    fi
  else
      echo -e "${RED}Container $SOURCE_CONTAINER_NAME was not found -- is the environment running?${NC}"
      exit $GENERAL_ERROR_EXIT_CODE
  fi
}

runUpgradeContainer() {
  # only run with --tty if standard input is a tty
  DOCKER_TTY=""
  if [ -t 0 ]; then
      DOCKER_TTY="--tty"
  fi

  if [ -n "${API_BASE_URL}" ]; then
      DOCKER_ADDITIONAL_ARGUMENTS="--env ECE_ADMIN_CONSOLE_API_BASE_URL=${API_BASE_URL} ${DOCKER_ADDITIONAL_ARGUMENTS}"
  fi

  if [ "$ECE_DOCKER_REPOSITORY" == "cloud-enterprise" ]; then
      LATEST_STACK_PRE_RELEASE=""
      LATEST_VERSIONS_DOCKER_NAMESPACE="cloud-release"
      PREVIOUS_STACK_PRE_RELEASE=""
      PREVIOUS_VERSIONS_DOCKER_NAMESPACE="cloud-release"

      if [[ $(compareVersions "4.0.0" $CLOUD_ENTERPRISE_VERSION) -eq 1 ]]; then
          PREVIOUS_VERSIONS_DOCKER_NAMESPACE="cloud-assets"
          PREVIOUS_STACK_PRE_RELEASE="-0"
      fi
  fi

  PASS=${PASS:-$(jq -r .adminconsole_root_password $BOOTSTRAP_SECRETS)}

  dockerCmdViaSocket run \
      ${DOCKER_ADDITIONAL_ARGUMENTS} \
      --env HOST_DOCKER_HOST=${HOST_DOCKER_HOST} \
      --env HOST_STORAGE_PATH=${HOST_STORAGE_PATH} \
      --env CLOUD_ENTERPRISE_VERSION=${CLOUD_ENTERPRISE_VERSION} \
      --env SKIP_PENDING_PLAN_CHECK=${SKIP_PENDING_PLAN_CHECK} \
      --env ENABLE_DEBUG_LOGGING=${ENABLE_DEBUG_LOGGING} \
      --env DOCKER_REGISTRY=${DOCKER_REGISTRY} \
      --env CONTAINER_ENGINE=${CONTAINER_ENGINE} \
      --env ECE_DOCKER_REPOSITORY=${ECE_DOCKER_REPOSITORY} \
      --env LATEST_VERSIONS_DOCKER_NAMESPACE=${LATEST_VERSIONS_DOCKER_NAMESPACE} \
      --env LATEST_STACK_PRE_RELEASE=${LATEST_STACK_PRE_RELEASE} \
      --env PREVIOUS_VERSIONS_DOCKER_NAMESPACE=${PREVIOUS_VERSIONS_DOCKER_NAMESPACE} \
      --env PREVIOUS_STACK_PRE_RELEASE=${PREVIOUS_STACK_PRE_RELEASE} \
      --env ECE_TIMEOUT_FACTOR=${TIMEOUT_FACTOR} \
      --env FORCE_UPGRADE=${FORCE_UPGRADE} \
      --env ADMINCONSOLE_USER_NAME=${USER} \
      --env ADMINCONSOLE_PASSWORD=${PASS} \
      -v ${HOST_DOCKER_HOST}:/run/docker.sock \
      -v ${HOST_STORAGE_PATH}:${HOST_STORAGE_PATH}${RESOURCE_MOUNTING_OPTIONS} \
      --name elastic-cloud-enterprise-installer \
      --rm -i ${DOCKER_TTY} ${DOCKER_REGISTRY}/${ECE_DOCKER_REPOSITORY}/elastic-cloud-enterprise:${CLOUD_ENTERPRISE_VERSION} elastic-cloud-enterprise-upgrader
}

createAndValidateHostStoragePath() {
  uid=`id -u`
  gid=`id -g`

  if [[ ! -e ${HOST_STORAGE_PATH} ]]; then
    mkdir -p ${HOST_STORAGE_PATH}
    chown -R $uid:$gid ${HOST_STORAGE_PATH}
  fi

  if [[ ! -r ${HOST_STORAGE_PATH} ]]; then
    printf "${RED}%s${NC}\n" "Host storage path ${HOST_STORAGE_PATH} exists but doesn't have read permissions for user '${USER}'."
    printf "${RED}%s${NC}\n" "Please supply the correct permissions for the host storage path."
    exit $GENERAL_ERROR_EXIT_CODE
  fi

  if [[ ! -w ${HOST_STORAGE_PATH} ]]; then
    printf "${RED}%s${NC}\n" "Host storage path ${HOST_STORAGE_PATH} exists but doesn't have write permissions for user '${USER}'."
    printf "${RED}%s${NC}\n" "Please supply the correct permissions for the host storage path."
    exit $GENERAL_ERROR_EXIT_CODE
  fi

  export HOST_STORAGE_DEVICE_PATH=$(df --output=source ${HOST_STORAGE_PATH} | sed 1d)
}

runBootstrapInitiatorContainer() {
  # only run with --tty if standard input is a tty
  DOCKER_TTY=""
  if [ -t 0 ]; then
      DOCKER_TTY="--tty"
  fi

  if [ -n "${RUNNER_EXTERNAL_HOSTNAME}" ]; then
      DOCKER_ADDITIONAL_ARGUMENTS="--env RUNNER_EXTERNAL_HOSTNAME=${RUNNER_EXTERNAL_HOSTNAME} --env HOST_DNS_NAMES=${RUNNER_EXTERNAL_HOSTNAME} ${DOCKER_ADDITIONAL_ARGUMENTS}"
  fi

  if [ -n "${API_BASE_URL}" ]; then
      DOCKER_ADDITIONAL_ARGUMENTS="--env ECE_ADMIN_CONSOLE_API_BASE_URL=${API_BASE_URL} ${DOCKER_ADDITIONAL_ARGUMENTS}"
  fi

  if [ "$ECE_DOCKER_REPOSITORY" == "cloud-enterprise" ]; then
      LATEST_STACK_PRE_RELEASE=""
      LATEST_VERSIONS_DOCKER_NAMESPACE="cloud-release"
      PREVIOUS_STACK_PRE_RELEASE=""
      PREVIOUS_VERSIONS_DOCKER_NAMESPACE="cloud-release"

      if [[ $(compareVersions "4.0.0" $CLOUD_ENTERPRISE_VERSION) -eq 1 ]]; then
          PREVIOUS_VERSIONS_DOCKER_NAMESPACE="cloud-assets"
          PREVIOUS_STACK_PRE_RELEASE="-0"
      fi
  fi

  FLAGS=$(env | while read ENV_VAR; do if [[ ${ENV_VAR} == CLOUD_FEATURE* ]]; then printf -- "--env ${ENV_VAR} "; fi; done)

  # binding for port 20000 is left for backward compatibility with 1.1.x and lower.
  dockerCmdViaSocket run \
      ${DOCKER_ADDITIONAL_ARGUMENTS} \
      --env RUNNER_ENVIRONMENT_METADATA_JSON=${RUNNER_ENVIRONMENT_METADATA_JSON:-{}} \
      --env COORDINATOR_HOST=${COORDINATOR_HOST} \
      --env HOST_DOCKER_HOST=${HOST_DOCKER_HOST} \
      --env HOST_STORAGE_PATH=${HOST_STORAGE_PATH} \
      --env HOST_STORAGE_DEVICE_PATH=${HOST_STORAGE_DEVICE_PATH} \
      --env CLOUD_ENTERPRISE_VERSION=${CLOUD_ENTERPRISE_VERSION} \
      --env ENABLE_DEBUG_LOGGING=${ENABLE_DEBUG_LOGGING} \
      --env DOCKER_REGISTRY=${DOCKER_REGISTRY} \
      --env CONTAINER_ENGINE=${CONTAINER_ENGINE} \
      --env LATEST_VERSIONS_DOCKER_NAMESPACE=${LATEST_VERSIONS_DOCKER_NAMESPACE} \
      --env LATEST_STACK_PRE_RELEASE=${LATEST_STACK_PRE_RELEASE} \
      --env PREVIOUS_VERSIONS_DOCKER_NAMESPACE=${PREVIOUS_VERSIONS_DOCKER_NAMESPACE} \
      --env PREVIOUS_STACK_PRE_RELEASE=${PREVIOUS_STACK_PRE_RELEASE} \
      --env ECE_DOCKER_REPOSITORY=${ECE_DOCKER_REPOSITORY} \
      --env RUNNER_ID=${RUNNER_ID} \
      --env RUNNER_ROLES=${RUNNER_ROLES} \
      --env RUNNER_ROLES_TOKEN=${RUNNER_ROLES_TOKEN} \
      --env CLIENT_FORWARDER_OBSERVERS_TAG=${CLIENT_FORWARDER_OBSERVERS_TAG:-""} \
      --env ALLOCATOR_TAGS=${ALLOCATOR_TAGS:-""} \
      --env PROXY_TAGS=${PROXY_TAGS:-""} \
      --env HOST_IP=${HOST_IP} \
      --env AVAILABILITY_ZONE=${AVAILABILITY_ZONE} \
      --env CAPACITY=${CAPACITY} \
      --env ROLE="bootstrap-initiator" \
      --env UID=`id -u` \
      --env GID=`id -g` \
      --env MEMORY_SETTINGS=${MEMORY_SETTINGS} \
      --env CONFIG_FILE=${CONFIG_FILE} \
      --env FORCE_INSTALL=${FORCE_INSTALL} \
      --env HOST_PREREQ_FAILED=${HOST_PREREQ_FAILED} \
      --env ECE_TIMEOUT_FACTOR=${TIMEOUT_FACTOR} \
      --env HOST_KERNEL_PARAMETERS="${HOST_KERNEL_PARAMETERS}" \
      ${FLAGS} \
      -p 22000:22000 \
      -p 21000:21000 \
      -p 20000:20000 \
      -v ${HOST_DOCKER_HOST}:/run/docker.sock \
      -v ${HOST_STORAGE_PATH}:${HOST_STORAGE_PATH}${RESOURCE_MOUNTING_OPTIONS} \
      --name elastic-cloud-enterprise-installer \
      --rm -i ${DOCKER_TTY} ${DOCKER_REGISTRY}/${ECE_DOCKER_REPOSITORY}/elastic-cloud-enterprise:${CLOUD_ENTERPRISE_VERSION} elastic-cloud-enterprise-installer
}

pullElasticCloudEnterpriseImage() {
  printf "%s\n" "Pulling ${DOCKER_REGISTRY}/${ECE_DOCKER_REPOSITORY}/elastic-cloud-enterprise:${CLOUD_ENTERPRISE_VERSION} image."
  dockerCmdViaSocket pull ${DOCKER_REGISTRY}/${ECE_DOCKER_REPOSITORY}/elastic-cloud-enterprise:${CLOUD_ENTERPRISE_VERSION}
}

defineHostIp() {
  local reason=""
  if [ -z ${HOST_IP} ]; then
    # first check that 'ip' tool exists
    if type 'ip' &> /dev/null ; then
      # 'ip' tool exists so lets attempt to get the interface to the default gateway.
      DEVICE=$(ip route show default | awk '/default/ {print $5}')
      if [ ! -z ${DEVICE} ]; then
        # now lets use 'ip' tool to get the ip of the network interface as the default HOST_IP
        HOST_IP=$(ip -4 addr show ${DEVICE}| grep -Po 'inet \K[\d.]+')
      else
        reason=" (the default gateway was not found)"
      fi
    else
      reason=" ('ip' tool can't be found)"
    fi
  fi
  if [ -z ${HOST_IP} ]; then
     # 'ip' tool doesn't exist so error out as we need --host-ip flag
     printf "${RED}%s${NC}\n" "Can't determine a default HOST_IP$reason. Please supply '--host-ip' with the appropriate ip address."
     exit $GENERAL_ERROR_EXIT_CODE
  fi
}

parseStackVersionArguments() {
  SOURCE_CONTAINER_NAME="frc-runners-runner"
  USER="admin"
  PASS=""
  VERSION=""
  SECRETS_RELATIVE_PATH="/bootstrap-state/bootstrap-secrets.json"

  while [ "$1" != "" ]; do
    case $1 in
        --host-docker-host )          setArgumentWithFilter HOST_DOCKER_HOST $1 $2
                                      shift
                                      ;;
        --user )                      setArgument USER $1 $2
                                      shift
                                      ;;
        --secrets )                   setArgument BOOTSTRAP_SECRETS $1 $2
                                      BOOTSTRAP_SECRETS=$(cd "$(dirname "$BOOTSTRAP_SECRETS")"; pwd)/$(basename "$BOOTSTRAP_SECRETS")
                                      shift
                                      ;;
        --pass )                      setArgument PASS $1 $2
                                      shift
                                      ;;
        --version )                   setArgument VERSION $1 $2
                                      shift
                                      ;;

        --podman )                    CONTAINER_ENGINE=podman
                                      ;;
        --help|help )     echo "================================================================================"
                          echo "Download and add a new Elastic Stack version from upstream."
                          echo "The script must be run on a host that is a part of an Elastic Cloud Enterprise"
                          echo "installation."
                          echo ""
                          echo "${0##*/} add-stack-version"
                          echo "[--host-docker-host HOST_DOCKER_HOST] [--secrets PATH_TO_SECRETS_FILE]"
                          echo "[--user USER_NAME] [--pass PASSWORD] [--version A.B.C] [--podman] [[--]help]"
                          echo ""
                          echo "Arguments:"
                          echo ""
                          echo "--host-docker-host   Set the docker's docker-host location."
                          echo "                     Defaults to /var/run/docker.sock."
                          echo ""
                          echo "--secrets            Specifies a path to a file with secrets."
                          echo "                     Defaults to '$HOST_STORAGE_PATH$SECRETS_RELATIVE_PATH'"
                          echo ""
                          echo "--user               The user to authenticate to the adminconsole."
                          echo "                     Defaults to 'admin'."
                          echo ""
                          echo "--pass               Password to auth as to the adminconsole. If it is"
                          echo "                     not specified, the password is sourced from the secrets file."
                          echo ""
                          echo "--version            The version to add."
                          echo ""
                          echo "--podman             Use podman as container engine instead of docker."
                          echo ""
                          echo "Example:"
                          echo "${0##*/} add-stack-version --version 5.4.0"
                          echo ""
                          exit 0
                          ;;
       *)  echo -e "${RED}Unknown argument '$1'${NC}"
           exit $INVALID_ARGUMENT_EXIT_CODE
           ;;
    esac
    shift
  done

  ensureUserPasswordOrSecretsFile
}

# Perform pre-condition checks on the host before starting the installation
verifyHostPreconditions() {
  # Check if we can connect to the docker socket
  validateDockerSocket

  # Check UserID spaces and group membership
  validateRunningUser

  # Check if firewalld is active
  verifyFirewalldPrecondition
}

# Validate that the firewalld service is off
# If it is active then there is an issue when it tries to update the IPTables
verifyFirewalldPrecondition(){
  if hash systemctl 2>/dev/null; then
    local is_active=$(systemctl is-active firewalld)
    if [[ "$is_active" == "active" ]]; then
      HOST_PREREQ_FAILED=true
      echo -e "${YELLOW}The firewalld service may interfere with the installation of ECE." \
        "If you encounter issues, please disable firewalld and reinstall ECE.${NC}"
    fi
  fi
}

# Quickly detect if the docker socket location exists or not
validateDockerSocket(){
  if [ ! -S "${HOST_DOCKER_HOST}" ]; then
    echo -e "${RED}ECE could not verify the Docker socket (${HOST_DOCKER_HOST})." \
      "\nTo resolve the issue, verify that the Docker daemon is running on this host and" \
      "that you are using the correct Docker socket to connect to the daemon.${NC}"
    exit $PRECONDITION_NOT_MET_EXIT_CODE;
  fi
}

# Get host kernel paratmeters that ECE requires to validate
# Only get the specific kernel parameter so to limit the amount of data being passed through
# sysctl might be on the PATH, it might be in /sbin (Ubuntu), or it might be in /usr/sbin (CentOS)
getHostKernelParameters(){
  # Piping error to /dev/null to keep internal errors off of the user's terminal
  if [ -n "$(which sysctl 2>/dev/null)" ]; then
    HOST_KERNEL_PARAMETERS=$(sysctl net/ipv4/ip_local_port_range)
  elif [ -e "/sbin/sysctl" ]; then
    HOST_KERNEL_PARAMETERS=$(/sbin/sysctl net/ipv4/ip_local_port_range)
  elif [ -e "/usr/sbin/sysctl" ]; then
    HOST_KERNEL_PARAMETERS=$(/usr/sbin/sysctl net/ipv4/ip_local_port_range)
  else
    HOST_KERNEL_PARAMETERS=""
    echo -e "${YELLOW}The installation process was not able to check the host kernel parameters, which might affect other prerequisite checks." \
    "\nTo resolve this issue, make sure sysctl is on the PATH or in /sbin or /usr/sbin." \
    "\nContinuing the installation process...${NC}"
  fi
}

function withoutPatchVersion() {
  local full_version="$1"
  local format_with_patch_version="[0-9]+\.[0-9]+\.[0-9]+"
  if [[ $full_version =~ $format_with_patch_version ]]
  then
    echo ${full_version%.*}
  else
    echo $full_version
  fi
}

function withoutMinorVersion() {
  local full_version="$1"
  local format_with_minor_version="[0-9]+\.[0-9]+"
  if [[ $full_version =~ $format_with_minor_version ]]
  then
    echo ${full_version%.*}
  else
    echo $full_version
  fi
}

# Returns ECE version in format {major}.{minor}
function parseEceVersion() {
  local full_version="$1"
  local long_version_format="[0-9]+\.[0-9]+\.[0-9]+-[-a-zA-Z]+"
  local version_without_suffix=$full_version
  if [[ $full_version =~ $long_version_format ]]
  then
    version_without_suffix=${full_version%%-*}
  fi
  echo $(withoutPatchVersion $version_without_suffix)
}

function getContainerRuntimeTypeAndVersion() {
  if [[ "$CONTAINER_ENGINE" == "podman" ]]
  then
    local podman_cmd=dockerCmdViaSocket
    local podman_version=$(eval "$podman_cmd version --format {{.Version}}")
    local suffix="-rhel"
    local podman_version_without_suffix=${podman_version%$suffix}
    local podman_version_without_patch=$(withoutPatchVersion "$podman_version_without_suffix")
    echo "Podman-"$(withoutMinorVersion "$podman_version_without_patch")
  elif [[ "$CONTAINER_ENGINE" == "docker" ]]
  then
    local docker_version=$(dockerCmdViaSocket --version)
    local prefix="Docker version "
    local docker_version_without_prefix=${docker_version#"$prefix"}
    local docker_version_without_suffix=${docker_version_without_prefix%,*}
    echo "Docker-"$(withoutPatchVersion "$docker_version_without_suffix")
  else
    echo "Neither Docker nor Podman were specified as container runtime. "
    exit 1
  fi

}

function getOperatingSystemTypeAndVersion() {
  local os_file=$(cat /etc/os-release)
  local os_full_name=$(echo $os_file | sed 's/" /"\n/g' | grep "^NAME=" | cut -f2 -d'=')
  local os_full_version_number=$(echo $os_file | sed 's/" /"\n/g' | grep "^VERSION_ID" | cut -f2 -d'=' | tr -d \")

  if [[ $os_full_name =~ "Ubuntu" ]]
  then
    os_name="Ubuntu"
    os_version=$os_full_version_number
  elif [[ $os_full_name =~ "Red Hat Enterprise" ]]
  then
    os_name="RHEL"
    os_version=$(withoutMinorVersion "$os_full_version_number")
  elif [[ $os_full_name =~ "Rocky" ]]
  then
    os_name="RockyLinux"
    os_version=$(withoutMinorVersion "$os_full_version_number")
  elif [[ $os_full_name =~ "CentOS" ]]
  then
    os_name="CentOS"
    os_version=$(withoutMinorVersion "$os_full_version_number")
  elif [[ $os_full_name =~ "SLES" ]]
  then
    os_name="SLES"
    os_version=$(withoutMinorVersion "$os_full_version_number")
  fi
  echo $os_name"-"$os_version
}

# Returns:
# 1 when the first version is higher
# -1 when the first version is lower
# 0 when the versions are equal
function compareVersions() {
  local version_one="$1"
  local version_two="$2"

  local array_one=(${version_one//./ })
  local major_one=${array_one[0]}
  local minor_one=${array_one[1]}
  local array_two=(${version_two//./ })
  local major_two=${array_two[0]}
  local minor_two=${array_two[1]}
  if [[ $major_one -gt $major_two ]]
  then
    echo 1
  elif [[ $major_one -lt $major_two ]]
  then
    echo -1
  elif [[ $minor_one -gt $minor_two ]]
  then
    echo 1
  elif [[ $minor_one -lt $minor_two ]]
  then
    echo -1
  else
    echo 0
  fi
}

# If a new ECE version doesn't introduce any changes in compatibility compared to the previous version, there's no need to add an entry.
declare -A ECE_compatibility

ECE_compatibility["4.0"]="RHEL-8_Podman-4 RHEL-9_Podman-4 RHEL-9_Podman-5 RockyLinux-8_Podman-4 RockyLinux-9_Podman-5 Ubuntu-20.04_Docker-25.0 Ubuntu-20.04_Docker-26.0 Ubuntu-20.04_Docker-27.0 Ubuntu-22.04_Docker-25.0 Ubuntu-22.04_Docker-26.0 Ubuntu-22.04_Docker-27.0 Ubuntu-24.04_Docker-26.0 Ubuntu-24.04_Docker-27.0 SLES-12_Docker-25.0 SLES-15_Docker-25.0"
ECE_compatibility["3.8"]="RHEL-8_Podman-4 RHEL-9_Podman-4 RHEL-9_Podman-5 RockyLinux-8_Podman-4 RockyLinux-9_Podman-5 Ubuntu-20.04_Docker-20.10 Ubuntu-20.04_Docker-24.0 Ubuntu-20.04_Docker-25.0 Ubuntu-22.04_Docker-24.0 Ubuntu-22.04_Docker-25.0 SLES-12_Docker-24.0 SLES-12_Docker-25.0 SLES-15_Docker-24.0 SLES-15_Docker-25.0"
ECE_compatibility["3.7"]="RHEL-8_Podman-4 RHEL-9_Podman-4 RockyLinux-8_Podman-4 Ubuntu-20.04_Docker-20.10 Ubuntu-20.04_Docker-24.0 Ubuntu-22.04_Docker-24.0 SLES-12_Docker-18.09 SLES-12_Docker-24.0 SLES-15_Docker-20.10 SLES-15_Docker-24.0"
ECE_compatibility["3.4"]="CentOS-7_Docker-20.10 RHEL-7_Docker-20.10 CentOS-8_Docker-20.10 RHEL-8_Docker-20.10 RHEL-8_Podman-4 Ubuntu-18.04_Docker-19.03 Ubuntu-20.04_Docker-20.10 SLES-12_Docker-18.09 SLES-15_Docker-20.10"
ECE_compatibility["3.3"]="CentOS-8_Docker-19.03 RHEL-8_Docker-19.03 CentOS-7_Docker-20.10 RHEL-7_Docker-20.10 CentOS-8_Docker-20.10 RHEL-8_Docker-20.10 RHEL-8_Podman-4 Ubuntu-18.04_Docker-19.03 Ubuntu-20.04_Docker-20.10 SLES-12_Docker-18.09 SLES-15_Docker-20.10"
ECE_compatibility["2.13"]="CentOS-8_Docker-19.03 RHEL-8_Docker-19.03 CentOS-7_Docker-20.10 RHEL-7_Docker-20.10 CentOS-8_Docker-20.10 RHEL-8_Docker-20.10 Ubuntu-16.04_Docker-19.03 Ubuntu-18.04_Docker-19.03 SLES-12_Docker-18.09"

function setUpInstallerLog() {
  INSTALLER_LOG_FILE_DIR="$HOST_STORAGE_PATH/logs/bootstrap-logs"
  INSTALLER_LOG_FILE_NAME="elastic-cloud-enterprise.log"
  INSTALLER_LOG_FILE_PATH="$INSTALLER_LOG_FILE_DIR/$INSTALLER_LOG_FILE_NAME"
  if [[ ! -e "$INSTALLER_LOG_FILE_PATH" ]]
    then
     mkdir -p "$INSTALLER_LOG_FILE_DIR"
     touch "$INSTALLER_LOG_FILE_PATH"
  fi
}

# Requires the setUpInstallerLog be invoked first
function logBootstrapMessage() {
  echo "[$(date)] $(cat)" | tee -a "$INSTALLER_LOG_FILE_PATH"
}

function validateEceCompatibilityWithOsAndContainersRuntime() {
  local ece_version=$(parseEceVersion "$CLOUD_ENTERPRISE_VERSION")
  echo "Validating ECE version $ece_version compatibility with OS and Docker/Podman." | logBootstrapMessage

  if [[ $SKIP_CLOUD_ENTERPRISE_VERSION_CHECK = true ]]
  then
    echo "Skipping the validation of ECE - OS - Docker/Podman compatibility." | logBootstrapMessage
    return
  fi

  if [[ -z ${ECE_compatibility["$ece_version"]} ]]
  then
    for key in ${!ECE_compatibility[@]}
    do
      if [[ $(compareVersions $key $ece_version) -eq -1 ]] && [[ $(compareVersions $key $highest_version) -eq 1 ]]
      then
        highest_version=$key
      fi
    done

    if [[ -n $highest_version ]]
    then
      echo "Since no changes have occurred in OS - Docker/Podman compatibility in ECE version $ece_version, validating against ECE version: $highest_version." | logBootstrapMessage
      ece_version=$highest_version
    fi
  fi

  os_type_and_version=$(getOperatingSystemTypeAndVersion)
  container_runtime_type_and_version=$(getContainerRuntimeTypeAndVersion)
  entry=$os_type_and_version"_"$container_runtime_type_and_version

  versions_compatible_with_ece=${ECE_compatibility["$ece_version"]}

  for version in $versions_compatible_with_ece
   do
     if [[ "$version" = "$entry" ]]
     then
       found_entry=$version
     fi
  done

  if [[ -n $found_entry ]]
  then
    echo "Verified that ECE version $CLOUD_ENTERPRISE_VERSION is compatible with $os_type_and_version and $container_runtime_type_and_version." | logBootstrapMessage
  else
    echo "ECE version $CLOUD_ENTERPRISE_VERSION is not compatible with $os_type_and_version and $container_runtime_type_and_version. Please consult https://www.elastic.co/support/matrix#elastic-cloud-enterprise to check the supported OS and Docker/Podman versions." | logBootstrapMessage
    exit 1
  fi
}

setSELinux() {
  echo "Configuring SELinux"
  echo "File Contexts"
  sudo semanage fcontext -d /mnt/data/docker || true
  sudo semanage fcontext -d ${HOST_STORAGE_PATH} || true
  sudo semanage fcontext -a -e /var/lib/containers/storage /mnt/data/docker
  sudo semanage fcontext -a -e /srv/containers ${HOST_STORAGE_PATH}
  sudo semanage fcontext -a -t container_var_run_t $HOST_DOCKER_HOST
  sudo setsebool -P container_use_devices 1

  echo "Creating SELinux Module"

  cat > /tmp/ece_selinux_module.te <<EOF
  module ece 3.7;

  require {
        type container_runtime_t;
        type container_var_lib_t;
        type container_var_run_t;
        type container_t;
        type user_home_t;
        type fixed_disk_device_t;
        type fs_t;
        type var_run_t;
        type container_t;
        type mnt_t;
        type proc_t;
        class file read;
        class blk_file getattr;
        class dir { add_name write };
        class file { create getattr lock open read setattr write };
        class filesystem { quotaget quotamod };
        class sock_file { getattr read write };
        class unix_stream_socket connectto;
  }

  allow container_t mnt_t:file { read write getattr };
  allow container_t proc_t:file { read getattr };
  allow container_t container_runtime_t:unix_stream_socket connectto;
  allow container_t container_var_lib_t:file read;
  allow container_t container_var_run_t:sock_file { getattr read write };
  allow container_t fixed_disk_device_t:blk_file getattr;
  allow container_t fs_t:filesystem { quotaget quotamod };
  allow container_t var_run_t:dir { add_name write };
  allow container_t var_run_t:file { create getattr lock open read setattr write };
  allow container_t user_home_t:file { open read getattr };

EOF

  echo "Compiling and installing module"
  sudo checkmodule -M -m -o ece.mod /tmp/ece_selinux_module.te
  sudo semodule_package -o ece.pp -m ece.mod
  sudo semodule -X 300 -i ece.pp

  sudo restorecon -R -v /mnt/data
  sudo restorecon -R -v /mnt/data/docker
  sudo restorecon -v $HOST_DOCKER_HOST

# HOST_STORAGE_PATH may not exist yet - specially during a first installation
  if [ -d ${HOST_STORAGE_PATH} ] ; then
    sudo restorecon -R -v ${HOST_STORAGE_PATH}
  fi
}

parseConfigureSELinuxSettingsArguments() {
  while [ "$1" != "" ]; do
    case $1 in
      --podman )        CONTAINER_ENGINE=podman
                        ;;
      --help|help)
                        echo "Prepares the host for SELinux"
                        echo ""
                        echo "elastic-cloud-enterprise.sh configure-selinux-settings"
                        echo ""
                        echo "Arguments:"
                        echo ""
                        echo "--podman                   Use podman as container engine instead of docker"
                        echo ""
                        echo "For the full description of every command see documentation"
                        echo ""
                        exit 0
                        ;;
      *)                echo -e "${RED}Unknown argument '$1'${NC}"
                        exit $INVALID_ARGUMENT_EXIT_CODE
                        ;;
    esac
    shift
  done
}

main() {
  # When we use the default value from the DOCKER_HOST envrionment variable then
  # it contains the unix:// prefix that we should omit because then when we
  # bind-mount it to the docker will result in invalid file
  setArgumentWithFilter HOST_DOCKER_HOST HOST_DOCKER_HOST "${HOST_DOCKER_HOST}"

  if [ $COMMAND == "install" ]; then
    parseInstallArguments "$@"
    if [[ $CONTAINER_ENGINE == "podman" && $USE_SELINUX == true ]]; then
      RESOURCE_MOUNTING_OPTIONS=":z"
      setSELinux
    fi
    verifyHostPreconditions
    setUpInstallerLog
    validateEceCompatibilityWithOsAndContainersRuntime
    createAndValidateHostStoragePath
    defineHostIp
    if [ ${OVERWRITE_EXISTING_IMAGE} == true ]; then
        pullElasticCloudEnterpriseImage
    fi
    getHostKernelParameters
    runBootstrapInitiatorContainer
  elif [ $COMMAND == "reset-adminconsole-password" ]; then
    parseResetAdminconsolePasswordArguments "$@"
    resetAdminconsolePassword
  elif [ $COMMAND == "add-stack-version" ]; then
    parseStackVersionArguments "$@"
    addStackVersion
  elif [ $COMMAND == "upgrade" ]; then
    parseUpgradeArguments "$@"
    setUpInstallerLog
    validateEceCompatibilityWithOsAndContainersRuntime
    if [[ $CONTAINER_ENGINE == "podman" && $USE_SELINUX == true ]]; then
      RESOURCE_MOUNTING_OPTIONS=":z"
      setSELinux
    fi
    if [ ${OVERWRITE_EXISTING_IMAGE} == true ]; then
        pullElasticCloudEnterpriseImage
    fi
    runUpgradeContainer
  elif [ $COMMAND == "configure-selinux-settings" ]; then
    parseConfigureSELinuxSettingsArguments "$@"
    if [[ $CONTAINER_ENGINE == "podman" ]]; then
      setSELinux
    fi
  fi

}

# Main function
main "$@"
