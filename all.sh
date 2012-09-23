#!/usr/bin/env bash

INSTANCE_IMAGE=${INSTANCE_IMAGE:-bridge-precise}

source $(dirname $0)/chef-jenkins.sh

init

rm -rf logs
mkdir -p logs/run
exec 9>logs/run/out.log
BASH_XTRACEFD=9
set -x

declare -a cluster
cluster=(mysql keystone glance api horizon compute1 compute2 proxy storage1 storage2 storage3 graphite)

boot_and_wait chef-server
wait_for_ssh $(ip_for_host chef-server)

x_with_server "Uploading cookbooks" "chef-server" <<EOF
update_package_provider
flush_iptables
install_package git-core
rabbitmq_fixup
chef_fixup
checkout_cookbooks
upload_cookbooks
upload_roles
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}
wait_for_cluster_ssh ${cluster[@]}

echo "Cluster booted... setting up vpn thing"
setup_private_network br100 br99 api ${cluster[@]}

# at this point, chef server is done, cluster is up.
# let's set up the environment.

create_chef_environment chef-server bigcluster
set_environment_attribute chef-server bigcluster "override_attributes/glance/image_upload" "false"

# fix up the storage nodes
x_with_cluster "un-fscking ephemerals" storage1 storage2 storage3 <<EOF
umount /mnt
dd if=/dev/zero of=/dev/vdb bs=1024 count=1024
grep -v "/mnt" /etc/fstab > /tmp/newfstab
cp /tmp/newfstab /etc/fstab
EOF

x_with_cluster "Running/registering chef-client" ${cluster[@]} <<EOF
update_package_provider
flush_iptables
install_chef_client
fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client -ldebug
EOF

# clients are all kicked and inserted into chef server.  Need to
# set up the proper roles for the nodes and go.
for d in "${cluster[@]}"; do
    set_environment chef-server ${d} bigcluster
done

role_add chef-server mysql "role[mysql-master]"
x_with_cluster "Installing mysql" mysql <<EOF
chef-client -ldebug
EOF

role_add chef-server keystone "role[rabbitmq-server]"
role_add chef-server keystone "role[keystone]"
x_with_cluster "Installing keystone" keystone <<EOF
chef-client -ldebug
EOF

role_add chef-server proxy "role[swift-management-server]"
role_add chef-server proxy "role[swift-proxy-server]"

for node_no in {1..3}; do
    role_add chef-server storage${node_no} "role[swift-object-server]"
    role_add chef-server storage${node_no} "role[swift-container-server]"
    role_add chef-server storage${node_no} "role[swift-account-server]"
    set_node_attribute chef-server storage${node_no} "normal/swift" "{\"zone\": ${node_no} }"
done

role_add chef-server glance "role[glance-registry]"
role_add chef-server glance "role[glance-api]"

x_with_cluster "Installing glance and swift proxy" proxy glance <<EOF
chef-client -ldebug
EOF

role_add chef-server api "role[nova-setup]"
role_add chef-server api "role[nova-scheduler]"
role_add chef-server api "role[nova-api-ec2]"
role_add chef-server api "role[nova-api-os-compute]"
role_add chef-server api "role[nova-vncproxy]"
role_add chef-server api "role[nova-volume]"

x_with_cluster "Installing API and storage nodes" api storage{1..3} <<EOF
chef-client -ldebug
EOF

role_add chef-server api "recipe[kong]"
role_add chef-server api "recipe[exerstack]"
role_add chef-server horizon "role[horizon-server]"
role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"

# run the proxy to generate the ring, now that we
# have discovered disks (ephemeral0)
x_with_cluster "proxy/api/horizon/computes" proxy api horizon compute{1..2} <<EOF
chef-client -ldebug
EOF

# Now run all the storage servers
x_with_cluster "Storage - Pass 2" storage{1..3} <<EOF
chef-client -ldebug
EOF

# and now pull the rings
x_with_cluster "All nodes - Pass 1" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

# turn on glance uploads again
set_environment_attribute chef-server bigcluster "override_attributes/glance/image_upload" "true"

# and again, just for good measure.
x_with_cluster "All nodes - Pass 2" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

x_with_server "fixerating" api <<EOF
install_package swift
ip addr add 192.168.100.254/24 dev br99
EOF
background_task "fc_do"
collect_tasks

retval=0

if ( ! run_tests api essex-final nova glance swift keystone glance-swift ); then
    echo "Tests failed."
    retval=1
fi

x_with_cluster "Fixing log perms" keystone glance api horizon compute1 compute2  <<EOF
if [ -e /var/log/nova ]; then chmod 755 /var/log/nova; fi
if [ -e /var/log/keystone ]; then chmod 755 /var/log/keystone; fi
if [ -e /var/log/apache2 ]; then chmod 755 /var/log/apache2; fi
EOF

cluster_fetch_file "/var/log/{nova,glance,keystone,apache2}/*log" ./logs ${cluster[@]}

if [ $retval -eq 0 ]; then
    if [ -n "${GIT_COMMENT_URL}" ] && [ "${GIT_COMMENT_URL}" != "noop" ] ; then
        github_post_comment ${GIT_COMMENT_URL} "Gate:  Nova AIO\n * ${BUILD_URL}consoleFull : SUCCESS"
    else
        echo "skipping building comment"
    fi
fi

exit $retval
