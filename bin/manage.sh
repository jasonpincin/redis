#!/bin/bash

CONSUL=localhost

readonly lockPath=service/redis/locks/master
readonly lastBackupKey=service/redis/last-backup

consulCommand() {
    consul-cli --quiet --consul="${CONSUL}:8500" $*
}

preStart() {
    logDebug "preStart"

    if [[ -n ${CONSUL_LOCAL_CONFIG} ]]; then
      	echo "$CONSUL_LOCAL_CONFIG" > "/opt/consul/config/local.json"
    fi
}

onStart() {
    logDebug "onStart"

    waitForLeader

    getRegisteredServiceName
    if [[ "${registeredServiceName}" == "redis-replica" ]]; then

        echo "Getting master address"

        if [[ "$(consulCommand catalog service "redis" | jq any)" == "true" ]]; then
            # only wait for a healthy service if there is one registered in the catalog
            local i
            for (( i = 0; i < ${MASTER_WAIT_TIMEOUT-60}; i++ )); do
                getServiceAddresses "redis"
                if [[ ${serviceAddresses} ]]; then
                    break
                fi
                sleep 1
            done
        fi

        if [[ ! ${serviceAddresses} ]]; then
            echo "No healthy master, trying to set this node as master"

            logDebug "Locking ${lockPath}"
            local session=$(consulCommand kv lock "${lockPath}" --ttl=30s --lock-delay=5s)
            echo ${session} > /var/run/redis-master.sid

            getServiceAddresses "redis"
            if [[ ! ${serviceAddresses} ]]; then
                echo "Still no healthy master, setting this node as master"

                setRegisteredServiceName "redis"
                exit 2
            fi

            logDebug "Unlocking ${lockPath}"
            consulCommand kv unlock "${lockPath}" --session="$session"
        fi

    else

        local session=$(< /var/run/redis-master.sid)
        if [[ "$(consulCommand kv lock "${lockPath}" --ttl=30s --session="${session}")" != "${session}" ]]; then
            echo "This node is no longer the master"

            setRegisteredServiceName "redis-replica"
            exit 2
        fi

    fi

    if [[ ${serviceAddresses} ]]; then
        echo "Master is ${serviceAddresses}"
    else
        getNodeAddress
        echo "Master is ${nodeAddress} (this node)"
        export MASTER_ADDRESS=${nodeAddress}
    fi
    if [[ ! -f /etc/redis.conf ]] && [[ ! -f /etc/sentinel.conf ]]; then
        # don't overwrite sentinel.conf because Sentinel rewrites it with state configuration
        consul-template -consul=${CONSUL}:8500 -once -template=/etc/redis.conf.tmpl:/etc/redis.conf -template=/etc/sentinel.conf.tmpl:/etc/sentinel.conf
        if [[ $? != 0 ]]; then
            exit 1
        fi
    fi

    if [[ "$MANTA_PRIVATE_KEY" ]]; then
        echo "$MANTA_PRIVATE_KEY" | tr '#' '\n' > /tmp/mantakey.pem
    fi

    if [[ ! -f /data/appendonly.aof ]]; then
        # only restore from backup if no data exists
        if [[ -s /data/dump.rdb ]]; then
            loadBackupRdb
        else
            restoreFromBackup
        fi
    fi
}

health() {
    logDebug "health"

    redis-cli PING | grep PONG > /dev/null
    if [[ $? -ne 0 ]]; then
        echo "redis ping failed"
        exit 1
    fi

    getRedisInfo
    local role=${redisInfo[role]}
    getRegisteredServiceName
    logDebug "Role ${role}, service ${registeredServiceName}"

    if [[ "${registeredServiceName}" == "redis" ]] && [[ "${role}" != "master" ]]; then
        setRegisteredServiceName "redis-replica"
    elif [[ "${registeredServiceName}" == "redis-replica" ]] && [[ "${role}" != "slave" ]]; then
        setRegisteredServiceName "redis"
    elif [[ "${registeredServiceName}" == "redis" ]] && [[ -f /var/run/redis-master.sid ]]; then
        getNodeAddress
        getServiceAddresses "redis"
        if [[ "${nodeAddress}" == "${serviceAddresses}" ]]; then
            local session=$(< /var/run/redis-master.sid)

            logDebug "Unlocking ${lockPath}"
            consulCommand kv unlock "${lockPath}" --session="$session"

            rm /var/run/redis-master.sid
        fi
    fi
}

