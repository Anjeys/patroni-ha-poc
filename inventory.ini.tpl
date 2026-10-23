[etcd_nodes]
node1 ansible_host=172.@NET@.0.2
node2 ansible_host=172.@NET@.0.3
node3 ansible_host=172.@NET@.0.4

[balancers]
balancer  ansible_host=172.@NET@.0.5 keepalived_state=MASTER keepalived_priority=150
balancer2 ansible_host=172.@NET@.0.6 keepalived_state=BACKUP keepalived_priority=100

[backup_hosts]
backup ansible_host=172.@NET@.0.7

[all:vars]
lab_net=@NET@
ansible_user=root
ansible_ssh_private_key_file=.ssh/lab_ed25519
ansible_python_interpreter=/usr/bin/python3
