#!/bin/bash

# 로그를 출력하는 함수
# 각 단계의 시작, 종료, 성공, 실패를 알립니다.
log_step() {
    local step_name=$1
    local status=$2 # START, END, SUCCESS, FAILURE
    local error_message=$3

    case "$status" in
        START)
            echo ""
            echo "=================================================="
            echo "➡️  단계 시작: $step_name"
            echo "=================================================="
            ;;
        END)
            echo "=================================================="
            echo "⬅️  단계 종료: $step_name"
            echo "=================================================="
            echo ""
            ;;
        SUCCESS)
            echo "✅ $step_name: 성공"
            ;;
        FAILURE)
            echo "❌ $step_name: 실패"
            echo "오류: $error_message"
            exit 1 # 실패 시 스크립트 종료
            ;;
    esac
}

echo "**************************************************"
echo "  쿠버네티스 노드 환경 구성 스크립트를 시작합니다.  "
echo "**************************************************"
echo ""

# 1. 시스템 정보 확인 및 사용자 확인
log_step "시스템 정보 확인" "START"

# OS 버전 확인
OS_VERSION=$(cat /etc/redhat-release 2>/dev/null || lsb_release -ds 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '"')
if [ -z "$OS_VERSION" ]; then
    OS_VERSION="알 수 없음"
fi

echo "현재 OS 버전: $OS_VERSION"
echo ""

# 네트워크 인터페이스 목록 및 IP 정보 확인
echo "네트워크 인터페이스 목록 및 IP 정보:"
nmcli dev show | grep "GENERAL.DEVICE:" | awk '{print $2}' | while read -r device; do
    echo "  - 디바이스: $device"
    # 각 디바이스의 상세 정보 표시
    device_type=$(nmcli -g GENERAL.TYPE dev show "$device" 2>/dev/null)
    device_state=$(nmcli -g GENERAL.STATE dev show "$device" 2>/dev/null)
    device_ip=$(nmcli -g IP4.ADDRESS dev show "$device" 2>/dev/null)
    device_gateway=$(nmcli -g IP4.GATEWAY dev show "$device" 2>/dev/null)
    device_dns=$(nmcli -g IP4.DNS dev show "$device" 2>/dev/null)
    
    echo "    타입: $device_type"
    echo "    상태: $device_state"
    echo "    IP 주소: ${device_ip:-없음}"
    echo "    게이트웨이: ${device_gateway:-없음}"
    echo "    DNS: ${device_dns:-없음}"
    echo ""
done

read -p "위 정보가 올바른가요? (y/n): " confirm_info
if [[ ! "$confirm_info" =~ ^[Yy]$ ]]; then
    echo "스크립트를 종료합니다. 시스템 정보를 확인해주세요."
    exit 1
fi
log_step "시스템 정보 확인" "SUCCESS"
log_step "시스템 정보 확인" "END"

# 2. 사용자 입력 변수 설정
log_step "사용자 입력 변수 설정" "START"

# 노드 종류 선택
echo "노드 종류를 선택하세요:"
echo "1) Master Node"
echo "2) Worker Node"
read -p "선택 (1 or 2): " node_type_choice

if [ "$node_type_choice" == "1" ]; then
    NODE_TYPE="master"
    echo "Master Node로 설정합니다."
else
    NODE_TYPE="worker"
    echo "Worker Node로 설정합니다."
fi

# 기본 정보 입력
read -p "이 노드의 IP 주소를 입력하세요 (예: 192.168.0.100): " NODE_IP
read -p "이 노드의 호스트 이름을 입력하세요 (예: k8s-master01 또는 k8s-worker01): " NODE_HOSTNAME

# 네트워크 인터페이스 선택
echo ""
echo "사용 가능한 네트워크 연결:"
nmcli con show | grep -v "NAME" | nl -nrz -w2
echo ""
read -p "네트워크 연결 번호를 선택하세요: " interface_num
CON_NAME=$(nmcli con show | grep -v "NAME" | sed -n "${interface_num}p" | awk '{print $1}')

if [ -z "$CON_NAME" ]; then
    log_step "사용자 입력 변수 설정" "FAILURE" "유효하지 않은 네트워크 연결 번호입니다."
fi

# DNS 서버 설정
read -p "DNS 서버 주소를 입력하세요 (기본값: 8.8.8.8): " DNS_SERVER
DNS_SERVER=${DNS_SERVER:-8.8.8.8}

