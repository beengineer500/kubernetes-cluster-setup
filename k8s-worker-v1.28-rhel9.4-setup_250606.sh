#!/bin/bash

#==============================================================================
# Kubernetes Worker Node Setup Script
# Description: 쿠버네티스 워커 노드 환경을 자동으로 구성하는 스크립트
# Author: DevOps Engineer
# Version: 1.0
#==============================================================================

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 상태 파일 경로
STATE_FILE="/var/log/k8s-worker-setup.state"
LOG_FILE="/var/log/k8s-worker-setup.log"

# 로그 함수
log() {
    echo -e "${1}" | tee -a "${LOG_FILE}"
}

# 성공 메시지
success() {
    log "${GREEN}[SUCCESS]${NC} $1"
}

# 실패 메시지
error() {
    log "${RED}[ERROR]${NC} $1"
}

# 정보 메시지
info() {
    log "${BLUE}[INFO]${NC} $1"
}

# 경고 메시지
warning() {
    log "${YELLOW}[WARNING]${NC} $1"
}

# 단계 시작
start_step() {
    local step_name=$1
    info "===== ${step_name} 시작 ====="
}

# 단계 완료
complete_step() {
    local step_num=$1
    local step_name=$2
    echo "${step_num}" > "${STATE_FILE}"
    success "===== ${step_name} 완료 ====="
    echo ""
}

# 시스템 정보 확인
check_system_info() {
    echo ""
    info "========== 시스템 정보 확인 =========="
    
    # OS 정보
    info "OS 정보:"
    cat /etc/os-release | grep -E "^(NAME|VERSION)" | sed 's/^/  /'
    
    # 하드웨어 정보
    info "하드웨어 정보:"
    echo "  CPU: $(nproc) cores"
    echo "  Memory: $(free -h | grep Mem | awk '{print $2}')"
    echo "  Disk:"
    lsblk | sed 's/^/    /'
    
    # 네트워크 정보
    info "네트워크 정보 (NetworkManager):"
    echo "  네트워크 연결:"
    nmcli con show | sed 's/^/    /'
    echo ""
    echo "  네트워크 디바이스:"
    nmcli dev status | sed 's/^/    /'
    echo ""
    echo "  IP 주소:"
    ip -4 addr show | grep inet | grep -v 127.0.0.1 | sed 's/^/    /'
    
    info "======================================"
    echo ""
}

# 작업 목차 표시
show_menu() {
    echo ""
    info "========== 작업 단계 목차 =========="
    echo "1. ISO 마운트 및 로컬 레포지토리 설정"
    echo "2. 방화벽 비활성화 및 SELinux 설정"
    echo "3. 호스트명 및 hosts 파일 설정"
    echo "4. 네트워크 DNS 설정"
    echo "5. 시간 동기화 확인"
    echo "6. Swap 비활성화"
    echo "7. 기존 컨테이너 런타임 제거"
    echo "8. Docker 및 Containerd 설치"
    echo "9. Containerd 설정"
    echo "10. 커널 모듈 및 sysctl 설정"
    echo "11. Kubernetes 패키지 설치"
    echo "12. 최종 확인 및 완료"
    info "===================================="
    echo ""
}

# 현재 상태 확인
get_current_step() {
    if [ -f "${STATE_FILE}" ]; then
        cat "${STATE_FILE}"
    else
        echo "0"
    fi
}

