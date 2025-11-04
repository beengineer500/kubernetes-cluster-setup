#!/bin/bash
set -eou pipefail

echo '#===================================================#'
echo '# This is shellscript for k8s-master-node @Online #'
echo '#===================================================#'  

echo "1) Disable firewalld"
sudo systemctl disable --now firewalld
echo "===== 1) Done ====="
echo
echo


echo "2) Disable SElinux"
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
echo "===== 2) Done ====="
echo
echo


# echo "3) Swap off"
# sudo swapoff -a
# sudo sed -i "@swap@s/^/#@" /etc/fstab
# echo "===== 3) Done ====="
# echo
# echo


echo "4) Configure Hostname"
echo "Type hostname for this server that you want to use"
read HOSTNAME
sudo hostnamectl set-hostname ${HOSTNAME}
echo "4) Done"
echo
echo


echo "5) Configure /etc/hosts"
cat <<EOF | sudo tee /etc/hosts
# XXX.XXX.XXX.XXX cluster-endpoint
#  
# XXX.XXX.XXX.XXX k8s-master01
# XXX.XXX.XXX.XXX k8s-master02
# XXX.XXX.XXX.XXX k8s-master03
#
# XXX.XXX.XXX.XXX h200-001
# XXX.XXX.XXX.XXX h200-002
# XXX.XXX.XXX.XXX h200-003
EOF
echo "===== 5) Done ====="
echo
echo


echo "6) Configure /etc/resolv.conf"
cat <<EOF | sudo tee /etc/resolv.conf
nameserver 168.126.63.2
EOF
echo "===== 6) Done ====="
echo
echo

echo "7) Configure sysctl parameters"
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
fs.inotify.max_user_instances = 4096
fs.inotify.max_user_watches = 1048576
vm.max_map_count = 524288
EOF
sudo sysctl --system
echo "===== 7) Done ====="
echo
echo

echo "8) Load Kubernetes Kernel Modules"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
ip_tables
EOF
sudo modprobe overlay br_netfilter ip_tables
echo "===== 8) Done ====="
echo
echo

echo "9) Load ipvs Kernel Modules"
cat <<EOF | sudo tee /etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_lc
ip_vs_wlc
ip_vs_lblc
ip_vs_lblcr
ip_vs_sh
ip_vs_dh
ip_vs_sed
ip_vs_nq
nf_conntrack
EOF
sudo modprobe ip_vs ip_vs_rr ip_vs_wrr ip_vs_lc ip_vs_wlc ip_vs_lblc ip_vs_lblcr ip_vs_sh ip_vs_dh ip_vs_sed ip_vs_nq nf_conntrack
echo "===== 9) Done ====="
echo
echo


echo "10) Download Packages from RHEL 9.4"
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && sleep 1 && dnf list &> /dev/null;
sudo dnf install -y net-tools \
wget \
traceroute \
iproute \
iperf3 \
ipmitool \
nano \
vim \
python3 \
jq \
dnf-dnf-plugins-core && sleep 1;
echo "===== 10) Done ====="
echo
echo


