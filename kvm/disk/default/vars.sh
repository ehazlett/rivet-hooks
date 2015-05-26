#!/bin/bash
pushd `dirname $0` > /dev/null
export BASE_DIR=`pwd -P`
popd > /dev/null

export VM_DIR=$BASE_DIR/vm
export BRIDGE=br0
export BRIDGE_IP=192.168.180.1
export BRIDGE_BROADCAST=192.168.180.255
export DHCP_RANGE="192.168.180.10,192.168.180.254"
export LOG_DIR=$BASE_DIR/logs
export RUN_DIR=$BASE_DIR/run
export DNSMASQ_PID=$RUN_DIR/dnsmasq-rivet.pid
export DNSMASQ_LOG=$LOG_DIR/dnsmasq.log
export SSH_USER=${SSH_USER:-ubuntu}
export SSH_PASS=${SSH_PASS:-trusty}

export BASE_DISK=${BASE_DISK:-}

if [ -z "$BASE_DISK" ]; then
    echo "you must set the BASE_DISK environment variable"
    exit 1
fi

# prereqs
if [ "`id -u`" -ne "0" ]; then
    echo "you must be root to run"
    exit 1
fi

if [ -z "`which sshpass`" ]; then
    echo -n "you must have sshpass installed"
    exit 1
fi

if [ -z "`which socat`" ]; then
    echo -n "you must have socat installed"
    exit 1
fi

if [ -z "`which qemu-system-x86_64`" ]; then
    echo -n "you must have qemu installed"
    exit 1
fi

if [ -z "`which dnsmasq`" ]; then
    echo -n "you must have dnsmasq installed"
    exit 1
fi
mkdir -p $VM_DIR
mkdir -p $LOG_DIR
mkdir -p $RUN_DIR

# bridge
if [ -z "`/sbin/ifconfig | grep br0`" ]; then
    echo "Creating bridge..."
    brctl addbr $BRIDGE
    ip addr add ${BRIDGE_IP}/24 broadcast $BRIDGE_BROADCAST dev br0
    ip link set br0 up
fi

# dnsmasq
if [ ! -e $DNSMASQ_PID ]; then
    echo "Starting dnsmasq..."
    dnsmasq --interface=$BRIDGE --bind-interfaces --dhcp-range=$DHCP_RANGE -x $DNSMASQ_PID -8 $DNSMASQ_LOG
fi

start_vm() {
    echo "Creating VM..."
    qemu-system-x86_64 -daemonize -enable-kvm \
        -name $NAME \
        -smp cpus=1,cores=$CPU \
        -m $MEM \
        -netdev user,id=user-$NAME \
        -device e1000,netdev=user-$NAME,id=nic0 \
        -netdev tap,id=t0,ifname=tap-$NAME,script=no,downscript=no \
        -device e1000,netdev=t0,id=nic1,mac=$MAC_ADDR \
        -boot c \
        -drive file=$DISK,if=virtio \
        -pidfile $PID_FILE \
        -vnc none \
        -monitor unix:$MONITOR_FILE,server,nowait
}

check_ssh() {
    nc -z $IP 22
    return $?
}

update_ssh_key() {
    for i in `seq 1 60`; do
        IP=`$BASE_DIR/get_ip $NAME`
        if [ ! -z "$IP" ]; then
            echo "Adding ssh key..."

            sshpass -p "$SSH_PASS" \
                ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                $SSH_USER@$IP -- mkdir -p /home/ubuntu/.ssh

            if [ $? -ne 0 ]; then
                sleep .5
                continue
            fi

            echo "$KEY" > $VM_DIR/$NAME.pub

            sshpass -p "$SSH_PASS" \
                scp -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                $VM_DIR/$NAME.pub \
                $SSH_USER@$IP:/home/ubuntu/.ssh/authorized_keys

            if [ $? -eq 0 ]; then
                break
            fi
            sleep .5
        fi
        sleep 1
    done
}
