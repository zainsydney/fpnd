#!/bin/bash
# fpn1-setup.sh v0.0
#   Configures incoming FPN routing interface/rules on target node
#
# PREREQS:
#   1. zt/iptables/iproute2 plus assoc. kernel modules installed on target node
#   2. network controller has available network with global default route
#   3. target node has been joined and authorized on the above network
#   4. target node has been configured as default gateway on the above network
#
# NOTE you may provide the ZT network ID as the only argument if
#      it does not automatically select the correct FPN1 network ID

#set -x

failures=0
trap 'failures=$((failures+1))' ERR

DATE=$(date +%Y%m%d)
# very simple log capture
exec &> >(tee -ia /tmp/fpn1-setup-${DATE}_output.log)
exec 2> >(tee -ia /tmp/fpn1-setup-${DATE}_error.log)

# uncomment for more output
#VERBOSE="anything"
# set the preferred network interface if needed
#SET_IPV4_IFACE="eth0"  <= fpnd.ini

# set allowed ports (still TBD))
ports_to_fwd="http https domain submission imaps ircs ircs-u"

[[ -n $VERBOSE ]] && echo "Checking iptables binary..."
IPTABLES=$(find /sbin /usr/sbin -name iptables)
HAS_LEGACY=$(find /sbin /usr/sbin -name iptables-legacy)
if [[ -n $HAS_LEGACY ]]; then
    IPTABLES="${HAS_LEGACY}"
fi

