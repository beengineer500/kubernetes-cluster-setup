#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to print major section headers (START/END)
print_step_header() {
    local step_name=$1
    local status=$2 # START, END

    case "$status" in
        START)
            echo ""
            echo -e "${YELLOW}=================================================="
            echo -e "➡️ 단계 시작: $step_name"
            echo -e "==================================================${NC}"
            ;;
        END)
            echo -e "${YELLOW}=================================================="
            echo -e "⬅️ 단계 종료: $step_name"
            echo -e "==================================================${NC}"
            echo ""
            ;;
    esac
}

# Function to check command execution status
check_status() {
    local task_description=$1
    local command_output=$2 # Optional: pass command output if needed for error details
    if [ $? -eq 0 ]; then
        print_success "$task_description 완료"
    else
        print_error "$task_description 실패"
        if [ -n "$command_output" ]; then
            print_error "오류 메시지: $command_output"
        fi
        exit 1 # Exit on failure
    fi
}

# Clear screen
clear

# Script header
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}     Kubernetes Cluster Setup Script v2.0       ${NC}"
echo -e "${BLUE}================================================${NC}"
echo

# 1. System Information Check and User Confirmation
print_step_header "1단계: 시스템 정보 확인 및 사용자 확인"

print_info "현재 시스템 정보를 확인합니다..."

# OS Version Check (more robust)
OS_VERSION=$(cat /etc/redhat-release 2>/dev/null || lsb_release -ds 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '"')
if [ -z "$OS_VERSION" ]; then
    OS_VERSION="알 수 없음"
fi
echo "  - 현재 OS 버전: $OS_VERSION"

# Network Interface List and IP Information
echo "  - 네트워크 인터페이스 목록 및 IP 정보:"
nmcli dev show | grep "GENERAL.DEVICE:" | awk '{print $2}' | while read -r device; do
    echo "    - 디바이스: $device"
    nmcli -g GENERAL.TYPE,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS dev show "$device" 2>/dev/null
done

read -p "위 정보가 올바른가요? (y/n): " confirm_info
if [[ ! "$confirm_info" =~ ^[Yy]$ ]]; then
    print_error "사용자가 시스템 정보 확인을 취소했습니다. 스크립트를 종료합니다."
    exit 1
fi
print_success "시스템 정보 확인 완료"
print_step_header "1단계: 시스템 정보 확인 및 사용자 확인" "END"


# 2. Get User Input for Configuration Variables
print_step_header "2단계: 사용자 입력 변수 설정"

# Node type
echo "노드 종류를 선택하세요:"
echo "1) Master Node"
echo "2) Worker Node"
read -p "선택 (1 또는 2): " node_type_choice

if [ "$node_type_choice" == "1" ]; then
    NODE_TYPE="master"
    print_info "Master Node로 설정합니다."
elif [ "$node_type_choice" == "2" ]; then
    NODE_TYPE="worker"
    print_info "Worker Node로 설정합니다."
else
    print_error "잘못된 노드 종류 선택입니다. 스크립트를 종료합니다."
    exit 1
fi

read -p "이 노드의 호스트 이름을 입력하세요 (예: k8s-master01 또는 k8s-worker01): " HOSTNAME
read -p "이 노드의 IP 주소를 입력하세요 (예: 192.168.0.100): " NODE_IP

# Get network interface name interactively
echo "사용 가능한 네트워크 인터페이스 목록:"
nmcli con show | grep -v NAME | awk '{print NR")", $1}'
read -p "네트워크 인터페이스 번호를 선택하세요: " interface_num
INTERFACE_NAME=$(nmcli con show | grep -v NAME | awk -v n=$interface_num 'NR==n {print $1}')

if [ -z "$INTERFACE_NAME" ]; then
    print_error "잘못된 네트워크 인터페이스 번호입니다. 스크립트를 종료합니다."
    exit 1
fi
print_info "선택된 네트워크 인터페이스: $INTERFACE_NAME"

read -p "DNS 서버 주소를 입력하세요 (기본값: 8.8.8.8): " DNS_SERVER
DNS_SERVER=${DNS_SERVER:-8.8.8.8}

# Master node IP and Hostname (for both master and worker)
if [ "$NODE_TYPE" == "worker" ]; then
    read -p "Master 노드의 IP 주소를 입력하세요: " MASTER_IP
    read -p "Master 노드의 호스트명을 입력하세요: " MASTER_HOSTNAME
else # If this is a master node, its own IP and hostname are the master's
    MASTER_IP=$NODE_IP
    MASTER_HOSTNAME=$HOSTNAME
fi

