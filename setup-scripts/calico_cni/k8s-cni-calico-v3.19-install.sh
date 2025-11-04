#!/bin/bash

#==============================================================================
# Calico v3.19 Setup Script
# Description: kubeadm init 이후, 쿠버네티스 통신을 위한 Calico v3.19 CNI 구성 스크립트
# Author: Beengineer
# Version: 1.0
#==============================================================================

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 상태 파일 경로
STATE_FILE="/var/log/calico_setup.state"
LOG_FILE="/var/log/calico_setup.log"

# 설정 변수
POD_CIDR='192.168.160.0/24'
CALICO_VERSION="v3.19"
KUBERNETES_VERSION=""

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

    # Kubernets 버전 확인
    info "\nKubernetes 도구 버전 (kubeadm, kubelet, kubectl):"
    if command -v kubeadm &> /dev/null; then
        KUBERNETES_VERSION=$(kubeadm version -o short)
        echo "  - kubeadm: $KUBERNETES_VERSION"
    else
        warning "kubeadm이 설치되지 않았습니다"
    fi
    
    if command -v kubectl &> /dev/null; then
        echo "  - kubectl: $(kubectl version --client --short 2>/dev/null || echo 'N/A')"
    else
        warning "kubectl이 설치되지 않았습니다"
    fi
    
    if command -v kubelet &> /dev/null; then
        echo "  - kubelet: $(kubelet --version)"
    else
        warning "kubelet이 설치되지 않았습니다"
    fi

        # Calico 호환성 정보
    info "\nCalico CNI 호환성 정보:"
    echo "  - 설치 예정 Calico 버전: $CALICO_VERSION"
    echo "  - Pod CIDR: $POD_CIDR"
    echo "  - Kubernetes $KUBERNETES_VERSION 와 Calico $CALICO_VERSION 호환성 확인 필요"
    
    info "======================================"
    echo ""
}

