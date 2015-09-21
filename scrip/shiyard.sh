#!/bin/bash

if [ "$1" != "" ] && [ "$1" = "-h" ]; then
    echo "Shipyard Deploy uses the following environment variables:"
    echo "  ACTION: this is the action to use (deploy, upgrade, remove)"
    echo "  IMAGE: this overrides the default Shipyard image"
    echo "  PREFIX: prefix for container names"
    echo "  SHIPYARD_ARGS: these are passed to the Shipyard controller container as controller args"
    echo "  TLS_CERT_PATH: path to certs to enable TLS for Shipyard"
    exit 1
fi

if [ -z "`which docker`" ]; then
    echo "You must have the Docker CLI installed on your \$PATH"
    echo "  See http://docs.docker.com for details"
    exit 1
fi

ACTION=${ACTION:-deploy}
IMAGE=${IMAGE:-shipyard/shipyard:latest}
PREFIX=${PREFIX:-shipyard}
SHIPYARD_ARGS=${SHIPYARD_ARGS:-""}
TLS_CERT_PATH=${TLS_CERT_PATH:-}
CERT_PATH="/etc/shipyard"
PROXY_PORT=2375
SWARM_PORT=3375
SHIPYARD_PROTOCOL=http
ENABLE_TLS=0
CERT_FINGERPRINT=""
LOCAL_CA_CERT=""
LOCAL_SSL_CERT=""
LOCAL_SSL_KEY=""
LOCAL_SSL_CLIENT_CERT=""
LOCAL_SSL_CLIENT_KEY=""
SSL_CA_CERT=""
SSL_CERT=""
SSL_KEY=""
SSL_CLIENT_CERT=""
SSL_CLIENT_KEY=""

show_cert_help() {
    echo "To use TLS in Shipyard, you must have existing certificates."
    echo "The certs must be named ca.pem, server.pem, server-key.pem, cert.pem and key.pem"
    echo "If you need to generate certificates, see https://github.com/ehazlett/certm for examples."
}

check_certs() {
    if [ -z "$TLS_CERT_PATH" ]; then
        return
    fi

    if [ ! -e $TLS_CERT_PATH ]; then
        echo "Error: unable to find certificates in $TLS_CERT_PATH"
        show_cert_help
        exit 1
    fi

    PROXY_PORT=2376
    SWARM_PORT=3376
    SHIPYARD_PROTOCOL=https
    LOCAL_SSL_CA_CERT="$TLS_CERT_PATH/ca.pem"
    LOCAL_SSL_CERT="$TLS_CERT_PATH/server.pem"
    LOCAL_SSL_KEY="$TLS_CERT_PATH/server-key.pem"
    LOCAL_SSL_CLIENT_CERT="$TLS_CERT_PATH/cert.pem"
    LOCAL_SSL_CLIENT_KEY="$TLS_CERT_PATH/key.pem"
    SSL_CA_CERT="$CERT_PATH/ca.pem"
    SSL_CERT="$CERT_PATH/server.pem"
    SSL_KEY="$CERT_PATH/server-key.pem"
    SSL_CLIENT_CERT="$CERT_PATH/cert.pem"
    SSL_CLIENT_KEY="$CERT_PATH/key.pem"
    CERT_FINGERPRINT=$(openssl x509 -noout -in $LOCAL_SSL_CERT -fingerprint -sha256 | awk -F= '{print $2;}')

    if [ ! -e $LOCAL_SSL_CA_CERT ] || [ ! -e $LOCAL_SSL_CERT ] || [ ! -e $LOCAL_SSL_KEY ] || [ ! -e $LOCAL_SSL_CLIENT_CERT ] || [ ! -e $LOCAL_SSL_CLIENT_KEY ]; then
        echo "Error: unable to find certificates"
        show_cert_help
        exit 1
    fi

    ENABLE_TLS=1
}

# container functions
start_certs() {
    ID=$(docker run \
        -ti \
        -d \
        --restart=always \
        --name $PREFIX-certs \
        -v $CERT_PATH \
        alpine \
        sh)
    if [ $ENABLE_TLS = 1 ]; then
        docker cp $LOCAL_SSL_CA_CERT $PREFIX-certs:$SSL_CA_CERT
        docker cp $LOCAL_SSL_CERT $PREFIX-certs:$SSL_CERT
        docker cp $LOCAL_SSL_KEY $PREFIX-certs:$SSL_KEY
        docker cp $LOCAL_SSL_CLIENT_CERT $PREFIX-certs:$SSL_CLIENT_CERT
        docker cp $LOCAL_SSL_CLIENT_KEY $PREFIX-certs:$SSL_CLIENT_KEY
    fi
}

remove_certs() {
    docker rm -fv $PREFIX-certs > /dev/null 2>&1
}

start_rethinkdb() {
    ID=$(docker run \
        -ti \
        -d \
        --restart=always \
        --name $PREFIX-rethinkdb \
        rethinkdb)
}

remove_rethinkdb() {
    docker rm -fv $PREFIX-rethinkdb > /dev/null 2>&1
}