# Worker nodes info (only for master node)
WORKER_IPS=()
WORKER_HOSTNAMES=()
if [ "$NODE_TYPE" == "master" ]; then
    read -p "클러스터에 워커 노드가 있습니까? (y/n): " has_workers
    if [[ "$has_workers" =~ ^[Yy]$ ]]; then
        read -p "워커 노드의 개수를 입력하세요: " worker_count
        if ! [[ "$worker_count" =~ ^[0-9]+$ ]] || [ "$worker_count" -eq 0 ]; then
            print_warning "유효하지 않은 워커 노드 개수입니다. 워커 노드 정보를 건너뜀."
        else
            for ((i=1; i<=worker_count; i++)); do
                read -p "Worker $i 의 IP 주소를 입력하세요: " worker_ip
                read -p "Worker $i 의 호스트명을 입력하세요: " worker_hostname
                WORKER_IPS+=("$worker_ip")
                WORKER_HOSTNAMES+=("$worker_hostname")
            done
        fi
    fi
fi

echo ""
print_step_header "3단계: 설정 값 확인"
echo "입력하신 정보 확인:"
echo "  - 노드 종류: $NODE_TYPE"
echo "  - 호스트명: $HOSTNAME"
echo "  - IP 주소: $NODE_IP"
echo "  - 네트워크 인터페이스: $INTERFACE_NAME"
echo "  - DNS 서버: $DNS_SERVER"
echo "  - Master 노드 IP: $MASTER_IP"
echo "  - Master 호스트명: $MASTER_HOSTNAME"
if [ "$NODE_TYPE" == "master" ] && [ ${#WORKER_IPS[@]} -gt 0 ]; then
    echo "  - 워커 노드들:"
    for ((i=0; i<${#WORKER_IPS[@]}; i++)); do
        echo "    - ${WORKER_HOSTNAMES[$i]}: ${WORKER_IPS[$i]}"
    done
fi
echo ""

read -p "위 설정이 맞습니까? (y/n): " confirm_vars
if [[ ! "$confirm_vars" =~ ^[Yy]$ ]]; then
    print_error "사용자가 변수 설정을 취소했습니다. 스크립트를 종료합니다."
    exit 1
fi
print_success "사용자 입력 변수 설정 완료"
print_step_header "2단계: 사용자 입력 변수 설정" "END"


# --- Main Script Logic Starts ---

# 4. Configure Local Yum Repository
print_step_header "4단계: 로컬 Yum 리포지토리 설정"
print_info "로컬 Yum 리포지토리 설정을 시작합니다..."
if ! sudo tee /etc/yum.repos.d/local.repo > /dev/null <<EOF
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
then
    check_status "로컬 Yum 리포지토리 파일 생성" "파일 쓰기 실패"
fi
check_status "로컬 Yum 리포지토리 파일 생성"

sudo yum clean all > /dev/null 2>&1
check_status "Yum 캐시 정리"

sudo yum repolist > /dev/null 2>&1
check_status "Yum 리포지토리 목록 확인"

sudo yum list > /dev/null 2>&1
check_status "Yum 패키지 목록 확인"
print_step_header "4단계: 로컬 Yum 리포지토리 설정" "END"


# 5. Disable Firewalld
print_step_header "5단계: Firewalld 중지 및 비활성화"
print_info "Firewalld를 중지하고 비활성화합니다..."
# Check if firewalld is active before stopping
if systemctl status firewalld | grep -q "active (running)"; then
    sudo systemctl stop firewalld
    check_status "Firewalld 중지"
fi

# Check if firewalld is enabled before disabling
if systemctl is-enabled firewalld | grep -q "enabled"; then
    sudo systemctl disable firewalld > /dev/null 2>&1
    check_status "Firewalld 자동 시작 비활성화"
fi
print_step_header "5단계: Firewalld 중지 및 비활성화" "END"


# 6. Disable SELinux
print_step_header "6단계: SELinux 비활성화"
print_info "SELinux를 비활성화합니다..."

sudo sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
check_status "SELinux 설정 파일 수정"

# Apply immediately (will be fully applied after reboot)
sudo setenforce 0 2>/dev/null || true
print_success "SELinux 즉시 비활성화 (재부팅 후 완전 적용)"

# Verify change in config file
if ! grep -q "SELINUX=disabled" /etc/selinux/config; then
    print_error "SELinux 설정 확인 실패: SELINUX=disabled가 /etc/selinux/config에 적용되지 않았습니다."
    exit 1
fi
print_step_header "6단계: SELinux 비활성화" "END"


# 7. Set Hostname
print_step_header "7단계: 호스트 이름 설정"
print_info "호스트 이름을 '$HOSTNAME'으로 설정합니다..."

sudo hostnamectl set-hostname "$HOSTNAME"
check_status "호스트 이름 설정"

# Verify hostname
if [ "$(hostname)" != "$HOSTNAME" ]; then
    print_error "호스트 이름 설정 실패: 호스트 이름이 '$HOSTNAME'으로 올바르게 설정되지 않았습니다."
    exit 1
fi
print_step_header "7단계: 호스트 이름 설정" "END"


# 8. Configure Hosts File
print_step_header "8단계: /etc/hosts 파일 설정"
print_info "/etc/hosts 파일을 설정합니다..."

# Remove existing k8s entries to prevent duplicates
sudo sed -i '/k8s-master/d' /etc/hosts
sudo sed -i '/k8s-worker/d' /etc/hosts

# Add master node entry (always needed)
echo "$MASTER_IP $MASTER_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
check_status "Master 노드 엔트리 추가"

# Add current node's entry if it's a worker
if [ "$NODE_TYPE" == "worker" ]; then
    echo "$NODE_IP $HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
    check_status "현재 워커 노드 엔트리 추가"
fi

# Add other worker nodes entries if this is a master
if [ "$NODE_TYPE" == "master" ] && [ ${#WORKER_IPS[@]} -gt 0 ]; then
    for ((i=0; i<${#WORKER_IPS[@]}; i++)); do
        echo "${WORKER_IPS[$i]} ${WORKER_HOSTNAMES[$i]}" | sudo tee -a /etc/hosts > /dev/null
        check_status "Worker 노드 ${WORKER_HOSTNAMES[$i]} 엔트리 추가"
    done
fi

# Verify entries
if ! grep -q "$MASTER_IP $MASTER_HOSTNAME" /etc/hosts; then
    print_error "/etc/hosts 파일 확인 실패: Master 노드 엔트리가 누락되었습니다."
    exit 1
fi
if [ "$NODE_TYPE" == "worker" ] && ! grep -q "$NODE_IP $HOSTNAME" /etc/hosts; then
    print_error "/etc/hosts 파일 확인 실패: 현재 워커 노드 엔트리가 누락되었습니다."
    exit 1
fi
print_success "/etc/hosts 파일 설정 완료"
print_step_header "8단계: /etc/hosts 파일 설정" "END"


# 9. Configure Network DNS
print_step_header "9단계: 네트워크 연결 DNS 설정"
print_info "네트워크 인터페이스 '$INTERFACE_NAME'의 DNS를 '$DNS_SERVER'로 설정합니다..."

sudo nmcli con mod "$INTERFACE_NAME" ipv4.dns "$DNS_SERVER"
check_status "DNS 서버 설정"

sudo nmcli con up "$INTERFACE_NAME" > /dev/null 2>&1
check_status "네트워크 연결 재시작"

# Verify DNS setting
if ! nmcli -g IP4.DNS dev show "$INTERFACE_NAME" | grep -q "$DNS_SERVER"; then
    print_error "네트워크 연결 DNS 설정 실패: DNS가 '$DNS_SERVER'으로 설정되지 않았습니다."
    exit 1
fi
print_step_header "9단계: 네트워크 연결 DNS 설정" "END"


# 10. Check Chronyd Status
print_step_header "10단계: Chronyd 상태 확인"
print_info "Chronyd 서비스 상태를 확인합니다..."

systemctl status chronyd > /dev/null
check_status "Chronyd 서비스 상태 확인"

chronyc tracking > /dev/null
check_status "Chronyd 추적 상태 확인"

chronyc sources > /dev/null
check_status "Chronyd 소스 목록 확인"
print_step_header "10단계: Chronyd 상태 확인" "END"


# 11. Disable Swap
print_step_header "11단계: Swap 비활성화"
print_info "Swap을 비활성화하고 /etc/fstab에서 주석 처리합니다..."

if swapon --show | grep -q "swap"; then
    sudo swapoff -a
    check_status "Swap 즉시 비활성화"
else
    print_info "Swap이 이미 비활성화되어 있습니다."
fi

# Remove swap entries from /etc/fstab
sudo sed -i '/swap/d' /etc/fstab
check_status "Swap 영구 비활성화 (fstab 수정)"

# Verify swap is disabled
if swapon --show | grep -q "swap"; then
    print_error "Swap 비활성화 실패: Swap이 여전히 활성화되어 있습니다."
    exit 1
fi
print_step_header "11단계: Swap 비활성화" "END"


# 12. Remove Old Container Packages
print_step_header "12단계: 기존 컨테이너 패키지 제거"
print_info "기존 Docker, Podman 및 관련 패키지를 제거합니다 (설치되어 있지 않아도 오류 무시)..."

sudo dnf remove -y docker \
docker-client \
docker-client-latest \
docker-common \
docker-latest \
docker-latest-logrotate \
docker-logrotate \
docker-engine \
podman \
runc > /dev/null 2>&1
print_success "기존 패키지 제거 완료 (설치되지 않은 경우 경고 무시)"
print_step_header "12단계: 기존 컨테이너 패키지 제거" "END"


# 13. Download Docker/Containerd Packages
print_step_header "13단계: Docker/Containerd 패키지 다운로드"
print_info "Docker 및 Containerd 패키지를 다운로드합니다..."

DOCKER_RPMS_DIR="/tmp/docker_rpms"
mkdir -p "$DOCKER_RPMS_DIR"
check_status "다운로드 디렉토리 생성 ($DOCKER_RPMS_DIR)"

cd "$DOCKER_RPMS_DIR" || check_status "다운로드 디렉토리로 이동" "디렉토리 변경 실패: $DOCKER_RPMS_DIR"

DOCKER_PACKAGES=(
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/containerd.io-1.7.27-3.1.el9.x86_64.rpm"
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-buildx-plugin-0.23.0-1.el9.x86_64.rpm"
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-28.1.1-1.el9.x86_64.rpm"
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-cli-28.1.1-1.el9.x86_64.rpm"
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-rootless-extras-28.1.1-1.el9.x86_64.rpm"
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-compose-plugin-2.35.1-1.el9.x86_64.rpm"
)

for url in "${DOCKER_PACKAGES[@]}"; do
    filename=$(basename "$url")
    print_info "  - $filename 다운로드 중..."
    curl_output=$(curl -fsSLO "$url" 2>&1)
    check_status "$filename 다운로드" "$curl_output"
done
print_step_header "13단계: Docker/Containerd 패키지 다운로드" "END"


# 14. Install Docker/Containerd Packages
print_step_header "14단계: Docker 및 Containerd 패키지 설치"
print_info "다운로드된 RPM 패키지를 설치합니다..."

sudo yum localinstall -y "$DOCKER_RPMS_DIR"/*.rpm > /dev/null 2>&1
check_status "Docker 및 Containerd 패키지 설치"
print_step_header "14단계: Docker 및 Containerd 패키지 설치" "END"


# 15. Start and Enable Docker and Containerd
print_step_header "15단계: Docker 및 Containerd 시작 및 활성화"
for service in docker containerd; do
    print_info "  - $service 서비스 시작 및 활성화 중..."
    sudo systemctl start "$service"
    check_status "$service 시작"

    sudo systemctl enable "$service" > /dev/null 2>&1
    check_status "$service 활성화"

    if ! systemctl is-enabled "$service" | grep -q "enabled"; then
        print_error "$service 활성화 확인 실패: $service가 활성화되지 않았습니다."
        exit 1
    fi
    if ! systemctl status "$service" | grep -q "active (running)"; then
        print_error "$service 상태 확인 실패: $service가 실행 중이 아닙니다."
        exit 1
    fi
done
print_step_header "15단계: Docker 및 Containerd 시작 및 활성화" "END"


# 16. Configure Containerd SystemdCgroup
print_step_header "16단계: Containerd SystemdCgroup 설정"
print_info "Containerd 기본 설정을 생성하고 SystemdCgroup을 true로 변경합니다..."

sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
check_status "Containerd 기본 설정 생성"

sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
check_status "Containerd SystemdCgroup 설정 변경"

# Verify change
if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
    print_error "Containerd SystemdCgroup 설정 실패: SystemdCgroup이 true로 설정되지 않았습니다."
    exit 1
fi

print_info "Containerd 서비스를 재시작합니다..."
sudo systemctl restart containerd
check_status "Containerd 재시작"
print_step_header "16단계: Containerd SystemdCgroup 설정" "END"


# 17. Load Kernel Modules
print_step_header "17단계: 커널 모듈 로드"
print_info "overlay 및 br_netfilter 모듈을 로드하도록 설정합니다..."

if ! sudo tee /etc/modules-load.d/containerd.conf > /dev/null <<EOF
overlay
br_netfilter
EOF
then
    check_status "커널 모듈 설정 파일 생성" "파일 쓰기 실패"
fi
check_status "커널 모듈 설정 파일 생성"

print_info "모듈을 즉시 로드합니다..."
sudo modprobe overlay
check_status "overlay 모듈 로드"

sudo modprobe br_netfilter
check_status "br_netfilter 모듈 로드"

# Verify modules are loaded
if ! lsmod | grep -q "overlay"; then
    print_error "overlay 모듈 로드 확인 실패: overlay 모듈이 로드되지 않았습니다."
    exit 1
fi
if ! lsmod | grep -q "br_netfilter"; then
    print_error "br_netfilter 모듈 로드 확인 실패: br_netfilter 모듈이 로드되지 않았습니다."
    exit 1
fi
print_step_header "17단계: 커널 모듈 로드" "END"


# 18. Configure Kubernetes Sysctl Parameters
print_step_header "18단계: 쿠버네티스 Sysctl 파라미터 설정"
print_info "쿠버네티스에 필요한 Sysctl 파라미터를 설정합니다..."

if ! sudo tee /etc/sysctl.d/k8s.conf > /dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
then
    check_status "Sysctl 설정 파일 생성" "파일 쓰기 실패"
fi
check_status "Sysctl 설정 파일 생성"

print_info "Sysctl 설정을 적용합니다..."
sudo sysctl --system > /dev/null 2>&1
check_status "Sysctl 설정 적용"

# Verify IP forwarding
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -ne "1" ]; then
    print_error "IP 포워딩 확인 실패: IP 포워딩이 활성화되지 않았습니다."
    exit 1
fi
print_step_header "18단계: 쿠버네티스 Sysctl 파라미터 설정" "END"


# 19. Add Kubernetes Yum Repository
print_step_header "19단계: 쿠버네티스 Yum 리포지토리 추가"
print_info "쿠버네티스 Yum 리포지토리를 추가합니다..."

if ! sudo tee /etc/yum.repos.d/kubernetes.repo > /dev/null <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
then
    check_status "쿠버네티스 리포지토리 설정 파일 생성" "파일 쓰기 실패"
fi
check_status "쿠버네티스 리포지토리 설정 파일 생성"

# Verify repository addition
if ! sudo yum repolist | grep -q "kubernetes"; then
    print_error "쿠버네티스 리포지토리 확인 실패: 쿠버네티스 리포지토리가 추가되지 않았습니다."
    exit 1
fi
print_step_header "19단계: 쿠버네티스 Yum 리포지토리 추가" "END"


# 20. Install Kubelet, Kubeadm, Kubectl
print_step_header "20단계: Kubelet, Kubeadm, Kubectl 설치"
print_info "kubelet, kubeadm, kubectl 패키지를 설치합니다..."

sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes > /dev/null 2>&1
check_status "Kubelet, Kubeadm, Kubectl 설치"
print_step_header "20단계: Kubelet, Kubeadm, Kubectl 설치" "END"


# 21. Enable Kubelet
print_step_header "21단계: Kubelet 시작 및 활성화"
print_info "Kubelet 서비스를 시작하고 활성화합니다..."

sudo systemctl start kubelet
check_status "Kubelet 시작"

sudo systemctl enable kubelet > /dev/null 2>&1
check_status "Kubelet 활성화"

# Verify Kubelet status
if ! systemctl is-enabled kubelet | grep -q "enabled"; then
    print_error "Kubelet 활성화 확인 실패: Kubelet이 활성화되지 않았습니다."
    exit 1
fi
if ! systemctl status kubelet | grep -q "active (running)"; then
    print_error "Kubelet 상태 확인 실패: Kubelet이 실행 중이 아닙니다."
    exit 1
fi
print_step_header "21단계: Kubelet 시작 및 활성화" "END"


# Final Summary
print_step_header "설치 완료"
echo -e "${GREEN}Kubernetes 클러스터 환경 구성이 완료되었습니다!${NC}"
echo
echo "다음 단계:"
if [ "$NODE_TYPE" == "master" ]; then
    echo "1. 시스템을 재부팅하세요: sudo reboot"
    echo "2. 재부팅 후 다음 명령을 실행하여 클러스터를 초기화하세요:"
    echo "   sudo kubeadm init --apiserver-advertise-address=$NODE_IP --pod-network-cidr=10.244.0.0/16"
    echo "3. 초기화 후 출력되는 'kubeadm join' 명령을 워커 노드에서 실행하세요."
else
    echo "1. 시스템을 재부팅하세요: sudo reboot"
    echo "2. Master 노드에서 'kubeadm init' 실행 후 출력되는 'kubeadm join' 명령을 실행하세요."
fi
echo
print_warning "주의: SELinux 비활성화는 재부팅 후 완전히 적용됩니다."

# Cleanup
print_info "임시 다운로드 파일들을 정리합니다..."
sudo rm -rf "$DOCKER_RPMS_DIR" 2>/dev/null
check_status "임시 파일 정리"

print_success "스크립트 실행이 완료되었습니다!"
print_step_header "설치 완료" "END"