zt_route_tgts=( $(ip route show | grep zt | grep -v '169.254' | cut -d" " -f3) )
num_zt_tgts=${#zt_route_tgts[@]}

if ((num_zt_tgts < 1)); then
    echo "No FPN networks found!!"
    echo "Has this device joined a network yet?"
    exit 1
elif ((num_zt_tgts > 0)); then
    [[ -n $VERBOSE ]] && echo "FPN networks found, parsing network IDs..."
fi

while read -r line; do
    [[ -n $VERBOSE ]] && echo "Checking network..."
    LAST_OCTET=$(echo "$line" | cut -d" " -f9 | cut -d"/" -f1 | cut -d"." -f4)
    FULL_OCTET=$(echo "$line" | cut -d" " -f9 | cut -d"/" -f1)
    ZT_NET_ID=$(echo "$line" | cut -d" " -f3)
    ZT_IF_NAME=$(echo "$line" | cut -d" " -f8)
    ZT_NET_GW=$(zerotier-cli -j listnetworks | grep "${ZT_NET_ID}" -A 14 | grep via | awk '{ print $2 }' | tail -n 1 | cut -d'"' -f2)
    if [[ $FULL_OCTET = $ZT_NET_GW ]]; then
        ZT_SRC_NETID="${ZT_NET_ID}"
        [[ -n $VERBOSE ]] && echo "  Found $ZT_SRC_NETID"
        break
    else
        [[ -n $VERBOSE ]] && echo "  No gateway found"
    fi
done < <(zerotier-cli listnetworks | grep zt)

ZT_SRC_NETID=${1:-$ZT_SRC_NETID}

if [[ -n $ZT_SRC_NETID ]]; then
    [[ -n $VERBOSE ]] && echo "Using FPN1 ID: $ZT_SRC_NETID"
else
    echo "Please provide the network ID as argument."
    exit 1
fi

ZT_INTERFACE=$(zerotier-cli get "${ZT_SRC_NETID}" portDeviceName)
ZT_SRC_ADDR=$(zerotier-cli get "${ZT_SRC_NETID}" ip4)

if [[ -n $SET_IPV4_IFACE ]]; then
    [[ -n $VERBOSE ]] && echo "Looking for $SET_IPV4_IFACE"
    TEST_IFACE=$(ip route show default | { grep -o "${SET_IPV4_IFACE}" || test $? = 1; })
    if [[ -n $TEST_IFACE ]]; then
        [[ -n $VERBOSE ]] && echo "  $TEST_IFACE looks good..."
        IPV4_INTERFACE="${TEST_IFACE}"
    else
        [[ -n $VERBOSE ]] && echo "  $TEST_IFACE not found!"
        DEFAULT_IFACE=$(ip route show default | awk '{print $5}' | head -n 1)
    fi
else
    DEFAULT_IFACE=$(ip route show default | awk '{print $5}' | head -n 1)
fi

if ! [[ -n $IPV4_INTERFACE ]]; then
    while read -r line; do
        [[ -n $VERBOSE ]] && echo "Checking interfaces..."
        IFACE=$(echo "$line")
        if [[ $DEFAULT_IFACE = $IFACE ]]; then
            IPV4_INTERFACE="${IFACE}"
            [[ -n $VERBOSE ]] && echo "  Found interface $IFACE"
            break
        else
            [[ -n $VERBOSE ]] && echo "  Skipping $IFACE"
        fi
    done < <(ip -o link show up  | awk -F': ' '{print $2}' | grep -v lo)
fi

if ! [[ -n $IPV4_INTERFACE ]]; then
    echo "No usable network interface found! (check settings?)"
    exit 1
fi

INET_GATEWAY=$(ip route show default | grep $IPV4_INTERFACE | awk '{print $3}')

INET_ADDRESS=$(ip address show "${IPV4_INTERFACE}" | awk '/inet / {print $2}' | cut -d/ -f1)
ZT_SRC_NET=$(ip route show | grep ${ZT_INTERFACE} | grep -v '169.254' | awk '{print $1}')

if [[ -n $VERBOSE ]]; then
    echo "Found these devices and parameters:"
    echo "  FPN SRC interface: ${ZT_INTERFACE}"
    echo "  FPN SRC address: ${ZT_SRC_ADDR}"
    echo "  FPN SRC network: ${ZT_SRC_NET}"
    echo "  FPN SRC network id: ${ZT_SRC_NETID}"
    echo ""
    echo "  INET interface: ${IPV4_INTERFACE}"
    echo "  INET address: ${INET_ADDRESS}"
    echo "  INET gateway: ${INET_GATEWAY}"
fi

if [[ -n $VERBOSE ]]; then
    echo "Allow forwarding for FPN source traffic"
    sysctl -w net.ipv4.ip_forward=1
else
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
fi

# setup nat/masq to forward outbound/return traffic
# drop/accept chain
$IPTABLES -N fpn1-allowin
$IPTABLES -A INPUT -j fpn1-allowin
$IPTABLES -A fpn1-allowin -i "${ZT_INTERFACE}" -s "${ZT_SRC_NET}" -m state --state ESTABLISHED,RELATED -j ACCEPT
$IPTABLES -A fpn1-allowin -i "${ZT_INTERFACE}" -s "${ZT_SRC_NET}" -p udp --dport 53 -j ACCEPT
$IPTABLES -A fpn1-allowin -i "${ZT_INTERFACE}" -s "${ZT_SRC_NET}" -p udp -j DROP
# nat/postrouting chain
$IPTABLES -N fpn1-postnat -t nat
$IPTABLES -t nat -A POSTROUTING -j fpn1-postnat
$IPTABLES -t nat -A fpn1-postnat -o "${IPV4_INTERFACE}" -s "${ZT_SRC_NET}" -j MASQUERADE
# forwarding chain
$IPTABLES -N fpn1-forward
$IPTABLES -A FORWARD -j fpn1-forward
$IPTABLES -A fpn1-forward -i "${ZT_INTERFACE}" -o "${IPV4_INTERFACE}" -s "${ZT_SRC_NET}" -p tcp --dport 80 -j ACCEPT
$IPTABLES -A fpn1-forward -i "${ZT_INTERFACE}" -o "${IPV4_INTERFACE}" -s "${ZT_SRC_NET}" -p tcp --dport 443 -j ACCEPT
$IPTABLES -A fpn1-forward -i "${IPV4_INTERFACE}" -o "${ZT_INTERFACE}" -d "${ZT_SRC_NET}" -p tcp --sport 80 -j ACCEPT
$IPTABLES -A fpn1-forward -i "${IPV4_INTERFACE}" -o "${ZT_INTERFACE}" -d "${ZT_SRC_NET}" -p tcp --sport 443 -j ACCEPT
$IPTABLES -A fpn1-forward -i "${ZT_INTERFACE}" -o "${IPV4_INTERFACE}" -s "${ZT_SRC_NET}" -p udp --dport 53 -j ACCEPT
$IPTABLES -A fpn1-forward -i "${IPV4_INTERFACE}" -o "${ZT_INTERFACE}" -d "${ZT_SRC_NET}" -p udp --sport 53 -j ACCEPT
$IPTABLES -A fpn1-forward -i "${ZT_INTERFACE}" -o "${IPV4_INTERFACE}" -s "${ZT_SRC_NET}" -p tcp --dport 53 -j ACCEPT
$IPTABLES -A fpn1-forward -i "${IPV4_INTERFACE}" -o "${ZT_INTERFACE}" -d "${ZT_SRC_NET}" -p tcp --sport 53 -j ACCEPT
$IPTABLES -A fpn1-forward -i "${ZT_INTERFACE}" -o "${IPV4_INTERFACE}" -s "${ZT_SRC_NET}" -p tcp --dport 853 -j ACCEPT
$IPTABLES -A fpn1-forward -i "${IPV4_INTERFACE}" -o "${ZT_INTERFACE}" -d "${ZT_SRC_NET}" -p tcp --sport 853 -j ACCEPT
# icmp limit chain
$IPTABLES -N fpn1-limit
$IPTABLES -A INPUT -j fpn1-limit
$IPTABLES -A fpn1-limit -p icmp -m icmp --icmp-type address-mask-request -j DROP
$IPTABLES -A fpn1-limit -p icmp -m icmp --icmp-type timestamp-request -j DROP
$IPTABLES -A fpn1-limit -p icmp -m icmp --icmp-type 8 -m limit --limit 1/second -j ACCEPT


[[ -n $VERBOSE ]] && echo ""
if ((failures < 1)); then
    echo "Success"
else
    echo "$failures warnings/errors"
    exit 1
fi