# 마스터/워커 노드별 추가 정보
if [[ "$NODE_TYPE" == "master" ]]; then
    read -p "워커 노드가 있습니까? (y/n): " has_workers
    if [[ "$has_workers" =~ ^[Yy]$ ]]; then
        read -p "워커 노드의 개수를 입력하세요: " worker_count
        WORKER_IPS=()
        WORKER_HOSTNAMES=()
        for ((i=1; i<=worker_count; i++)); do
            read -p "워커 노드 $i의 IP 주소를 입력하세요: " worker_ip
            read -p "워커 노드 $i의 호스트 이름을 입력하세요: " worker_hostname
            WORKER_IPS+=($worker_ip)
            WORKER_HOSTNAMES+=($worker_hostname)
        done
    fi
elif [[ "$NODE_TYPE" == "worker" ]]; then
    read -p "마스터 노드의 IP 주소를 입력하세요: " MASTER_IP
    read -p "마스터 노드의 호스트 이름을 입력하세요: " MASTER_HOSTNAME
fi

echo ""
echo "입력하신 정보 확인:"
echo "  - 노드 종류: $NODE_TYPE"
echo "  - 이 노드 IP: $NODE_IP"
echo "  - 이 노드 호스트 이름: $NODE_HOSTNAME"
echo "  - 네트워크 연결: $CON_NAME"
echo "  - DNS 서버: $DNS_SERVER"