# Step 1: ISO 마운트 및 로컬 레포지토리 설정
step1_iso_repo() {
    start_step "ISO 마운트 및 로컬 레포지토리 설정"
    
    # ISO 디렉토리 생성
    mkdir -p /iso /mnt/cdrom || { error "디렉토리 생성 실패"; return 1; }
    
    # CD/DVD 확인
    if [ ! -b /dev/sr0 ]; then
        error "CD/DVD 디바이스를 찾을 수 없습니다 (/dev/sr0)"
        return 1
    fi
    
    # ISO 마운트
    mount /dev/sr0 /mnt/cdrom || { error "ISO 마운트 실패"; return 1; }
    
    # 파일 복사
    info "ISO 파일 복사 중... (시간이 걸릴 수 있습니다)"
    cp -rf /mnt/cdrom/* /iso/ || { error "파일 복사 실패"; umount /mnt/cdrom; return 1; }
    
    # 언마운트
    umount /mnt/cdrom || warning "언마운트 실패 (무시하고 진행)"
    
    # 로컬 레포지토리 설정
    cat <<EOF | tee /etc/yum.repos.d/local.repo
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

    # 레포지토리 정리 및 확인
    yum clean all
    yum repolist
    
    complete_step 1 "ISO 마운트 및 로컬 레포지토리 설정"
    return 0
}

# Step 2: 방화벽 및 SELinux 설정
step2_firewall_selinux() {
    start_step "방화벽 비활성화 및 SELinux 설정"
    
    # 방화벽 비활성화
    systemctl stop firewalld || warning "방화벽 정지 실패"
    systemctl disable firewalld || warning "방화벽 비활성화 실패"
    
    # SELinux 비활성화
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config || { error "SELinux 설정 변경 실패"; return 1; }
    
    # 설정 확인
    info "SELinux 설정:"
    grep "^SELINUX=" /etc/selinux/config
    
    complete_step 2 "방화벽 비활성화 및 SELinux 설정"
    return 0
}

# Step 3: 호스트명 및 hosts 설정
step3_hostname_hosts() {
    start_step "호스트명 및 hosts 파일 설정"
    
    # 호스트명 설정 (워커 노드)
    read -p "워커 노드 호스트명을 입력하세요 [k8s-worker01]: " hostname
    hostname=${hostname:-k8s-worker01}
    
    hostnamectl set-hostname "${hostname}" || { error "호스트명 설정 실패"; return 1; }
    
    # hosts 파일 설정
    # 기존 항목 확인 후 추가
    grep -q "k8s-master01" /etc/hosts || echo "192.168.35.70 k8s-master01" >> /etc/hosts
    grep -q "k8s-worker01" /etc/hosts || echo "192.168.35.75 k8s-worker01" >> /etc/hosts
    
    info "hosts 파일 내용:"
    cat /etc/hosts | grep -E "(k8s-master|k8s-worker)"
    
    complete_step 3 "호스트명 및 hosts 파일 설정"
    return 0
}

# Step 4: 네트워크 DNS 설정
step4_network_dns() {
    start_step "네트워크 DNS 설정"
    
    # 활성 연결 확인
    info "현재 네트워크 연결:"
    nmcli con show
    
    # 활성 연결 이름 가져오기
    CON_NAME=$(nmcli -t -f NAME,DEVICE con show --active | grep -v lo | head -1 | cut -d: -f1)
    
    if [ -z "$CON_NAME" ]; then
        error "활성 네트워크 연결을 찾을 수 없습니다"
        return 1
    fi
    
    info "DNS를 8.8.8.8로 설정합니다 (연결: $CON_NAME)"
    nmcli con mod "$CON_NAME" ipv4.dns 8.8.8.8 || { error "DNS 설정 실패"; return 1; }
    nmcli con up "$CON_NAME" || { error "네트워크 연결 재시작 실패"; return 1; }
    
    complete_step 4 "네트워크 DNS 설정"
    return 0
}

# Step 5: 시간 동기화 확인
step5_time_sync() {
    start_step "시간 동기화 확인"
    
    # chronyd 상태 확인
    systemctl status chronyd --no-pager
    
    if ! systemctl is-active chronyd >/dev/null 2>&1; then
        warning "chronyd가 실행 중이 아닙니다. 시작합니다."
        systemctl start chronyd
        systemctl enable chronyd
    fi
    
    # 동기화 상태 확인
    info "시간 동기화 상태:"
    chronyc tracking | grep -E "(Reference ID|System time|NTP)"
    
    complete_step 5 "시간 동기화 확인"
    return 0
}

# Step 6: Swap 비활성화
step6_disable_swap() {
    start_step "Swap 비활성화"
    
    # 현재 swap 비활성화
    swapoff -a
    
    # swap 상태 확인
    if swapon --show | grep -q .; then
        error "Swap 비활성화 실패"
        return 1
    fi
    
    # fstab에서 swap 항목 주석 처리
    sed -i '/swap/s/^/#/' /etc/fstab
    
    info "Swap 설정 확인:"
    grep swap /etc/fstab || info "fstab에 swap 항목이 없습니다"
    
    complete_step 6 "Swap 비활성화"
    return 0
}

# Step 7: 기존 컨테이너 런타임 제거
step7_remove_old_runtime() {
    start_step "기존 컨테이너 런타임 제거"
    
    # 제거할 패키지 목록
    REMOVE_PKGS="docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman runc"
    
    for pkg in $REMOVE_PKGS; do
        if rpm -q $pkg >/dev/null 2>&1; then
            info "$pkg 제거 중..."
            dnf remove -y $pkg
        fi
    done
    
    complete_step 7 "기존 컨테이너 런타임 제거"
    return 0
}

# Step 8: Docker 및 Containerd 설치
step8_install_docker() {
    start_step "Docker 및 Containerd 설치"
    
    # Docker 패키지 다운로드
    info "Docker 패키지 다운로드 중..."
    
    DOCKER_PKGS=(
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/containerd.io-1.7.27-3.1.el9.x86_64.rpm"
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-buildx-plugin-0.23.0-1.el9.x86_64.rpm"
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-28.1.1-1.el9.x86_64.rpm"
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-cli-28.1.1-1.el9.x86_64.rpm"
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-ce-rootless-extras-28.1.1-1.el9.x86_64.rpm"
        "https://download.docker.com/linux/rhel/9/x86_64/stable/Packages/docker-compose-plugin-2.35.1-1.el9.x86_64.rpm"
    )
    
    for url in "${DOCKER_PKGS[@]}"; do
        filename=$(basename "$url")
        if [ ! -f "$filename" ]; then
            curl -fsSLO "$url" || { error "다운로드 실패: $url"; return 1; }
        else
            info "$filename 이미 존재함"
        fi
    done
    
    # 패키지 설치
    info "Docker 패키지 설치 중..."
    dnf install -y ./*.rpm || { error "Docker 설치 실패"; return 1; }
    
    # Docker 서비스 시작 및 활성화
    systemctl start docker
    systemctl enable docker
    
    # Containerd 서비스 시작 및 활성화
    systemctl start containerd
    systemctl enable containerd
    
    # 서비스 상태 확인
    info "서비스 상태 확인:"
    systemctl is-enabled docker containerd
    
    complete_step 8 "Docker 및 Containerd 설치"
    return 0
}

# Step 9: Containerd 설정
step9_configure_containerd() {
    start_step "Containerd 설정"
    
    # Containerd 기본 설정 생성
    containerd config default | tee /etc/containerd/config.toml || { error "Containerd 설정 생성 실패"; return 1; }
    
    # SystemdCgroup 활성화
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # 설정 확인
    info "SystemdCgroup 설정 확인:"
    grep 'SystemdCgroup' /etc/containerd/config.toml
    
    # Containerd 재시작
    systemctl restart containerd || { error "Containerd 재시작 실패"; return 1; }
    
    complete_step 9 "Containerd 설정"
    return 0
}

# Step 10: 커널 모듈 및 sysctl 설정
step10_kernel_settings() {
    start_step "커널 모듈 및 sysctl 설정"
    
    # 필요한 커널 모듈 로드
    cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter
    
    # sysctl 파라미터 설정
    cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    # 설정 적용
    sysctl --system
    
    # 설정 확인
    info "커널 모듈 확인:"
    lsmod | grep -E "overlay|br_netfilter"
    
    complete_step 10 "커널 모듈 및 sysctl 설정"
    return 0
}

# Step 11: Kubernetes 패키지 설치
step11_install_kubernetes() {
    start_step "Kubernetes 패키지 설치"
    
    # Kubernetes 레포지토리 추가
    cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

    # kubernetes 레포지토리 확인
    cat /etc/yum.repos.d/kubernetes.repo
    yum repolist
    info "Kubernetes 레포지토리 설정 완료"
    info "Kubernetes 패키지 설치를 시작합니다..."
    echo ""

    # 패키지 설치
    yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes || { error "Kubernetes 패키지 설치 실패"; return 1; }
    
    # kubelet 활성화
    systemctl enable kubelet
    
    info "설치된 Kubernetes 버전:"
    kubectl version --client
    kubeadm version
    
    complete_step 11 "Kubernetes 패키지 설치"
    return 0
}

# Step 12: 최종 확인
step12_final_check() {
    start_step "최종 확인 및 완료"
    
    info "시스템 설정 최종 확인:"
    echo ""
    
    # 각 항목 확인
    echo "✓ 호스트명: $(hostname)"
    echo "✓ SELinux: $(getenforce)"
    echo "✓ Swap: $(swapon --show | wc -l) (0이어야 함)"
    echo "✓ Docker: $(systemctl is-active docker)"
    echo "✓ Containerd: $(systemctl is-active containerd)"
    echo "✓ Kubelet: $(systemctl is-enabled kubelet)"
    echo ""
    
    success "모든 설정이 완료되었습니다!"
    info "이제 마스터 노드에서 'kubeadm join' 명령을 실행하여 클러스터에 참여할 수 있습니다."
    
    # 상태 파일 제거 (모든 단계 완료)
    rm -f "${STATE_FILE}"
    
    complete_step 12 "최종 확인 및 완료"
    return 0
}

# 메인 함수
main() {
    clear
    echo "=================================================="
    echo "   Kubernetes Worker Node Setup Script v1.0"
    echo "=================================================="
    
    # 시스템 정보 확인
    check_system_info
    
    # 작업 목차 표시
    show_menu
    
    # 현재 진행 상태 확인
    current_step=$(get_current_step)
    
    if [ "$current_step" -gt 0 ]; then
        warning "이전에 중단된 작업이 있습니다. (마지막 완료 단계: $current_step)"
        read -p "이어서 진행하시겠습니까? (y/n) [y]: " continue_work
        continue_work=${continue_work:-y}
        
        if [[ ! "$continue_work" =~ ^[Yy]$ ]]; then
            read -p "처음부터 시작하시겠습니까? (y/n) [n]: " restart_work
            restart_work=${restart_work:-n}
            
            if [[ "$restart_work" =~ ^[Yy]$ ]]; then
                current_step=0
                rm -f "${STATE_FILE}"
            else
                info "작업을 취소합니다."
                exit 0
            fi
        fi
    else
        read -p "설치를 시작하시겠습니까? (y/n) [y]: " start_install
        start_install=${start_install:-y}
        
        if [[ ! "$start_install" =~ ^[Yy]$ ]]; then
            info "작업을 취소합니다."
            exit 0
        fi
    fi
    
    # 시작할 단계 선택
    if [ "$current_step" -eq 0 ]; then
        read -p "시작할 단계를 선택하세요 (1-12) [1]: " start_step_num
        start_step_num=${start_step_num:-1}
        current_step=$((start_step_num - 1))
    fi
    
    # 각 단계 실행
    steps=(
        "step1_iso_repo"
        "step2_firewall_selinux"
        "step3_hostname_hosts"
        "step4_network_dns"
        "step5_time_sync"
        "step6_disable_swap"
        "step7_remove_old_runtime"
        "step8_install_docker"
        "step9_configure_containerd"
        "step10_kernel_settings"
        "step11_install_kubernetes"
        "step12_final_check"
    )
    
    # 선택된 단계부터 실행
    for ((i=current_step; i<${#steps[@]}; i++)); do
        echo ""
        ${steps[$i]}
        
        if [ $? -ne 0 ]; then
            error "단계 $((i+1))에서 실패했습니다!"
            error "오류를 수정한 후 스크립트를 다시 실행하면 이 단계부터 재시작됩니다."
            exit 1
        fi
        
        # 다음 단계 진행 확인 (마지막 단계 제외)
        if [ $i -lt $((${#steps[@]} - 1)) ]; then
            read -p "다음 단계로 진행하시겠습니까? (y/n) [y]: " proceed
            proceed=${proceed:-y}
            
            if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
                info "작업을 중단합니다. 다음 실행 시 이어서 진행됩니다."
                exit 0
            fi
        fi
    done
    
    echo ""
    success "========== 모든 작업이 완료되었습니다! =========="
    echo ""
}

# 스크립트 실행
main "$@"
