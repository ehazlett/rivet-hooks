#!/bin/bash
pushd `dirname $0` > /dev/null
export BASE_DIR=`pwd -P`
popd > /dev/null

export VM_DIR=$BASE_DIR/vm
export TAP_DEVICE=tap-rivet
export TAP_IP=192.168.185.1
export VDE_DOMAIN=vde.local
export DHCP_MIN=192.168.185.2
export DHCP_MAX=192.168.185.250
export DHCP_RANGE="$DHCP_MIN,$DHCP_MAX"
export NETWORK_SCRIPT=/etc/network/if-up.d/vde-rivet
export DNSMASQ_CONF=/etc/dnsmasq.d/vde-rivet
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

if [ -z "`which vde_switch`" ]; then
    echo -n "you must have vde2 installed"
    exit 1
fi

mkdir -p $VM_DIR
mkdir -p $LOG_DIR
mkdir -p $RUN_DIR

# tap / vde
if [ -z "`/sbin/ifconfig | grep $TAP_DEVICE`" ]; then
    echo "Creating tap device and vde-switch..."
    cat << EOF >> /etc/network/interfaces
allow-hotplug $TAP_DEVICE
iface $TAP_DEVICE inet static
    address $TAP_IP
    netmask 255.255.255.0
    vde2-switch -
EOF
    ifup $TAP_DEVICE
fi

# network
if [ ! -e $NETWORK_SCRIPT ]; then
    echo "Configuring network..."
    cat << EOF > $NETWORK_SCRIPT
#!/bin/bash
RANGE=$DHCP_RANGE
case $IFACE in
    lo|$TAP_DEVICE)
        # ignore
    ;;
    *)
        /sbin/iptables -t nat -A POSTROUTING -s $DHCP_RANGE -o $IFACE -j MASQUERADE
    ;;
esac
EOF
    chmod +x $NETWORK_SCRIPT
fi

# dnsmasq
if [ ! -e $DNSMASQ_CONF ]; then
    echo "Configuring dnsmasq..."
    cat << EOF > $DNSMASQ_CONF
interface=$TAP_DEVICE
dhcp-range=$TAP_DEVICE,$DHCP_RANGE
domain=$VDE_DOMAIN,$TAP_IP,$DHCP_MAX
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
        -net nic \
        -net user,hostfwd=tcp::$SSH_LOCAL_PORT-:22 \
        -netdev vde,id=t0,sock=/var/run/vde2/$TAP_DEVICE.ctl \
        -device e1000,netdev=t0,id=nic1,mac=$MAC_ADDR \
        -drive file=$DISK,if=virtio \
        -cdrom $ISO_PATH \
        -boot d \
        -pidfile $PID_FILE \
        -vnc none \
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