#!/bin/bash

# 체크포인트 파일 경로
CHECKPOINT_FILE="/var/tmp/k8s-setup-checkpoint"
VARS_FILE="/var/tmp/k8s-setup-vars"

# 로그를 출력하는 함수
log_step() {
    local step_name=$1
    local status=$2
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
            echo ""
            echo "실패한 단계: $CURRENT_STEP"
            echo "다음 실행 시 이 단계부터 다시 시작됩니다."
            save_checkpoint
            exit 1
            ;;
    esac
}

# 체크포인트 저장
save_checkpoint() {
    echo "$CURRENT_STEP" > "$CHECKPOINT_FILE"
    # 중요 변수들도 저장
    cat > "$VARS_FILE" <<EOF
NODE_IP="$NODE_IP"
NODE_HOSTNAME="$NODE_HOSTNAME"
NODE_TYPE="$NODE_TYPE"
CON_NAME="$CON_NAME"
DNS_SERVER="$DNS_SERVER"
MASTER_IP="$MASTER_IP"
MASTER_HOSTNAME="$MASTER_HOSTNAME"
WORKER_IPS=(${WORKER_IPS[@]})
WORKER_HOSTNAMES=(${WORKER_HOSTNAMES[@]})
EOF
}

# 체크포인트 로드
load_checkpoint() {
    if [ -f "$CHECKPOINT_FILE" ]; then
        LAST_STEP=$(cat "$CHECKPOINT_FILE")
        echo "이전 실행이 $LAST_STEP 단계에서 중단되었습니다."
        
        if [ -f "$VARS_FILE" ]; then
            source "$VARS_FILE"
            echo "이전 설정값을 불러왔습니다."
            echo "  - 노드 종류: $NODE_TYPE"
            echo "  - 노드 IP: $NODE_IP"
            echo "  - 노드 호스트명: $NODE_HOSTNAME"
            echo ""
            read -p "이전 설정을 사용하여 $LAST_STEP 단계부터 계속하시겠습니까? (y/n): " continue_choice
            if [[ "$continue_choice" =~ ^[Yy]$ ]]; then
                return 0
            fi
        fi
    fi
    return 1
}

# 체크포인트 초기화
clear_checkpoint() {
    rm -f "$CHECKPOINT_FILE" "$VARS_FILE"
}

# 단계 실행 함수
execute_step() {
    local step_number=$1
    local step_name=$2
    local step_function=$3
    
    CURRENT_STEP=$step_number
    
    # 이전 체크포인트보다 이전 단계는 건너뛰기
    if [ -n "$LAST_STEP" ] && [ "$step_number" -lt "$LAST_STEP" ]; then
        echo "[$step_number] $step_name - 건너뛰기 (이미 완료됨)"
        return
    fi
    
    log_step "$step_name" "START"
    $step_function
    log_step "$step_name" "SUCCESS"
    log_step "$step_name" "END"
    
    # 체크포인트 업데이트
    save_checkpoint
}

# 각 단계를 함수로 정의
step_01_system_info() {
    # OS 버전 확인
    OS_VERSION=$(cat /etc/redhat-release 2>/dev/null || lsb_release -ds 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '"')
    if [ -z "$OS_VERSION" ]; then
        OS_VERSION="알 수 없음"
    fi

    echo "현재 OS 버전: $OS_VERSION"
    echo ""
    
    # 네트워크 인터페이스 정보 표시
    echo "네트워크 인터페이스 목록 및 IP 정보:"
    nmcli dev show | grep "GENERAL.DEVICE:" | awk '{print $2}' | while read -r device; do
        echo "  - 디바이스: $device"
        device_type=$(nmcli -g GENERAL.TYPE dev show "$device" 2>/dev/null)
        device_state=$(nmcli -g GENERAL.STATE dev show "$device" 2>/dev/null)
        device_ip=$(nmcli -g IP4.ADDRESS dev show "$device" 2>/dev/null)
        echo "    타입: $device_type"
        echo "    상태: $device_state"
        echo "    IP 주소: ${device_ip:-없음}"
        echo ""
    done

    read -p "위 정보가 올바른가요? (y/n): " confirm_info
    if [[ ! "$confirm_info" =~ ^[Yy]$ ]]; then
        log_step "시스템 정보 확인" "FAILURE" "사용자가 시스템 정보를 확인하지 않았습니다."
    fi
}