healthSentinel() {
    logDebug "healthSentinel"
    redis-cli -p 26379 PING | grep PONG > /dev/null
    if [[ $? -ne 0 ]]; then
        echo "sentinel ping failed"
        exit 1
    fi
}

preStop() {
    logDebug "preStop"

    local sentinels=$(redis-cli -p 26379 SENTINEL SENTINELS mymaster | awk '/^ip$/ { getline; print $0 }')
    logDebug "Sentinels to reset: ${sentinels}"
    if [[ -f /var/run/sentinel.pid ]]; then
      kill $(cat /var/run/sentinel.pid)
      rm /var/run/sentinel.pid
    fi

    for sentinel in ${sentinels} ; do
        echo "Resetting sentinel $sentinel"
        redis-cli -h "${sentinel}" -p 26379 SENTINEL RESET "*"
    done
}

backUpIfTime() {
    logDebug "backUpIfTime"

    local backupCheckName=redis-backup-run
    local status=$(consulCommand agent checks | jq -r ".\"${backupCheckName}\".Status")
    logDebug "status $status"
    if [[ "${status}" != "passing" ]]; then
        # TODO: pass the check after the backup?
        consulCommand check pass "${backupCheckName}"
        if [[ $? != 0 ]]; then
            consulCommand check register "${backupCheckName}" --ttl=${BACKUP_TTL-24h} || exit 1
            consulCommand check pass "${backupCheckName}" || exit 1
        fi

        saveBackup
    fi
}

saveBackup() {
    logDebug "saveBackup"

    echo "Saving backup"
    local prevLastSave=$(redis-cli LASTSAVE)
    redis-cli BGSAVE || (echo "BGSAVE failed" ; exit 1)

    local tries=0
    while true
    do
        logDebug -n "."
        tries=$((tries + 1))
        local lastSave=$(redis-cli LASTSAVE)
        if [[ "${lastSave}" != "${prevLastSave}" ]]; then
            logDebug ""
            break
        elif [[ $tries -eq 60 ]]; then
            logDebug ""
            echo "Timeout waiting for backup"
            exit 1
        fi
        sleep 1
    done

    local backupFilename=dump-$(date -u +%Y%m%d%H%M%S -d @${lastSave}).rdb.gz
    gzip /data/dump.rdb -c > /data/${backupFilename}

    echo "Uploading ${backupFilename}"
    (manta ${MANTA_BUCKET}/${backupFilename} --upload-file /data/${backupFilename} -H 'content-type: application/gzip; type=file' --fail) || (echo "Backup upload failed" ; exit 1)

    (consulCommand kv write "${lastBackupKey}" "${backupFilename}") || (echo "Set last backup value failed" ; exit 1)

    # remove the backup files so they don't grow without limit
    rm ${backupFilename}
}

restoreFromBackup() {
    local backupFilename=$(consulCommand kv read --format=text "${lastBackupKey}")

    if [[ -n ${backupFilename} ]]; then
        echo "Downloading ${backupFilename}"
        manta ${MANTA_BUCKET}/${backupFilename} | gunzip > /data/dump.rdb
        if [[ ! -s /data/dump.rdb ]]; then
            echo "Backup download failed"
            exit 1
        fi

        loadBackupRdb
    fi
}