start_proxy() {
    TLS_OPTS=""
    if [ $ENABLE_TLS = 1 ]; then
        TLS_OPTS="-e SSL_CA=$SSL_CA_CERT -e SSL_CERT=$SSL_CERT -e SSL_KEY=$SSL_KEY -e SSL_SKIP_VERIFY=1"
    fi
    # Note: we add SSL_SKIP_VERIFY=1 to skip verification of the client
    # certificate in the proxy image.  this will pass it to swarm that
    # does verify.  this helps with performance and avoids certificate issues
    # when running through the proxy.  ultimately if the cert is invalid
    # swarm will fail to return.
    ID=$(docker run \
        -ti \
        -d \
        --hostname=$HOSTNAME \
        --restart=always \
        --name $PREFIX-proxy \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e PORT=$PROXY_PORT \
        --volumes-from=$PREFIX-certs $TLS_OPTS\
        ehazlett/docker-proxy:latest)
}

remove_proxy() {
    docker rm -fv $PREFIX-proxy > /dev/null 2>&1
}

start_swarm() {
    TLS_OPTS=""
    if [ $ENABLE_TLS = 1 ]; then
        TLS_OPTS="--tlsverify --tlscacert=$SSL_CA_CERT --tlscert=$SSL_CERT --tlskey=$SSL_KEY"
    fi
    ID=$(docker run \
        -ti \
        -d \
        --restart=always \
        --name $PREFIX-swarm \
        --link $PREFIX-proxy:proxy \
        --volumes-from=$PREFIX-certs \
        swarm:latest \
        m --host tcp://0.0.0.0:$SWARM_PORT $TLS_OPTS proxy:$PROXY_PORT)
}

remove_swarm() {
    docker rm -fv $PREFIX-swarm > /dev/null 2>&1
}

start_controller() {
    #-v $CERT_PATH:/etc/docker:ro \
    TLS_OPTS=""
    if [ $ENABLE_TLS = 1 ]; then
        TLS_OPTS="--tls-ca-cert $SSL_CA_CERT --tls-cert=$SSL_CERT --tls-key=$SSL_KEY --shipyard-tls-ca-cert=$SSL_CA_CERT --shipyard-tls-cert=$SSL_CERT --shipyard-tls-key=$SSL_KEY"
    fi

    ID=$(docker run \
        -ti \
        -d \
        --restart=always \
        --name $PREFIX-controller \
        --link $PREFIX-rethinkdb:rethinkdb \
        --link $PREFIX-swarm:swarm \
        -p 8080:8080 \
        --volumes-from=$PREFIX-certs \
        $IMAGE \
        server \
        -d tcp://swarm:$SWARM_PORT $TLS_OPTS $SHIPYARD_ARGS)
}

get_shipyard_ip() {
    SHIPYARD_IP=`docker run --rm --net=host alpine ip route get 8.8.8.8 | awk '{ print $7;  }'`
}

wait_for_available() {
    set +e 
    IP=$1
    PORT=$2
    echo Waiting for Shipyard on $IP:$PORT

    docker pull ehazlett/curl > /dev/null 2>&1

    TLS_OPTS=""
    if [ $ENABLE_TLS = 1 ]; then
        TLS_OPTS="-k"
    fi

    until $(docker run --rm ehazlett/curl --output /dev/null --connect-timeout 1 --silent --head --fail $TLS_OPTS $SHIPYARD_PROTOCOL://$IP:$PORT/); do
        printf '.'
        sleep 1 
    done
    printf '\n'
}

remove_controller() {
    docker rm -fv $PREFIX-controller > /dev/null 2>&1
}

if [ "$ACTION" = "deploy" ]; then
    set -e

    check_certs

    echo "Deploying Shipyard"
    echo " -> Starting Database"
    start_rethinkdb
    echo " -> Starting Cert Volume"
    start_certs
    echo " -> Starting Proxy"
    start_proxy
    echo " -> Starting Swarm"
    start_swarm
    echo " -> Starting Controller"
    start_controller

    get_shipyard_ip 

    wait_for_available $SHIPYARD_IP 8080

    echo "Shipyard available at $SHIPYARD_PROTOCOL://$SHIPYARD_IP:8080"
    if [ $ENABLE_TLS = 1 ] && [ ! -z "$CERT_FINGERPRINT" ]; then
        echo "SSL SHA-256 Fingerprint: $CERT_FINGERPRINT"
    fi
    echo "Username: admin Password: shipyard"
    
elif [ "$ACTION" = "upgrade" ]; then
    set -e

    check_certs

    echo "Upgrading Shipyard"
    echo " -> Pulling $IMAGE"
    docker pull $IMAGE

    echo " -> Upgrading Controller"
    remove_controller
    start_controller

    get_shipyard_ip
    
    wait_for_available $SHIPYARD_IP 8080

    echo "Shipyard controller updated"

elif [ "$ACTION" = "remove" ]; then
    # ignore errors
    set +e

    echo "Removing Shipyard"
    echo " -> Removing Database"
    remove_rethinkdb
    echo " -> Removing Cert Volume"
    remove_certs
    echo " -> Removing Proxy"
    remove_proxy
    echo " -> Removing Swarm"
    remove_swarm
    echo " -> Removing Controller"
    remove_controller

    echo "Done"
else
    echo "Unknown action $ACTION"
    exit 1
fi