step_02_user_input() {
    # 체크포인트에서 복원된 경우 이미 변수가 있으므로 건너뛰기
    if [ -n "$NODE_IP" ] && [ -n "$NODE_HOSTNAME" ]; then
        echo "체크포인트에서 복원된 설정을 사용합니다."
        return
    fi
    
    # 노드 종류 선택
    echo "노드 종류를 선택하세요:"
    echo "1) Master Node"
    echo "2) Worker Node"
    read -p "선택 (1 or 2): " node_type_choice

    if [ "$node_type_choice" == "1" ]; then
        NODE_TYPE="master"
    else
        NODE_TYPE="worker"
    fi

    # 기본 정보 입력
    read -p "이 노드의 IP 주소를 입력하세요 (예: 192.168.0.100): " NODE_IP
    read -p "이 노드의 호스트 이름을 입력하세요: " NODE_HOSTNAME

    # 네트워크 인터페이스 선택
    echo ""
    echo "사용 가능한 네트워크 연결:"
    nmcli con show | grep -v "NAME" | nl -nrz -w2
    read -p "네트워크 연결 번호를 선택하세요: " interface_num
    CON_NAME=$(nmcli con show | grep -v "NAME" | sed -n "${interface_num}p" | awk '{print $1}')

    # DNS 서버
    read -p "DNS 서버 주소를 입력하세요 (기본값: 8.8.8.8): " DNS_SERVER
    DNS_SERVER=${DNS_SERVER:-8.8.8.8}

    # 노드별 추가 정보
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

    # 설정 확인
    echo ""
    echo "입력하신 정보 확인:"
    echo "  - 노드 종류: $NODE_TYPE"
    echo "  - 이 노드 IP: $NODE_IP"
    echo "  - 이 노드 호스트 이름: $NODE_HOSTNAME"
    echo ""
    
    read -p "위 정보가 맞습니까? (y/n): " confirm_vars
    if [[ ! "$confirm_vars" =~ ^[Yy]$ ]]; then
        log_step "사용자 입력 변수 설정" "FAILURE" "사용자가 입력 정보를 확인하지 않았습니다."
    fi
}

step_03_local_repo() {
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
}

step_04_yum_clean() {
    if ! sudo yum clean all; then
        log_step "Yum 캐시 정리" "FAILURE" "$?"
    fi
    if ! sudo yum repolist; then
        log_step "Yum 리포지토리 목록 확인" "FAILURE" "$?"
    fi
}

step_05_disable_firewall() {
    if systemctl is-active firewalld &>/dev/null; then
        echo "Firewalld를 중지합니다..."
        if ! sudo systemctl stop firewalld; then
            log_step "Firewalld 중지" "FAILURE" "$?"
        fi
    fi
    if systemctl is-enabled firewalld &>/dev/null; then
        echo "Firewalld를 비활성화합니다..."
        if ! sudo systemctl disable firewalld; then
            log_step "Firewalld 비활성화" "FAILURE" "$?"
        fi
    fi
}

step_06_disable_selinux() {
    echo "SELinux를 비활성화합니다..."
    if ! sudo sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config; then
        log_step "SELinux 설정 변경" "FAILURE" "$?"
    fi
    if ! grep -q "SELINUX=disabled" /etc/selinux/config; then
        log_step "SELinux 설정 확인" "FAILURE" "SELinux 설정이 적용되지 않았습니다."
    fi
    if command -v setenforce &>/dev/null; then
        sudo setenforce 0 2>/dev/null || true
    fi
}

step_07_set_hostname() {
    echo "호스트 이름을 '$NODE_HOSTNAME'으로 설정합니다..."
    if ! sudo hostnamectl set-hostname "$NODE_HOSTNAME"; then
        log_step "호스트 이름 설정" "FAILURE" "$?"
    fi
}

