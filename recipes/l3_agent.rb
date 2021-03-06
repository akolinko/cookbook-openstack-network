# Encoding: utf-8
#
# Cookbook Name:: openstack-network
# Recipe:: l3_agent
#
# Copyright 2013, AT&T
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

['quantum', 'neutron'].include?(node['openstack']['compute']['network']['service_type']) || return

include_recipe 'openstack-network::common'

platform_options = node['openstack']['network']['platform']
core_plugin = node['openstack']['network']['core_plugin']
main_plugin = node['openstack']['network']['core_plugin_map'][core_plugin.split('.').last.downcase]

platform_options['neutron_l3_packages'].each do |pkg|
  package pkg do
    options platform_options['package_overrides']
    action :upgrade
    # The providers below do not use the generic L3 agent...
    not_if { ['nicira', 'plumgrid', 'bigswitch'].include?(main_plugin) }
  end
end

service 'neutron-l3-agent' do
  service_name platform_options['neutron_l3_agent_service']
  supports status: true, restart: true

  action :enable
  subscribes :restart, 'template[/etc/neutron/neutron.conf]'
end

template '/etc/neutron/l3_agent.ini' do
  source 'l3_agent.ini.erb'
  owner node['openstack']['network']['platform']['user']
  group node['openstack']['network']['platform']['group']
  mode   00644
  notifies :restart, 'service[neutron-l3-agent]', :immediately
end

driver_name = node['openstack']['network']['interface_driver'].split('.').last
# See http://docs.openstack.org/admin-guide-cloud/content/section_adv_cfg_l3_agent.html
case driver_name
when 'OVSInterfaceDriver'
  ext_bridge = node['openstack']['network']['l3']['external_network_bridge']
  ext_bridge_iface = node['openstack']['network']['l3']['external_network_bridge_interface']
  execute 'create external network bridge' do
    command "ovs-vsctl add-br #{ext_bridge}"
    action :run
    not_if "ovs-vsctl br-exists #{ext_bridge}"
    only_if "ip link show #{ext_bridge_iface}"
  end
  check_port = `ovs-vsctl port-to-br #{ext_bridge_iface}`.delete("\n")
  # If ovs-vsctl port-to-br command returned 0, then <ext_bridge_iface> exists
  if $?.to_i == 0
    # Raise exception and terminate chef execution if ext_bridge_iface is plugged into another bridge on OVS
    if check_port != "#{ext_bridge}"
       Chef::Application.fatal!("Didn't expect the #{ext_bridge_iface} in other bridge #{check_port}! Should be assigned to #{ext_bridge} by chef. Remove this port from invalid bridge (ovs-vsctl del-port #{check_port} #{ext_bridge_iface}) and try again!", 42)
    end
  # If port <ext_bridge_iface> doesn't exist and corresponding interface is present - add it to <ext_bridge>
  else
    execute 'add interface to external network bridge' do
      command "ovs-vsctl add-port #{ext_bridge} #{ext_bridge_iface}"
      action :run
      only_if "ip link show #{ext_bridge_iface}"
    end
  end
when 'BridgeInterfaceDriver'
  # TODO: Handle linuxbridge case
end
