#!/bin/bash

if [ "$#" -ne 7 ]; then
  echo "Usage: $0 answer_file compute_host(1.2.3.4,2.3.4.5) provider_interface keystone_region start_pool_ip end_pool_ip dns_ip" >&2
  exit 1
fi

answer_file=$1
compute_hosts=$2
provider_interface=$3
region=$4
start_pool_ip=$5
end_pool_ip=$6
dns_ip=$7

prereq ()
{
	systemctl disable firewalld
	systemctl stop firewalld
	systemctl disable NetworkManager
	systemctl stop NetworkManager
	systemctl enable network
	systemctl start network
}

setup_packstack () {
    yum install -y https://www.rdoproject.org/repos/rdo-release.rpm
    yum install -y openstack-packstack
	yum install -y openstack-utils
    packstack --gen-answer-file=$answer_file
}

disable_ex_interface () {
sed -i s/CONFIG_NEUTRON_L3_EXT_BRIDGE=.*/CONFIG_NEUTRON_L3_EXT_BRIDGE=provider/ $answer_file
sed -i s/CONFIG_PROVISION_DEMO=y/CONFIG_PROVISION_DEMO=n/ $answer_file
}

enable_heat () {
sed -i s/CONFIG_HEAT_INSTALL=n/CONFIG_HEAT_INSTALL=y/ $answer_file
}

set_keystone_region () {
sed -i s/CONFIG_KEYSTONE_REGION.*/CONFIG_KEYSTONE_REGION=${region}/ $answer_file
}

enable_keystone_v3 () {
sed -i s/CONFIG_KEYSTONE_API_VERSION.*/CONFIG_KEYSTONE_API_VERSION=v3/ $answer_file
}

set_keystone_passwd () {
sed -i  s/CONFIG_KEYSTONE_ADMIN_PW.*/CONFIG_KEYSTONE_ADMIN_PW=openstack1/ $answer_file
sed -i  s/CONFIG_KEYSTONE_DEMO_PW.*/CONFIG_KEYSTONE_DEMO_PW=openstack1/ $answer_file
sed -i s/_KS_PW=.*$/_KS_PW=openstack1/ $answer_file
sed -i  s/CONFIG_HEAT_DOMAIN_PASSWORD.*/CONFIG_HEAT_DOMAIN_PASSWORD=openstack1/ $answer_file
}

set_provider_network () {
sed -i s/^CONFIG_NEUTRON_OVS_BRIDGE_MAPPINGS=.*/CONFIG_NEUTRON_OVS_BRIDGE_MAPPINGS=physnet1:br-${provider_interface}/ $answer_file
sed -i s/^CONFIG_NEUTRON_OVS_BRIDGE_IFACES=.*/CONFIG_NEUTRON_OVS_BRIDGE_IFACES=br-${provider_interface}:${provider_interface}/ $answer_file
sed -i s/^CONFIG_NEUTRON_OVS_BRIDGES_COMPUTE=.*/CONFIG_NEUTRON_OVS_BRIDGES_COMPUTE=br-${provider_interface}/ $answer_file
sed -i s/^CONFIG_NEUTRON_ML2_TYPE_DRIVERS=.*/CONFIG_NEUTRON_ML2_TYPE_DRIVERS=vlan,vxlan,flat/ $answer_file
sed -i s/^CONFIG_NEUTRON_ML2_FLAT_NETWORKS=.*/CONFIG_NEUTRON_ML2_FLAT_NETWORKS=physnet1/ $answer_file
sed -i s/^CONFIG_NEUTRON_ML2_VLAN_RANGES=.*/CONFIG_NEUTRON_ML2_VLAN_RANGES=physnet1:412:415/ $answer_file
}

disable_components () {
sed -i s/CONFIG_SWIFT_INSTALL=y/CONFIG_SWIFT_INSTALL=n/ $answer_file
sed -i s/CONFIG_CEILOMETER_INSTALL=y/CONFIG_CEILOMETER_INSTALL=n/ $answer_file
sed -i s/CONFIG_AODH_INSTALL=y/CONFIG_AODH_INSTALL=n/ $answer_file
sed -i s/CONFIG_GNOCCHI_INSTALL=y/CONFIG_GNOCCHI_INSTALL=n/ $answer_file
}

verify_answer_file () {
cat $answer_file | egrep "^CONFIG_NEUTRON_OVS_BRIDGE_MAPPINGS|^CONFIG_NEUTRON_OVS_BRIDGE_IFACES|CONFIG_NEUTRON_OVS_BRIDGES_COMPUTE|CONFIG_NEUTRON_ML2_VLAN_RANGES|CONFIG_NEUTRON_ML2_TYPE_DRIVERS|CONFIG_NEUTRON_ML2_FLAT_NETWORKS|CONFIG_KEYSTONE_REGION|CONFIG_KEYSTONE_ADMIN_PW|CONFIG_KEYSTONE_DEMO_PW|CONFIG_KEYSTONE_API_VERSION|CONFIG_HEAT_INSTALL|^CONFIG_COMPUTE_HOSTS|_KS_PW=|CONFIG_PROVISION_DEMO"
}

set_compute_host () {
sed -i "/CONFIG_COMPUTE_HOSTS=/ s/$/,${compute_hosts}/" $answer_file
}

prepare_answer_file () {
    enable_heat
    enable_keystone_v3
    set_keystone_region
    set_keystone_passwd
    disable_ex_interface
    set_provider_network
	disable_components
    #set_compute_host
}

execute_answer_file () {
    packstack --answer-file $answer_file
}

post_install ()
{
GATEWAY=$(route -n | grep 'UG[ \t]' | awk '{print $2}')
IP=$(hostname  -I | cut -f1 -d' ')
CIDR="$(echo $IP | cut -d"." -f1-3).0/22"
source $HOME/keystonerc_admin
openstack network create  --share --external --provider-physical-network physnet1 --provider-network-type flat physnet1
openstack subnet create --network physnet1 --allocation-pool start=$start_pool_ip,end=$end_pool_ip --dns-nameserver $dns_ip --gateway $GATEWAY --subnet-range $CIDR physnet1

#####Disable metadata netowork to boot instance without requesting metadata#####
sed -i s/"^enable_metadata_network =.*"/enable_metadata_network=False/ "/etc/neutron/dhcp_agent.ini"
sed -i s/"^enable_isolated_metadata =.*"/enable_isolated_metadata=True/ "/etc/neutron/dhcp_agent.ini"

#####Set virt_type=kvm to boot windows instance otherwise it will fail#####
#####Make sure hardware Virtualization is enabled to use virt_type=kvm#####
#####verify hardware Virtualization by executing lscpu | grep VT-x    #####
sed -i s/"^virt_type=.*"/virt_type=kvm/ "/etc/nova/nova.conf"
sed -i s/"^allow_resize_to_same_host=.*"/allow_resize_to_same_host=true/ "/etc/nova/nova.conf"

#####Add security rules#####
nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
nova secgroup-add-rule default tcp 22 22 0.0.0.0/0
nova secgroup-add-rule default tcp 1 65535 0.0.0.0/0
nova secgroup-add-rule default udp 1 65535 0.0.0.0/0

#####Restart All Openstack Services#####
openstack-service restart
}

prereq
setup_packstack
prepare_answer_file
verify_answer_file
execute_answer_file
post_install