if [[ "$NODE_TYPE" == "master" ]] && [[ "$has_workers" =~ ^[Yy]$ ]]; then
    echo "  - 워커 노드들:"
    for ((i=0; i<${#WORKER_IPS[@]}; i++)); do
        echo "    * ${WORKER_HOSTNAMES[$i]}: ${WORKER_IPS[$i]}"
    done
elif [[ "$NODE_TYPE" == "worker" ]]; then
    echo "  - 마스터 노드 IP: $MASTER_IP"
    echo "  - 마스터 노드 호스트 이름: $MASTER_HOSTNAME"
fi
echo ""

read -p "위 정보가 맞습니까? (y/n): " confirm_vars
if [[ ! "$confirm_vars" =~ ^[Yy]$ ]]; then
    echo "스크립트를 종료합니다. 변수 설정을 다시 해주세요."
    exit 1
fi
log_step "사용자 입력 변수 설정" "SUCCESS"
log_step "사용자 입력 변수 설정" "END"

# 3. 로컬 Yum 리포지토리 설정
log_step "로컬 Yum 리포지토리 설정" "START"
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
    log_step "로컬 Yum 리포지토리 설정" "FAILURE" "파일 쓰기 실패"
fi
log_step "로컬 Yum 리포지토리 설정" "SUCCESS"
log_step "로컬 Yum 리포지토리 설정" "END"

# 4. Yum 캐시 정리 및 리포지토리 확인
log_step "Yum 캐시 정리 및 리포지토리 확인" "START"
if ! sudo yum clean all; then
    log_step "Yum 캐시 정리" "FAILURE" "$?"
fi
if ! sudo yum repolist; then
    log_step "Yum 리포지토리 목록 확인" "FAILURE" "$?"
fi
log_step "Yum 캐시 정리 및 리포지토리 확인" "SUCCESS"
log_step "Yum 캐시 정리 및 리포지토리 확인" "END"

# 5. Firewalld 중지 및 비활성화
log_step "Firewalld 중지 및 비활성화" "START"
# Firewalld가 실행 중인지 확인하고 중지
if systemctl is-active firewalld &>/dev/null; then
    echo "Firewalld를 중지합니다..."
    if ! sudo systemctl stop firewalld; then
        log_step "Firewalld 중지" "FAILURE" "$?"
    fi
fi
# Firewalld가 활성화되어 있는지 확인하고 비활성화
if systemctl is-enabled firewalld &>/dev/null; then
    echo "Firewalld를 비활성화합니다..."
    if ! sudo systemctl disable firewalld; then
        log_step "Firewalld 비활성화" "FAILURE" "$?"
    fi
fi
log_step "Firewalld 중지 및 비활성화" "SUCCESS"
log_step "Firewalld 중지 및 비활성화" "END"

# 6. SELinux 비활성화
log_step "SELinux 비활성화" "START"
echo "SELINUX=enforcing을 SELINUX=disabled로 변경합니다..."
if ! sudo sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config; then
    log_step "SELinux 설정 변경" "FAILURE" "$?"
fi
# 변경 사항 확인
if ! grep -q "SELINUX=disabled" /etc/selinux/config; then
    log_step "SELinux 설정 확인" "FAILURE" "SELINUX=disabled 설정이 /etc/selinux/config에 적용되지 않았습니다."
fi
# 현재 SELinux 모드를 permissive로 변경 (재부팅 없이 즉시 적용)
if command -v setenforce &>/dev/null; then
    sudo setenforce 0 2>/dev/null || true
fi
echo "SELinux 변경 사항을 완전히 적용하려면 재부팅이 필요합니다."
log_step "SELinux 비활성화" "SUCCESS"
log_step "SELinux 비활성화" "END"

# 7. 호스트 이름 설정
log_step "호스트 이름 설정" "START"
echo "호스트 이름을 '$NODE_HOSTNAME'으로 설정합니다..."
if ! sudo hostnamectl set-hostname "$NODE_HOSTNAME"; then
    log_step "호스트 이름 설정" "FAILURE" "$?"
fi
# 설정 확인
current_hostname=$(hostname)
if [ "$current_hostname" != "$NODE_HOSTNAME" ]; then
    echo "경고: 호스트 이름이 즉시 반영되지 않았습니다. 재부팅 후 적용됩니다."
fi
log_step "호스트 이름 설정" "SUCCESS"
log_step "호스트 이름 설정" "END"

# 8. /etc/hosts 파일에 엔트리 추가
log_step "/etc/hosts 파일에 엔트리 추가" "START"
echo "/etc/hosts 파일에 노드 IP 및 호스트 이름 엔트리를 추가합니다..."

# 기존 k8s 관련 엔트리 제거 (중복 방지)
sudo sed -i '/k8s-master/d' /etc/hosts
sudo sed -i '/k8s-worker/d' /etc/hosts

# 새 엔트리 추가
if [[ "$NODE_TYPE" == "master" ]]; then
    # 마스터 노드 엔트리 추가
    if ! echo "$NODE_IP $NODE_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null; then
        log_step "/etc/hosts 파일에 엔트리 추가" "FAILURE" "마스터 노드 엔트리 추가 실패"
    fi
    # 워커 노드 엔트리들 추가
    if [[ "$has_workers" =~ ^[Yy]$ ]]; then
        for ((i=0; i<${#WORKER_IPS[@]}; i++)); do
            if ! echo "${WORKER_IPS[$i]} ${WORKER_HOSTNAMES[$i]}" | sudo tee -a /etc/hosts > /dev/null; then
                log_step "/etc/hosts 파일에 엔트리 추가" "FAILURE" "워커 노드 ${WORKER_HOSTNAMES[$i]} 엔트리 추가 실패"
            fi
        done
    fi
elif [[ "$NODE_TYPE" == "worker" ]]; then
    # 마스터 노드 엔트리 추가
    if ! echo "$MASTER_IP $MASTER_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null; then
        log_step "/etc/hosts 파일에 엔트리 추가" "FAILURE" "마스터 노드 엔트리 추가 실패"
    fi
    # 워커 노드 자신의 엔트리 추가
    if ! echo "$NODE_IP $NODE_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null; then
        log_step "/etc/hosts 파일에 엔트리 추가" "FAILURE" "워커 노드 엔트리 추가 실패"
    fi
fi

# 추가된 엔트리 확인
echo "현재 /etc/hosts 파일의 k8s 관련 엔트리:"
grep "k8s-" /etc/hosts
log_step "/etc/hosts 파일에 엔트리 추가" "SUCCESS"
log_step "/etc/hosts 파일에 엔트리 추가" "END"

# 9. 네트워크 연결 DNS 설정
log_step "네트워크 연결 DNS 설정" "START"
echo "네트워크 연결 '$CON_NAME'의 DNS를 $DNS_SERVER로 설정합니다..."
# nmcli con show "$CON_NAME"이 성공하는지 확인 (연결 이름 유효성 검사)
if ! nmcli con show "$CON_NAME" > /dev/null 2>&1; then
    log_step "네트워크 연결 DNS 설정" "FAILURE" "네트워크 연결 '$CON_NAME'을 찾을 수 없습니다."
fi
if ! sudo nmcli con mod "$CON_NAME" ipv4.dns "$DNS_SERVER"; then
    log_step "네트워크 연결 DNS 설정" "FAILURE" "$?"
fi
# 연결 재시작
echo "네트워크 연결을 재시작합니다..."
if ! sudo nmcli con up "$CON_NAME"; then
    log_step "네트워크 연결 재시작" "FAILURE" "$?"
fi
# DNS 설정 확인
if ! nmcli -g IP4.DNS dev show | grep -q "$DNS_SERVER"; then
    echo "경고: DNS가 즉시 반영되지 않았을 수 있습니다."
fi
log_step "네트워크 연결 DNS 설정" "SUCCESS"
log_step "네트워크 연결 DNS 설정" "END"

# 10. Chronyd 상태 확인
log_step "Chronyd 상태 확인" "START"
echo "Chronyd 서비스 상태를 확인합니다..."
if systemctl is-active chronyd &>/dev/null; then
    echo "Chronyd가 실행 중입니다."
    if ! chronyc tracking > /dev/null; then
        echo "경고: Chronyd 추적 상태를 확인할 수 없습니다."
    fi
    if ! chronyc sources > /dev/null; then
        echo "경고: Chronyd 소스를 확인할 수 없습니다."
    fi
else
    echo "경고: Chronyd가 실행되고 있지 않습니다. 시간 동기화를 확인하세요."
fi
log_step "Chronyd 상태 확인" "SUCCESS"
log_step "Chronyd 상태 확인" "END"

# 11. Swap 비활성화
log_step "Swap 비활성화" "START"
echo "Swap을 비활성화하고 /etc/fstab에서 주석 처리합니다..."
# 현재 활성화된 swap 확인 및 비활성화
if swapon --show | grep -q "swap"; then
    echo "활성화된 Swap을 비활성화합니다..."
    if ! sudo swapoff -a; then
        log_step "Swap 비활성화" "FAILURE" "$?"
    fi
fi
# /etc/fstab에서 swap 라인 주석 처리
if grep -q "^[^#].*swap" /etc/fstab; then
    echo "/etc/fstab에서 swap 라인을 주석 처리합니다..."
    if ! sudo sed -i '/ swap / s/^/#/' /etc/fstab; then
        log_step "Swap 비활성화" "FAILURE" "/etc/fstab 파일 수정 실패"
    fi
fi
# Swap이 비활성화되었는지 확인
if swapon --show | grep -q "swap"; then
    log_step "Swap 비활성화" "FAILURE" "Swap이 여전히 활성화되어 있습니다."
fi
log_step "Swap 비활성화" "SUCCESS"
log_step "Swap 비활성화" "END"

# 12. 기존 Docker/Podman 설치 제거
log_step "기존 Docker/Podman 설치 제거" "START"
echo "기존 Docker, Podman 및 관련 패키지를 제거합니다..."
# 설치되어 있지 않은 패키지가 있어도 에러 무시
sudo dnf remove -y docker \
    docker-client \
    docker-client-latest \
    docker-common \
    docker-latest \
    docker-latest-logrotate \
    docker-logrotate \
    docker-engine \
    podman \
    runc 2>/dev/null || true
log_step "기존 Docker/Podman 설치 제거" "SUCCESS"
log_step "기존 Docker/Podman 설치 제거" "END"

# 13. Docker/Containerd 패키지 다운로드
log_step "Docker/Containerd 패키지 다운로드" "START"
DOCKER_PACKAGES=(
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/containerd.io-1.7.27-3.1.el9.x86_64.rpm"
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-buildx-plugin-0.23.0-1.el9.x86_64.rpm"
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-28.1.1-1.el9.x86_64.rpm"
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-cli-28.1.1-1.el9.x86_64.rpm"
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-rootless-extras-28.1.1-1.el9.x86_64.rpm"
    "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-compose-plugin-2.35.1-1.el9.x86_64.rpm"
)

# 다운로드 디렉토리 생성 및 이동
mkdir -p /tmp/docker_rpms
cd /tmp/docker_rpms || log_step "Docker/Containerd 패키지 다운로드" "FAILURE" "디렉토리 변경 실패: /tmp/docker_rpms"

# 기존 RPM 파일 제거
rm -f *.rpm 2>/dev/null

echo "Docker 및 Containerd 패키지를 다운로드합니다..."
for url in "${DOCKER_PACKAGES[@]}"; do
    filename=$(basename "$url")
    echo "  - $filename 다운로드 중..."
    if ! curl -fsSLO "$url"; then
        log_step "Docker/Containerd 패키지 다운로드" "FAILURE" "파일 다운로드 실패: $url"
    fi
done
log_step "Docker/Containerd 패키지 다운로드" "SUCCESS"
log_step "Docker/Containerd 패키지 다운로드" "END"

# 14. Docker/Containerd 패키지 설치
log_step "Docker/Containerd 패키지 설치" "START"
echo "다운로드된 RPM 패키지를 설치합니다..."
if ! sudo yum localinstall -y *.rpm; then
    log_step "Docker/Containerd 패키지 설치" "FAILURE" "$?"
fi
log_step "Docker/Containerd 패키지 설치" "SUCCESS"
log_step "Docker/Containerd 패키지 설치" "END"

# 15. Docker 및 Containerd 시작 및 활성화
log_step "Docker 및 Containerd 시작 및 활성화" "START"
for service in docker containerd; do
    echo "  - $service 서비스 시작 및 활성화 중..."
    if ! sudo systemctl start "$service"; then
        log_step "$service 시작" "FAILURE" "$?"
    fi
    if ! sudo systemctl enable "$service"; then
        log_step "$service 활성화" "FAILURE" "$?"
    fi
    # 서비스 활성화 및 실행 상태 확인
    if ! systemctl is-enabled "$service" &>/dev/null; then
        log_step "$service 활성화 확인" "FAILURE" "$service가 활성화되지 않았습니다."
    fi
    if ! systemctl is-active "$service" &>/dev/null; then
        log_step "$service 상태 확인" "FAILURE" "$service가 실행 중이 아닙니다."
    fi
done
log_step "Docker 및 Containerd 시작 및 활성화" "SUCCESS"
log_step "Docker 및 Containerd 시작 및 활성화" "END"

# 16. Containerd SystemdCgroup 설정
log_step "Containerd SystemdCgroup 설정" "START"
echo "Containerd 기본 설정을 생성하고 SystemdCgroup을 true로 변경합니다..."
if ! sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null; then
    log_step "Containerd 기본 설정 생성" "FAILURE" "$?"
fi
if ! sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml; then
    log_step "Containerd SystemdCgroup 설정 변경" "FAILURE" "$?"
fi
# 변경 사항 확인
if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
    log_step "Containerd SystemdCgroup 설정 확인" "FAILURE" "SystemdCgroup이 true로 설정되지 않았습니다."
fi
echo "Containerd 서비스를 재시작합니다..."
if ! sudo systemctl restart containerd; then
    log_step "Containerd 재시작" "FAILURE" "$?"
fi
log_step "Containerd SystemdCgroup 설정" "SUCCESS"
log_step "Containerd SystemdCgroup 설정" "END"

# 17. 커널 모듈 로드
log_step "커널 모듈 로드" "START"
echo "overlay 및 br_netfilter 모듈을 로드하도록 설정합니다..."
if ! sudo tee /etc/modules-load.d/containerd.conf > /dev/null <<EOF
overlay
br_netfilter
EOF
then
    log_step "커널 모듈 설정 파일 생성" "FAILURE" "파일 쓰기 실패"
fi
echo "모듈을 즉시 로드합니다..."
if ! sudo modprobe overlay; then
    log_step "overlay 모듈 로드" "FAILURE" "$?"
fi
if ! sudo modprobe br_netfilter; then
    log_step "br_netfilter 모듈 로드" "FAILURE" "$?"
fi
# 모듈 로드 확인
if ! lsmod | grep -q "overlay"; then
    log_step "overlay 모듈 확인" "FAILURE" "overlay 모듈이 로드되지 않았습니다."
fi
if ! lsmod | grep -q "br_netfilter"; then
    log_step "br_netfilter 모듈 확인" "FAILURE" "br_netfilter 모듈이 로드되지 않았습니다."
fi
log_step "커널 모듈 로드" "SUCCESS"
log_step "커널 모듈 로드" "END"

# 18. 쿠버네티스 Sysctl 파라미터 설정
log_step "쿠버네티스 Sysctl 파라미터 설정" "START"
echo "쿠버네티스에 필요한 Sysctl 파라미터를 설정합니다..."
if ! sudo tee /etc/sysctl.d/k8s.conf > /dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
then
    log_step "Sysctl 설정 파일 생성" "FAILURE" "파일 쓰기 실패"
fi
echo "Sysctl 설정을 적용합니다..."
if ! sudo sysctl --system > /dev/null; then
    log_step "Sysctl 설정 적용" "FAILURE" "$?"
fi
# IP 포워딩 즉시 활성화
echo '1' | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
# IP 포워딩 확인
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -ne "1" ]; then
    log_step "IP 포워딩 확인" "FAILURE" "IP 포워딩이 활성화되지 않았습니다."
fi
log_step "쿠버네티스 Sysctl 파라미터 설정" "SUCCESS"
log_step "쿠버네티스 Sysctl 파라미터 설정" "END"

# 19. 쿠버네티스 Yum 리포지토리 추가
log_step "쿠버네티스 Yum 리포지토리 추가" "START"
echo "쿠버네티스 Yum 리포지토리를 추가합니다..."
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
    log_step "쿠버네티스 리포지토리 설정 파일 생성" "FAILURE" "파일 쓰기 실패"
fi
# 리포지토리 추가 확인
if ! sudo yum repolist | grep -q "kubernetes"; then
    log_step "쿠버네티스 리포지토리 확인" "FAILURE" "쿠버네티스 리포지토리가 추가되지 않았습니다."
fi
log_step "쿠버네티스 Yum 리포지토리 추가" "SUCCESS"
log_step "쿠버네티스 Yum 리포지토리 추가" "END"

# 20. Kubelet, Kubeadm, Kubectl 설치
log_step "Kubelet, Kubeadm, Kubectl 설치" "START"
echo "kubelet, kubeadm, kubectl 패키지를 설치합니다..."
if ! sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes; then
    log_step "Kubelet, Kubeadm, Kubectl 설치" "FAILURE" "$?"
fi
# 설치 확인
for cmd in kubelet kubeadm kubectl; do
    if ! command -v $cmd &>/dev/null; then
        log_step "Kubelet, Kubeadm, Kubectl 설치" "FAILURE" "$cmd 명령을 찾을 수 없습니다."
    fi
done
log_step "Kubelet, Kubeadm, Kubectl 설치" "SUCCESS"
log_step "Kubelet, Kubeadm, Kubectl 설치" "END"

# 21. Kubelet 시작 및 활성화
log_step "Kubelet 시작 및 활성화" "START"
echo "Kubelet 서비스를 활성화합니다..."
# Kubelet은 kubeadm init/join 전까지는 시작되지 않으므로 enable만 수행
if ! sudo systemctl enable kubelet; then
    log_step "Kubelet 활성화" "FAILURE" "$?"
fi
# Kubelet 활성화 확인
if ! systemctl is-enabled kubelet &>/dev/null; then
    log_step "Kubelet 활성화 확인" "FAILURE" "Kubelet이 활성화되지 않았습니다."
fi
echo "참고: Kubelet은 kubeadm init/join 명령 실행 후 시작됩니다."
log_step "Kubelet 시작 및 활성화" "SUCCESS"
log_step "Kubelet 시작 및 활성화" "END"

# 22. 설치 완료 및 다음 단계 안내
echo ""
echo "**************************************************"
echo "  모든 쿠버네티스 노드 환경 구성이 완료되었습니다!  "
echo "**************************************************"
echo ""
echo "중요: SELinux 변경 사항을 완전히 적용하려면 시스템을 재부팅해야 합니다."
echo ""
echo "다음 단계:"
echo "1. 시스템을 재부팅하세요:"
echo "   sudo reboot"
echo ""
if [[ "$NODE_TYPE" == "master" ]]; then
    echo "2. 재부팅 후 마스터 노드를 초기화하세요:"
    echo "   sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$NODE_IP"
    echo ""
    echo "3. 초기화 완료 후 kubectl 설정:"
    echo "   mkdir -p \$HOME/.kube"
    echo "   sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
    echo "   sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
    echo ""
    echo "4. CNI 플러그인 설치 (예: Flannel):"
    echo "   kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
    echo ""
    echo "5. 초기화 과정에서 출력되는 'kubeadm join' 명령을 워커 노드에서 실행하세요."
elif [[ "$NODE_TYPE" == "worker" ]]; then
    echo "2. 재부팅 후 마스터 노드에서 제공받은 'kubeadm join' 명령을 실행하세요."
    echo "   예시:"
    echo "   sudo kubeadm join $MASTER_IP:6443 --token <token> --discovery-token-ca-cert-hash <hash>"
fi
echo ""
echo "문제 해결 팁:"
echo "- 로그 확인: journalctl -xeu kubelet"
echo "- 노드 상태 확인: kubectl get nodes (마스터 노드에서)"
echo "- 파드 상태 확인: kubectl get pods --all-namespaces (마스터 노드에서)"
echo ""

# 임시 파일 정리
rm -rf /tmp/docker_rpms 2>/dev/null

log_step "스크립트 실행 완료" "SUCCESS"