echo "11) Download Containerd & Docker Packages"
mkdir -p /root/containerd-docker-pkgs
wget -P /root/containerd-docker-pkgs https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/containerd.io-1.7.28-1.el9.x86_64.rpm
wget -P /root/containerd-docker-pkgs https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-buildx-plugin-0.29.1-1.el9.x86_64.rpm
wget -P /root/containerd-docker-pkgs https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-28.5.1-1.el9.x86_64.rpm
wget -P /root/containerd-docker-pkgs https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-cli-28.5.1-1.el9.x86_64.rpm
wget -P /root/containerd-docker-pkgs https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-rootless-extras-28.5.1-1.el9.x86_64.rpm
wget -P /root/containerd-docker-pkgs https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-compose-plugin-2.40.3-1.el9.x86_64.rpm
wget -P /root/containerd-docker-pkgs https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-model-plugin-0.1.44-1.el9.x86_64.rpm
sudo dnf install -y /root/containerd-docker-pkgs/*.rpm
sleep 1;
echo "Enable containerd & Docker"
sudo systemctl enable --now containerd \
&& sudo systemctl enable --now docker \
&& sleep 1;
echo "===== 11) Done ====="
echo
echo
  
echo "12) ADD Repository for Kubernetes v1.31"
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
sudo dnf repolist \
&& sudo dnf list &> /dev/null;
echo "===== 10) Done ====="
echo
echo


echo "12) Download Kubernetes Packages"
sudo mkdir -p /k8s-pkgs
sudo dnf install -y --disableexcludes=kubernetes --downloadonly --downloaddir=/root/k8s-pkgs kubeadm-1.31.13 \
kubelet-1.31.13 \
kubectl-1.31.13 \
cri-tools-1.31.1 \
kubernetes-cni-1.5.1 && sleep 1;
echo "===== 12) Done ====="
echo
echo


echo "13) Install Kubernetes packages"
sudo dnf install -y /root/k8s-pkgs/*.rpm
echo "===== 13) Done ====="
echo
echo


echo "14) Unlimit container's resources"
cat <<EOF | sudo tee /etc/systemd/system/containerd.service.d/override.conf
[Service]
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
LimitMEMLOCK=infinity
EOF
sudo systemctl daemon-reload && sudo systemctl restart 
echo "===== 14) Done ====="
echo
echo

echo "15) Configure containerd's volume directory"
sudo mkdir -p /data/containerd/var/lib/containerd
sudo mkdir -p /data/containerd/var/run/containerd
sudo mkdir -p /data/containerd/run/containerd
sudo mkdir -p /data/docker/var/lib/docker
sudo mkdir -p /data/docker/var/run/docker
sudo mkdir -p /data/docker/run/docker
sudo mkdir 

# Creating containerd config
sudo mkdir -p /etc/containerd && containerd config default | sudo tee /etc/containerd/config.toml

# modify containerd config
sudo sed -i 's@SystemdCgroup = false@SystemdCgroup = true@g' /etc/containerd/config.toml
sudo sed -i 's@root = "/var/lib/containerd"@root = "/data/containerd/var/lib/containerd"@g' /etc/containerd/config.toml
sudo sed -i 's@state = "/run/containerd"@state = "/data/containerd/run/containerd"@g' /etc/containerd/config.toml
sudo sed -i 's@ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock@ExecStart=/usr/bin/dockerd -H fd:// --containerd=/data/containerd/run/containerd/containerd.sock --data-root=/data/docker/var/lib/docker --exec-root=/data/docker/run/docker@g' /usr/lib/systemd/system/docker.service

sudo systemctl daemon-realod && sudo systemctl restart containerd
echo "===== 15) Done ====="
echo
echo

echo "16) Configure containerd config about certs & registry(harbor)"
# !!!!!!!!!!!!!!!! Need to edit !!!!!!!!!!!!!!!!
# sudo mkdir -p /etc/containerd/certs.d
# sudo sed -i 's@config_path = ""@config_path = "/etc/containerd/certs.d"@g' /etc/containerd/config.toml
# sudo sed -i 's@sandbox_image = "registry.k8s.io/pause:3.8"@sandbox_image = "harbor.co.kr/registry.k8s.io/pause:3.10"@g' /etc/containerd/config.toml
# sudo mkdir -p /etc/containerd/certs.d/harbor.co.kr
# cat <<EOF | sudo tee /etc/containerd/certs.d/harbor.co.kr/hosts.toml
# server = "http://harborco.kr"

# [host."http://harbor.co.kr"]
#   capabilities = ["pull", "resolve", "push"]
#   skip_verify = true

#   [host."http://harbor..co.kr".auth]
#     username = ""
#     password = ""
# EOF
# cat <<EOF | sudo tee /etc/docker/daemon.json
# {
#     "insecure-registries" : ["harbor.co.kr"]
# }
# EOF

sudo systemctl daemon-realod && sudo systemctl restart containerd
echo "===== 16) Done ====="
echo
echo


echo "17) Configure k8s GPU node"
sudo nvidia-ctk runtime configure --runtime=containerd
sudo sed -i 's/default_runtime_name = "runc"/default_runtime_name = "nvidia"/g' /etc/containerd/config.toml
sudo systemctl daemon-realod && sudo systemctl restart containerd
echo "===== 16) Done ====="
echo
echo


# echo "18) Initiating Kubernetes Cluster"
# echo 'Type pod-network-cidr you want to use (e.g. 10.250.0.0/16)'
# read POD_NETWORK_CIDR
# echo 'Type image-repository <IP or DomainName> you want to use (e.g. harbor/registry.k8s.io)'
# read IMAGE_REPO
# sudo kubeadm init --control-plane-endpoint="cluster-endpoint:6443" \
# --upload-certs \
# --pod-network-cidr=${POD_NETWORK_CIDR} \
# --service-cidr=10.96.0.0/12 \
# --kubernetes-version=1.31.13 \
# --image-repository=${IMAGE_REPO} && sleep 1;
# echo "===== 16) Done ====="
# echo
# echo


exit 1;