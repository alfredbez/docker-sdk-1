#!/bin/bash

# shellcheck disable=SC2155

require docker docker-compose tr awk wc sed grep

Registry::Flow::addBoot "Compose::verboseMode"

function Compose::getComposeFiles() {
    local composeFiles="-f ${DEPLOYMENT_PATH}/../${SPRYKER_INTERNAL_PROJECT_NAME}/${DOCKER_COMPOSE_FILENAME}"

    for composeFile in ${DOCKER_COMPOSE_FILES_EXTRA}; do
        composeFiles+=" -f ${composeFile}"
    done

    echo "${composeFiles}"
}

function Compose::ensureTestingMode() {
    SPRYKER_TESTING_ENABLE=1
    local isTestMode=$(docker ps --filter 'status=running' --filter "name=${SPRYKER_INTERNAL_PROJECT_NAME}_webdriver_*" --format "{{.Names}}")
    if [ -z "${isTestMode}" ]; then
        Compose::run
    fi
}

function Compose::ensureRunning() {
    local service=${1:-${SPRYKER_PROJECT_NAME}_'cli'}
    local isCliRunning=$(docker ps --filter 'status=running' --filter "name=${service}" --format "{{.Names}}")
    if [ -z "${isCliRunning}" ]; then
        Compose::run
    fi
}

function Compose::ensureCliRunning() {
    local isCliRunning=$(docker ps --filter 'status=running' --filter "ancestor=${SPRYKER_DOCKER_PREFIX}_run_cli:${SPRYKER_DOCKER_TAG}" --filter "name=${SPRYKER_DOCKER_PREFIX}_cli_*" --format "{{.Names}}")
    if [ -z "${isCliRunning}" ]; then
        Compose::run --no-deps ${SPRYKER_PROJECT_NAME}_cli ${SPRYKER_PROJECT_NAME}_cli_ssh_relay
        Registry::Flow::runAfterCliReady
    fi
}

# ---------------
function Compose::exec() {
    local tty
    [ -t -0 ] && tty='' || tty='-T'

	# For avoid https://github.com/docker/compose/issues/9104
	local ttyDisabledKey='docker_compose_tty_disabled'
	local lastArg="${@: -1}"
	if [ "${DOCKER_COMPOSE_TTY_DISABLED}" = "${lastArg}" ]; then
		if  [ "${DOCKER_COMPOSE_TTY_DISABLED}" = "${ttyDisabledKey}" ]; then
			tty='-T'
		fi

		set -- "${@:1:$(($#-1))}"
	fi

    Compose::command exec ${tty} \
        -e COMMAND="${*}" \
        -e APPLICATION_STORE="${SPRYKER_CURRENT_STORE}" \
        -e SPRYKER_CURRENT_REGION="${SPRYKER_CURRENT_REGION}" \
        -e SPRYKER_PIPELINE="${SPRYKER_PIPELINE}" \
        -e SSH_AUTH_SOCK="${SSH_AUTH_SOCK_IN_CLI}" \
        -e SPRYKER_XDEBUG_MODE_ENABLE="${SPRYKER_XDEBUG_MODE_ENABLE}" \
        -e SPRYKER_XDEBUG_ENABLE_FOR_CLI="${SPRYKER_XDEBUG_ENABLE_FOR_CLI}" \
        -e SPRYKER_TESTING_ENABLE_FOR_CLI="${SPRYKER_TESTING_ENABLE_FOR_CLI}" \
        -e COMPOSER_AUTH="${COMPOSER_AUTH}" \
        ${SPRYKER_PROJECT_NAME}_cli \
        bash -c 'bash ~/bin/cli.sh'
}

function Compose::verboseMode() {
    local output=''
    if [ "${SPRYKER_FILE_MODE}" == 'mount' ]; then
        output+="  DEVELOPMENT MODE  "
    fi
    if [ -n "${SPRYKER_TESTING_ENABLE}" ]; then
        output+="  TESTING MODE  "
    fi
    if [ -n "${SPRYKER_XDEBUG_ENABLE}" ] && [ -n "${SPRYKER_XDEBUG_MODE_ENABLE}" ]; then
        output+="  DEBUGGING MODE  "
    fi
    if [ -n "${output}" ]; then
        Console::warn "-->${output}"
    fi
    if [ -n "${SPRYKER_XDEBUG_ENABLE}" ] && [ -z "${SPRYKER_XDEBUG_MODE_ENABLE}" ]; then
        Console::error "Debugging is disabled in deploy.yml. Please, set ${INFO}deploy.yml: docker: debug: xdebug: enabled: true${WARN}, bootstrap and up to start debugging."
    fi
}

function Compose::command() {

    local -a composeFiles=()
    IFS=' ' read -r -a composeFiles <<< "$(Compose::getComposeFiles)"

    ${DOCKER_COMPOSE_SUBSTITUTE:-'docker-compose'} \
        --project-directory "${PROJECT_DIR}" \
        --project-name "${SPRYKER_INTERNAL_PROJECT_NAME}" \
        "${composeFiles[@]}" \
        "${@}"
}