step_08_update_hosts() {
    echo "/etc/hosts 파일을 업데이트합니다..."
    
    # 기존 k8s 관련 엔트리 제거
    sudo sed -i '/k8s-master/d' /etc/hosts
    sudo sed -i '/k8s-worker/d' /etc/hosts
    
    # 새 엔트리 추가
    if [[ "$NODE_TYPE" == "master" ]]; then
        if ! echo "$NODE_IP $NODE_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null; then
            log_step "/etc/hosts 업데이트" "FAILURE" "마스터 노드 엔트리 추가 실패"
        fi
        if [ ${#WORKER_IPS[@]} -gt 0 ]; then
            for ((i=0; i<${#WORKER_IPS[@]}; i++)); do
                if ! echo "${WORKER_IPS[$i]} ${WORKER_HOSTNAMES[$i]}" | sudo tee -a /etc/hosts > /dev/null; then
                    log_step "/etc/hosts 업데이트" "FAILURE" "워커 노드 엔트리 추가 실패"
                fi
            done
        fi
    elif [[ "$NODE_TYPE" == "worker" ]]; then
        if ! echo "$MASTER_IP $MASTER_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null; then
            log_step "/etc/hosts 업데이트" "FAILURE" "마스터 노드 엔트리 추가 실패"
        fi
        if ! echo "$NODE_IP $NODE_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null; then
            log_step "/etc/hosts 업데이트" "FAILURE" "워커 노드 엔트리 추가 실패"
        fi
    fi
}

step_09_configure_dns() {
    echo "DNS를 $DNS_SERVER로 설정합니다..."
    if ! nmcli con show "$CON_NAME" > /dev/null 2>&1; then
        log_step "네트워크 DNS 설정" "FAILURE" "네트워크 연결 '$CON_NAME'을 찾을 수 없습니다."
    fi
    if ! sudo nmcli con mod "$CON_NAME" ipv4.dns "$DNS_SERVER"; then
        log_step "네트워크 DNS 설정" "FAILURE" "$?"
    fi
    if ! sudo nmcli con up "$CON_NAME"; then
        log_step "네트워크 재시작" "FAILURE" "$?"
    fi
}

step_10_check_chronyd() {
    echo "Chronyd 서비스를 확인합니다..."
    if systemctl is-active chronyd &>/dev/null; then
        echo "Chronyd가 실행 중입니다."
    else
        echo "경고: Chronyd가 실행되고 있지 않습니다."
    fi
}

step_11_disable_swap() {
    echo "Swap을 비활성화합니다..."
    if swapon --show | grep -q "swap"; then
        if ! sudo swapoff -a; then
            log_step "Swap 비활성화" "FAILURE" "$?"
        fi
    fi
    if grep -q "^[^#].*swap" /etc/fstab; then
        if ! sudo sed -i '/ swap / s/^/#/' /etc/fstab; then
            log_step "Swap 비활성화" "FAILURE" "/etc/fstab 수정 실패"
        fi
    fi
}

step_12_remove_old_docker() {
    echo "기존 Docker/Podman을 제거합니다..."
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
}

step_13_download_docker() {
    echo "Docker 패키지를 다운로드합니다..."
    DOCKER_PACKAGES=(
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/containerd.io-1.7.27-3.1.el9.x86_64.rpm"
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-buildx-plugin-0.23.0-1.el9.x86_64.rpm"
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-28.1.1-1.el9.x86_64.rpm"
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-cli-28.1.1-1.el9.x86_64.rpm"
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-rootless-extras-28.1.1-1.el9.x86_64.rpm"
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-compose-plugin-2.35.1-1.el9.x86_64.rpm"
    )
    
    mkdir -p /tmp/docker_rpms
    cd /tmp/docker_rpms || log_step "Docker 다운로드" "FAILURE" "디렉토리 변경 실패"
    
    for url in "${DOCKER_PACKAGES[@]}"; do
        filename=$(basename "$url")
        if [ ! -f "$filename" ]; then
            echo "  - $filename 다운로드 중..."
            if ! curl -fsSLO "$url"; then
                log_step "Docker 다운로드" "FAILURE" "파일 다운로드 실패: $url"
            fi
        else
            echo "  - $filename 이미 존재 (건너뛰기)"
        fi
    done
}

step_14_install_docker() {
    echo "Docker 패키지를 설치합니다..."
    cd /tmp/docker_rpms || log_step "Docker 설치" "FAILURE" "디렉토리 변경 실패"
    if ! sudo yum localinstall -y *.rpm; then
        log_step "Docker 설치" "FAILURE" "$?"
    fi
}

step_15_start_docker() {
    for service in docker containerd; do
        echo "  - $service 서비스 시작 및 활성화..."
        if ! sudo systemctl start "$service"; then
            log_step "$service 시작" "FAILURE" "$?"
        fi
        if ! sudo systemctl enable "$service"; then
            log_step "$service 활성화" "FAILURE" "$?"
        fi
    done
}

step_16_configure_containerd() {
    echo "Containerd를 설정합니다..."
    if ! sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null; then
        log_step "Containerd 설정" "FAILURE" "기본 설정 생성 실패"
    fi
    if ! sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml; then
        log_step "Containerd 설정" "FAILURE" "SystemdCgroup 설정 실패"
    fi
    if ! sudo systemctl restart containerd; then
        log_step "Containerd 재시작" "FAILURE" "$?"
    fi
}

step_17_load_modules() {
    echo "커널 모듈을 로드합니다..."
    if ! sudo tee /etc/modules-load.d/containerd.conf > /dev/null <<EOF
overlay
br_netfilter
EOF
    then
        log_step "커널 모듈 설정" "FAILURE" "파일 쓰기 실패"
    fi
    
    if ! sudo modprobe overlay; then
        log_step "overlay 모듈 로드" "FAILURE" "$?"
    fi
    if ! sudo modprobe br_netfilter; then
        log_step "br_netfilter 모듈 로드" "FAILURE" "$?"
    fi
}

step_18_configure_sysctl() {
    echo "Sysctl 파라미터를 설정합니다..."
    if ! sudo tee /etc/sysctl.d/k8s.conf > /dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    then
        log_step "Sysctl 설정" "FAILURE" "파일 쓰기 실패"
    fi
    
    if ! sudo sysctl --system > /dev/null; then
        log_step "Sysctl 적용" "FAILURE" "$?"
    fi
    
    echo '1' | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
}

step_19_add_k8s_repo() {
    echo "Kubernetes 리포지토리를 추가합니다..."
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
        log_step "Kubernetes 리포지토리 추가" "FAILURE" "파일 쓰기 실패"
    fi
}

step_20_install_k8s() {
    echo "Kubernetes 구성요소를 설치합니다..."
    if ! sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes; then
        log_step "Kubernetes 설치" "FAILURE" "$?"
    fi
}

step_21_enable_kubelet() {
    echo "Kubelet을 활성화합니다..."
    if ! sudo systemctl enable kubelet; then
        log_step "Kubelet 활성화" "FAILURE" "$?"
    fi
}

# 메인 실행부
echo "**************************************************"
echo "  쿠버네티스 노드 환경 구성 스크립트 v2.0        "
echo "        (체크포인트 기능 포함)                    "
echo "**************************************************"
echo ""

# 체크포인트 확인
if load_checkpoint; then
    echo "체크포인트에서 복원하여 계속 진행합니다..."
    START_FROM=$LAST_STEP
else
    echo "새로운 설치를 시작합니다..."
    START_FROM=1
    clear_checkpoint
fi

# 단계별 실행
execute_step 1 "시스템 정보 확인" step_01_system_info
execute_step 2 "사용자 입력 변수 설정" step_02_user_input
execute_step 3 "로컬 Yum 리포지토리 설정" step_03_local_repo
execute_step 4 "Yum 캐시 정리 및 리포지토리 확인" step_04_yum_clean
execute_step 5 "Firewalld 중지 및 비활성화" step_05_disable_firewall
execute_step 6 "SELinux 비활성화" step_06_disable_selinux
execute_step 7 "호스트 이름 설정" step_07_set_hostname
execute_step 8 "/etc/hosts 파일 업데이트" step_08_update_hosts
execute_step 9 "네트워크 DNS 설정" step_09_configure_dns
execute_step 10 "Chronyd 상태 확인" step_10_check_chronyd
execute_step 11 "Swap 비활성화" step_11_disable_swap
execute_step 12 "기존 Docker/Podman 제거" step_12_remove_old_docker
execute_step 13 "Docker 패키지 다운로드" step_13_download_docker
execute_step 14 "Docker 패키지 설치" step_14_install_docker
execute_step 15 "Docker 및 Containerd 시작" step_15_start_docker
execute_step 16 "Containerd 설정" step_16_configure_containerd
execute_step 17 "커널 모듈 로드" step_17_load_modules
execute_step 18 "Sysctl 파라미터 설정" step_18_configure_sysctl
execute_step 19 "Kubernetes 리포지토리 추가" step_19_add_k8s_repo
execute_step 20 "Kubernetes 구성요소 설치" step_20_install_k8s
execute_step 21 "Kubelet 활성화" step_21_enable_kubelet

# 모든 단계 완료 - 체크포인트 삭제
clear_checkpoint

echo ""
echo "**************************************************"
echo "  모든 쿠버네티스 노드 환경 구성이 완료되었습니다!  "
echo "**************************************************"
echo ""
echo "중요: SELinux 변경 사항을 완전히 적용하려면 시스템을 재부팅해야 합니다."
echo ""
echo "다음 단계:"
echo "1. 시스템을 재부팅하세요: sudo reboot"
echo ""
if [[ "$NODE_TYPE" == "master" ]]; then
    echo "2. 재부팅 후 마스터 노드를 초기화하세요:"
    echo "   sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$NODE_IP"
    echo ""
    echo "3. kubectl 설정:"
    echo "   mkdir -p \$HOME/.kube"
    echo "   sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
    echo "   sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
elif [[ "$NODE_TYPE" == "worker" ]]; then
    echo "2. 마스터 노드에서 제공받은 'kubeadm join' 명령을 실행하세요."
fi

# 임시 파일 정리
rm -rf /tmp/docker_rpms 2>/dev/null

echo ""
echo "설치가 완료되었습니다!"