# 작업 목차 표시
show_menu() {
    echo ""
    info "========== 작업 단계 목차 =========="
    echo "1. ISO 마운트 및 로컬 레포지토리 설정"
    echo "2. 방화벽 비활성화 및 SELinux 설정"
    echo "3. 커널 모듈 및 sysctl 설정"
    echo "4. 호스트명 및 hosts 파일 설정"
    echo "5. 네트워크 DNS 설정"
    echo "6. 시간 동기화 확인"
    echo "7. Swap 비활성화"
    echo "8. 기존 컨테이너 런타임 제거"
    echo "9. Docker 및 Containerd 설치"
    echo "10. Containerd 설정"
    echo "11. Kubernetes Docker 이미지 로드"
    echo "12. Kubernetes 패키지 로컬 설치"
    echo "13. 최종 확인 및 완료"
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

# Step 1 : 사전 요구사항 확인
step1_prerequisites() {
    start_step "사전 요구사항 확인"

    # swap 비활성화 확인
    if [[ $(swapon -s | wc -l) -gt 0 ]]; then
        warning "swap이 활성화 돼있습니다. 비활성화가 필요합니다."
        return 1
    fi
    success "Swap 비활성화 확인"

    # 필수 커널 모듈 확인
    local modules=("overlay" "br_netfilter")
    for module in "${modules[@]}"; do
        if ! lsmod | grep -q "^$module"; then
            waring "커널 모듈 $module 이 로드되지 않았습니다."
            execute_command "modprobe $module" "커널 모듈 $module 로드"
        fi
    done
    success "필수 커널 모듈 확인"

    # sysctl 설정 확인
    if [[ ! -f /etc/sysctl.d/k8s.conf ]]; then
        cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
        execute_command "sysctl --system" "sysctl 설정 적용" || return 1
    fi
    success "sysctl 설정 확인"

    complete_step 1 "사전 요구사항 확인"
    retunr 0
}

# Step 2 : 컨테이너 런타임 확인
step2_container_runtime() {
    start_step "Container Runtime 확인"

    # containerd, docker 확인
    if systemctl is-active containerd &> /dev/null; then
        success "containerd 가 실행 중입니다."
    elif systemctl is-active docker &> /dev/null; then
        success "docker 가 실행 중입니다."
    else
        error "Container Runtime이 실행 상태가 아닙니다."
        return 1
    fi

    complete_step 2 "Container Runtime 확인"
    return 0
}

# Step 3 : 클러스터 확인
step3_cluster() {
    start_step "Kubernetes 클러스터 상태 확인"

    kubectl get nodes || { error "쿠버네티스 클러스터를 확인하세요."; return 1; }
    
    complete_step 3 "Kubernetes 클러스터 상태 확인"
    return 0
}


# Step 4 : Calico 이미지 로드
step4_load_calico_images() {
    start_step "Calico 이미지 로드"
    read -p "이미지 로드를 위해, Bundle 내 Caclico 도커 이미지 파일 경로를 입력하세요. : " calico_docker_image_path

    echo ">>> Calico Docker 이미지를 로드합니다..."
    for img in "${calico_docker_image_path}"/*.tar; do
      ctr -n k8s.io image import "${img}" || { error "${img} 이미지 로드 실패"; return 1;}
    done

    echo ">>> 모든 Calco 도커 이미지를 성공적으로 로드했습니다."
    
    # 이미지 확인
    crictl images
    
    complete_step 4 "Calico 이미지 로드"
    retrun 0
}

# Step 5 : Calico mainfest 수정
step5_modify_calico() {
    start_step "Calico manifest 수정"
    read -p "Calico manifest 수정을 위해, Bundle 내 calico.yaml 파일 경로를 입력하세요. (calico.yaml 포함) : " calico_manifest_file
    
    if [[ ! -f "$calico_manifest_file" ]]; then
        error "calico.yaml 파일이 존재하지 않습니다."
        return 1
    fi

    # 백업 생성
    cp "$calico_manifest_file" "${calico_manifest_file}.bk"
    info "백업 파일 생성: ${calico_manifest_file}.bk"

    # CALICO_IPV4POOL_CIDR 수정
    info "calico.yaml 내 Pod CIDR 설정 수정 중..."
    



}


# Step 12: Kubernetes 패키지 로컬 설치
step12_local_install_kubernetes() {
    start_step "Kubernetes 패키지 로컬 설치"
    
    # 쿠버네티스 패키지 로컬 설치
    read -p "패키지 설정을 위해, Bundle 내 OS 버전에 맞는 k8s 패키지 경로를 입력하세요. : " k8s_pkg_path
    dnf localinstall -y ${k8s_pkg_path}/*.rpm || { error "kubernetes 패키지 로컬 설치 실패"; return 1; }

    # kubelet 활성화
    systemctl start kubelet
    systemctl enable kubelet
    
    info "설치된 Kubernetes 버전:"
    kubectl version --client
    kubeadm version
    kubectl --version
    
    complete_step 12 "Kubernetes 패키지 로컬 설치"
    return 0
}

# Step 13: 최종 확인
step13_final_check() {
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
    
    # 상태 파일 제거 (모든 단계 완료)
    rm -f "${STATE_FILE}"
    
    complete_step 13 "최종 확인 및 완료"
    return 0
}

# 메인 함수
main() {
    clear
    echo "=================================================="
    echo "   Calico CNI Setup Script v1.0"
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
        read -p "시작할 단계를 선택하세요 (1-13) [1]: " start_step_num
        start_step_num=${start_step_num:-1}
        current_step=$((start_step_num - 1))
    fi
    
    # 각 단계 실행
    steps=(
        "step1_iso_repo"
        "step2_firewall_selinux"
        "step3_kernel_settings"
        "step4_hostname_hosts"
        "step5_network_dns"
        "step6_time_sync"
        "step7_disable_swap"
        "step8_remove_old_runtime"
        "step9_install_docker"
        "step10_configure_containerd"
        "step11_load_k8s_docker_images"
        "step12_localinstall_kubernetes"
        "step13_final_check"
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