# ---------------
function Compose::up() {

    local noCache=""
    local doBuild=""
    local doAssets=""
    local doData=""
    local doJobs=""

    for arg in "${@}"; do
        case "${arg}" in
            '--build')
                doBuild="--force"
                ;;
            '--assets')
                doAssets="--force"
                ;;
            '--data')
                doData="--force"
                ;;
            '--jobs')
                doJobs="--force"
                ;;
            '--no-cache')
                # TODO --no-cache flag. Ticket is necessary
                noCache="--no-cache"
                ;;
            *)
                Console::verbose "\nUnknown option ${INFO}${arg}${WARN} is acquired."
                ;;
        esac
    done

    Registry::Flow::runBeforeUp

    Images::buildApplication ${noCache} ${doBuild}
    Codebase::build ${noCache} ${doBuild}
    Assets::build ${noCache} ${doAssets}
    Images::buildFrontend ${noCache} ${doBuild}
    Compose::run --build
    Compose::command --profile ${SPRYKER_PROJECT_NAME} --profile ${SPRYKER_INTERNAL_PROJECT_NAME} restart ${SPRYKER_PROJECT_NAME}_frontend ${SPRYKER_INTERNAL_PROJECT_NAME}_gateway

    Registry::Flow::runAfterUp

    Data::load ${noCache} ${doData}
    Service::Scheduler::start ${noCache} ${doJobs}
}

function Compose::run() {
    Registry::Flow::runBeforeRun
    Console::verbose "${INFO}Running Spryker containers${NC}"

    local profiles=( "--profile ${SPRYKER_PROJECT_NAME}" )

    for projectName in $(Project::getListOfEnabledProjects) ; do
      if [ "${projectName}" == "${SPRYKER_PROJECT_NAME}" ]; then
          continue
      fi

      profiles+=( "--profile ${projectName}" )
    done

    Compose::command --compatibility --profile ${SPRYKER_INTERNAL_PROJECT_NAME} ${profiles[*]} up -d --remove-orphans --quiet-pull "${@}"

#   todo: env variable for each project
    if [ -n "${SPRYKER_TESTING_ENABLE}" ]; then
      Service::Scheduler::stop
    fi

    if [ -z "${SPRYKER_TESTING_ENABLE}" ]; then
      local projectWebdriver=( "${SPRYKER_PROJECT_NAME}_webdriver" )

      for projectName in $(Project::getListOfEnabledProjects) ; do
        if [ "${projectName}" == "${SPRYKER_PROJECT_NAME}" ]; then
            continue
        fi

        projectWebdriver+=( "${projectName}_webdriver" )
      done

      Compose::command --compatibility ${profiles[*]} stop ${projectWebdriver[*]}
    fi

    # Note: Compose::run can be used for running only one container, e.g. CLI.
    Registry::Flow::runAfterRun
}

function Compose::ps() {
    Compose::command ps "${@}"
}

function Compose::restart() {
    Console::verbose "${INFO}Restarting Spryker containers${NC}"
    Compose::stop
    Compose::run
}

function Compose::stop() {
    Console::verbose "${INFO}Stopping all containers${NC}"

    if [ ! -f "${DEPLOYMENT_DIR}/${ENABLED_FILENAME}" ]; then
      return
    fi

    local enabledProjects=($(Project::getListOfEnabledProjects))
    local enabledProjectsCount=${#enabledProjects[@]}

    if [ "${enabledProjectsCount}" == 1 ]; then
      Compose::command --profile ${SPRYKER_INTERNAL_PROJECT_NAME} --profile ${SPRYKER_PROJECT_NAME} stop
    else
      docker stop $(docker ps --filter "name=${SPRYKER_PROJECT_NAME}" --format="{{.ID}}")
    fi

    Registry::Flow::runAfterStop
}

function Compose::down() {
    local enabledProjects=($(Project::getListOfEnabledProjects))
    local count="${#enabledProjects[@]}"

    Console::verbose "${INFO}Stopping and removing all containers${NC}"

    if [ "${count}" -gt 1 ]; then
      Compose::downProject
    else
      Compose::command down
    fi

    sync stop
    Registry::Flow::runAfterDown
}

function Compose::downProject() {
  Service::Scheduler::stop
  docker stop $(docker ps --filter "name=${SPRYKER_PROJECT_NAME}" --format="{{.ID}}")
  docker rm $(docker ps -a --filter "name=${SPRYKER_PROJECT_NAME}" --format="{{.ID}}")
  Mount::dropVolumes
}

function Compose::cleanVolumes() {
    Console::verbose "${INFO}Stopping and removing all Spryker containers and volumes${NC}"
    Mount::dropVolumes
    Registry::Flow::runAfterDown
}

function Compose::cleanEverything() {
    Console::verbose "${INFO}Stopping and removing all Spryker containers and volumes${NC}"
    Compose::downProject
    Registry::Flow::runAfterDown
}