loadBackupRdb() {
    echo "Initializing from /data/dump.rdb"

    redis-server --appendonly no --protected-mode yes &
    local i
    for (( i = 0; i < 10; i++ )); do
        sleep 0.1
        redis-cli PING | grep PONG > /dev/null && break
    done

    redis-cli CONFIG SET appendonly yes | grep OK > /dev/null || exit 1

    for (( i = 0; i < 600; i++ )); do
        sleep 0.1
        getRedisInfo
        logDebug "aof_rewrite_in_progress ${redisInfo[aof_rewrite_in_progress]}"
        if [[ "${redisInfo[aof_rewrite_in_progress]}" == "0" ]]; then
            break
        fi
    done

    logDebug "Shutting down"
    redis-cli SHUTDOWN || exit 1

    wait
}

waitForLeader() {
    logDebug "Waiting for consul leader"
    local tries=0
    while true
    do
        logDebug "Waiting for consul leader"
        tries=$((tries + 1))
        local leader=$(consulCommand --template="{{.}}" status leader)
        if [[ -n "$leader" ]]; then
            break
        elif [[ $tries -eq 60 ]]; then
            echo "No consul leader"
            exit 1
        fi
        sleep 1
    done
}

getServiceAddresses() {
    local serviceInfo=$(consulCommand health service --passing "$1")
    serviceAddresses=($(echo $serviceInfo | jq -r '.[].Service.Address'))
    logDebug "serviceAddresses $1 ${serviceAddresses[*]}"
}

getRegisteredServiceName() {
    registeredServiceName=$(jq -r '.services[0].name' /etc/containerpilot.json)
}

setRegisteredServiceName() {
    jq ".services[0].name = \"$1\"" /etc/containerpilot.json  > /etc/containerpilot.json.new
    mv /etc/containerpilot.json.new /etc/containerpilot.json
    kill -HUP 1
}

declare -A redisInfo
getRedisInfo() {
    eval $(redis-cli INFO | tr -d '\r' | egrep -v '^(#.*)?$' | sed -E 's/^([^:]*):(.*)$/redisInfo[\1]="\2"/')
}

manta() {
    local alg=rsa-sha256
    local keyId=/$MANTA_USER/keys/$MANTA_KEY_ID
    if [[ "${MANTA_SUBUSER}" != "" ]]; then
        keyId=/$MANTA_USER/$MANTA_SUBUSER/keys/$MANTA_KEY_ID
    fi
    local now=$(date -u "+%a, %d %h %Y %H:%M:%S GMT")
    local sig=$(echo "date:" $now | \
                tr -d '\n' | \
                openssl dgst -sha256 -sign /tmp/mantakey.pem | \
                openssl enc -e -a | tr -d '\n')

    if [[ -z "$sig" ]]; then
        return 1
    fi

    curl -sS $MANTA_URL"$@" -H "date: $now"  \
        -H "Authorization: Signature keyId=\"$keyId\",algorithm=\"$alg\",signature=\"$sig\""
}

getNodeAddress() {
    nodeAddress=$(ifconfig eth0 | awk '/inet addr/ {gsub("addr:", "", $2); print $2}')
}

logDebug() {
    if [[ "${LOG_LEVEL}" == "DEBUG" ]]; then
        echo "manage: $*"
    fi
}

help() {
    echo "Usage: ./manage.sh preStart       => configure Consul agent"
    echo "       ./manage.sh onStart        => first-run configuration"
    echo "       ./manage.sh health         => health check Redis"
    echo "       ./manage.sh healthSentinel => health check Sentinel"
    echo "       ./manage.sh preStop        => prepare for stop"
    echo "       ./manage.sh backUpIfTime   => save backup if it is time"
    echo "       ./manage.sh saveBackup     => save backup now"
}

until
    cmd=$1
    if [[ -z "$cmd" ]]; then
        help
    fi
    shift 1
    $cmd "$@"
    [ "$?" -ne 127 ]
do
    help
    exit
done
