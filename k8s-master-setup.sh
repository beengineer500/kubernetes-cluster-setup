#/bin/bash

lsblk;

mkdir /iso /mnt/cdrom

mount /dev/sr0 /mnt/cdrom

cp -rvf /mnt/cdrom/* /iso


# cp가 끝나고 나서 umount가 되도록 해야한다. sleep??
umount /mnt/cdrom

cat <<EOF | sudo tee /etc/yum.repos.d/local.repo
[BaseOS]
name=BaseOS
baseurl=file:///iso/BaseOS
enabled=1
gpgcheck=0
 
[AppStream]
name=AppStream
baseurl=file:///iso/AppStream
enabled=1
gpgcheck=0
EOF

yum clean all

yum repolist

yum list

systemctl status firewalld

systemctl stop firewalld

systemctl disable firewalld

sed -i 's/SELINUX=enforcing/SELINUX=disalbed/' /etc/selinux/config

cat /etc/selinux/config | grep SELINUX

hostnamectl set-hostname k8s-master01

echo "192.168.0.100 k8s-master01" >> /etc/hosts
echo "192.168.0.200 k8s-worker01" >> /etc/hosts
cat /etc/hosts

nmcli con show
nmcli dev show

nmcli con mod $(CON_NAME) ipv4.dns 8.8.8.8


systemctl status chronyd

chronyc tracking
chronyc sources

swapoff -a
swapon --show

cat /etc/fstab | grep swap

dnf remove docker \
docker-client \
docker-client-latest \
docker-common \
docker-latest \
docker-latest-logrotate \
docker-logrotate \
docker-engine \
podman \
runc

curl -fsSLO https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/containerd.io-1.7.27-3.1.el9.x86_64.rpm
curl -fsSLO https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-buildx-plugin-0.23.0-1.el9.x86_64.rpm
curl -fsSLO https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-28.1.1-1.el9.x86_64.rpm
curl -fsSLO https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-cli-28.1.1-1.el9.x86_64.rpm
curl -fsSLO https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-rootless-extras-28.1.1-1.el9.x86_64.rpm
curl -fsSL https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-compose-plugin-2.35.1-1.el9.x86_64.rpm


# 다운 다되는 거 기다린 후
systemctl status docker
systemctl start docker
systemctl enable docker
systemctl is-enabled docker

systemctl status containerd
systemctl start containerd
systemctl enable containerd
systemctl is-enabled containerd


containerd config default | sudo tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
grep 'SystemdCgroup' /etc/containerd/config.toml
systemctl restart containerd