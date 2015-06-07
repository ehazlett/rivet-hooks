#!/bin/bash
#set -x
pushd `dirname $0` > /dev/null
export BASE_DIR=`pwd -P`
popd > /dev/null

export BRIDGE=${BRIDGE:-br0}
export VM_DIR=$BASE_DIR/vm
export BRIDGE_IP=192.168.185.1
export BRIDGE_BROADCAST=192.168.185.255
export LOCAL_DOMAIN=vm.local
export DHCP_MIN=192.168.185.2
export DHCP_MAX=192.168.185.250
export DHCP_RANGE="$DHCP_MIN,$DHCP_MAX"
export NETWORK_UP_SCRIPT=/etc/ovs-ifup
export NETWORK_DOWN_SCRIPT=/etc/ovs-ifdown
export DNSMASQ_CONF=/etc/dnsmasq.d/rivet.conf
export LOG_DIR=$BASE_DIR/logs
export RUN_DIR=$BASE_DIR/run
export DNSMASQ_LOG=${DNSMASQ_LOG:-/var/log/syslog}

export ISO_PATH=$BASE_DIR/os.iso
export SSH_USER=${SSH_USER:-rancher}
export SSH_PASS=${SSH_PASS:-rancher}

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

if [ -z "`which ovs-vsctl`" ]; then
    echo -n "you must have openvswitch installed (openvswitch-switch)"
    exit 1
fi

mkdir -p $VM_DIR
mkdir -p $LOG_DIR
mkdir -p $RUN_DIR

# openvswitch
ovs-ofctl show $BRIDGE > /dev/null 2>&1
if [ "$?" = "1" ]; then
    echo "Creating bridge..."
    ovs-vsctl add-br $BRIDGE
    ip addr add $BRIDGE_IP/24 broadcast $BRIDGE_BROADCAST dev $BRIDGE
    ip link set $BRIDGE up
fi

# network scripts
if [ ! -e $NETWORK_UP_SCRIPT ]; then
    echo "Configuring network up script..."
    cat << EOF > $NETWORK_UP_SCRIPT
#!/bin/bash
switch='$BRIDGE'
/sbin/ifconfig \$1 0.0.0.0 up
ovs-vsctl add-port \${switch} \$1
EOF
    chmod +x $NETWORK_UP_SCRIPT
fi

if [ ! -e $NETWORK_DOWN_SCRIPT ]; then
    echo "Configuring network down script..."
    cat << EOF > $NETWORK_DOWN_SCRIPT
#!/bin/bash
switch='$BRIDGE'
/sbin/ifconfig \$1 0.0.0.0 down
ovs-vsctl del-port \${switch} \$1
EOF
    chmod +x $NETWORK_DOWN_SCRIPT
fi

# dnsmasq
if [ ! -e $DNSMASQ_CONF ]; then
    echo "Configuring dnsmasq..."
    cat << EOF > $DNSMASQ_CONF
interface=$BRIDGE
dhcp-range=$BRIDGE,$DHCP_RANGE
domain=$LOCAL_DOMAIN,$BRIDGE_IP,$DHCP_MAX
EOF
    service dnsmasq restart
fi

get_ip() {
    if [ ! -e "$VM_DIR/$NAME.mac" ]; then
        echo -n ""
        exit 0
    fi
    
    for i in `seq 1 2`; do
        MAC_ADDR=`cat $VM_DIR/$NAME.mac`
        if [ -z "$MAC_ADDR" ]; then
            echo "unable to find machine mac address"
            exit 1
        fi
    
        MAC="`echo $MAC_ADDR | awk '{print tolower($0)}'`"
    
        INFO=`grep "$MAC" $DNSMASQ_LOG | grep DHCPACK`
    
        if [ ! -z "$INFO" ]; then
            IP=`echo $INFO | awk '{ print $7; }'`
            break
        fi
    
        sleep 1
    done
}

start_vm() {
    echo "Creating VM..."
    qemu-system-x86_64 -daemonize -enable-kvm \
        -name $NAME \
        -smp cpus=1,cores=$CPU \
        -m $MEM \
        -netdev user,id=user-$NAME \
        -device e1000,netdev=user-$NAME,id=nic0 \
        -netdev tap,id=t0,script=$NETWORK_UP_SCRIPT,downscript=$NETWORK_DOWN_SCRIPT \
        -device e1000,netdev=t0,id=nic1,mac=$MAC_ADDR \
        -drive file=$DISK,if=virtio \
        -cdrom $ISO_PATH \
        -boot d \
        -pidfile $PID_FILE \
        -monitor unix:$MONITOR_FILE,server,nowait
}

enable_hostonly_network() {
    sshpass -p "$SSH_PASS" \
        ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p $SSH_LOCAL_PORT \
        $SSH_USER@127.0.0.1 -- sudo dhcpcd eth1
}

update_ssh_key() {
    get_ip

    for i in `seq 1 60`; do
        IP=`$BASE_DIR/get_ip $NAME`
        if [ ! -z "$IP" ]; then
            echo "Adding ssh key..."

            sshpass -p "$SSH_PASS" \
                ssh -v -o StrictHostKeyChecking=no \
                -t \
                -o UserKnownHostsFile=/dev/null \
                $SSH_USER@$IP -- mkdir -p /home/$SSH_USER/.ssh

            if [ $? -ne 0 ]; then
                sleep .5
                continue
            fi

            echo "$KEY" > $VM_DIR/$NAME.pub

            sshpass -p "$SSH_PASS" \
                scp -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                $VM_DIR/$NAME.pub \
                $SSH_USER@$IP:/home/$SSH_USER/.ssh/authorized_keys

            if [ $? -eq 0 ]; then
                break
            fi
            sleep .5
        fi
        sleep 1
    done
}
