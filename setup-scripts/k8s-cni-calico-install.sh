#!/bin/bash

# ===============================================================================
# Kubernetes Cluster Setup with Calico CNI
# 
# 이 스크립트는 kubeadm을 사용하여 Kubernetes 클러스터를 구성하고
# Calico CNI를 설치하는 자동화 스크립트입니다.
# ===============================================================================

set -euo pipefail

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 상태 파일 경로
STATE_FILE="/tmp/k8s_setup_state.txt"
LOG_FILE="/tmp/k8s_setup_$(date +%Y%m%d_%H%M%S).log"

# 설정 변수
POD_CIDR="172.20.0.0/16"
CALICO_VERSION="v3.19"
KUBERNETES_VERSION="" # 자동 감지

# ===============================================================================
# 유틸리티 함수들
# ===============================================================================

# 로그 함수
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 성공 메시지
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

# 에러 메시지
error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

# 경고 메시지
warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# 정보 메시지
info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# 단계 시작 함수
start_step() {
    local step_name=$1
    echo -e "\n${BLUE}========================================${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}단계 시작: $step_name${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}========================================${NC}" | tee -a "$LOG_FILE"
}

# 단계 완료 함수
complete_step() {
    local step_name=$1
    success "단계 완료: $step_name"
    echo -e "${GREEN}========================================${NC}\n" | tee -a "$LOG_FILE"
}

# 상태 저장 함수
save_state() {
    local step=$1
    echo "$step" > "$STATE_FILE"
    log "상태 저장: 단계 $step 완료"
}

# 현재 상태 읽기 함수
get_current_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "0"
    fi
}

# 명령 실행 및 결과 확인 함수
execute_command() {
    local cmd=$1
    local description=$2
    
    log "실행: $description"
    log "명령어: $cmd"
    
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        success "$description 완료"
        return 0
    else
        error "$description 실패"
        error "상세 로그는 $LOG_FILE 를 확인하세요"
        return 1
    fi
}

# ===============================================================================
# 시스템 정보 확인 함수들
# ===============================================================================

check_system_info() {
    start_step "시스템 정보 확인"
    
    echo -e "\n${BLUE}=== 시스템 환경 확인 ===${NC}"
    
    # 운영체제 정보
    info "운영체제 정보:"
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "  - OS: $NAME $VERSION"
    fi
    
    # Kubernetes 버전 확인
    info "\nKubernetes 도구 버전:"
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
    
    # 네트워크 인터페이스 정보
    info "\n네트워크 인터페이스 정보:"
    ip -br addr show | grep -E '^(eth|ens|enp)' | while read line; do
        echo "  - $line"
    done
    
    # NetworkManager 상태 확인
    info "\nNetworkManager 상태:"
    if systemctl is-active NetworkManager &> /dev/null; then
        echo "  - NetworkManager: 활성화됨"
        warning "Calico와 충돌할 수 있습니다. 필요시 비활성화를 고려하세요."
    else
        echo "  - NetworkManager: 비활성화됨"
    fi
    
    # 네트워크 대역 확인
    info "\n현재 네트워크 대역:"
    ip route | grep -E '^(10\.|172\.|192\.168\.)' | while read line; do
        echo "  - $line"
    done
    
    # Calico 호환성 정보
    info "\nCalico CNI 호환성 정보:"
    echo "  - 설치 예정 Calico 버전: $CALICO_VERSION"
    echo "  - Pod CIDR: $POD_CIDR"
    echo "  - Kubernetes $KUBERNETES_VERSION 와 Calico $CALICO_VERSION 호환성 확인 필요"
    
    complete_step "시스템 정보 확인"
}

# ===============================================================================
# 설치 단계 함수들
# ===============================================================================

# 단계 1: 사전 요구사항 확인
step1_prerequisites() {
    start_step "사전 요구사항 확인"
    
    # swap 비활성화 확인
    if [[ $(swapon -s | wc -l) -gt 0 ]]; then
        error "Swap이 활성화되어 있습니다. 비활성화가 필요합니다."
        return 1
    fi
    success "Swap 비활성화 확인"
    
    # 필수 커널 모듈 확인
    local modules=("br_netfilter" "overlay")
    for module in "${modules[@]}"; do
        if ! lsmod | grep -q "^$module"; then
            warning "커널 모듈 $module 이 로드되지 않았습니다."
            execute_command "modprobe $module" "커널 모듈 $module 로드" || return 1
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
    
    save_state 1
    complete_step "사전 요구사항 확인"
    return 0
}

# 단계 2: Container Runtime 확인
step2_container_runtime() {
    start_step "Container Runtime 확인"
    
    # containerd 또는 docker 확인
    if systemctl is-active containerd &> /dev/null; then
        success "containerd가 실행 중입니다"
    elif systemctl is-active docker &> /dev/null; then
        success "docker가 실행 중입니다"
    else
        error "Container runtime이 실행되지 않습니다"
        return 1
    fi
    
    save_state 2
    complete_step "Container Runtime 확인"
    return 0
}

# 단계 3: kubeadm init 실행 (Master 노드만)
step3_kubeadm_init() {
    start_step "Kubernetes 클러스터 초기화 (Master 노드)"
    
    read -p "이 노드가 Master 노드입니까? (y/n): " is_master
    if [[ "$is_master" != "y" ]]; then
        info "Worker 노드는 이 단계를 건너뜁니다"
        save_state 3
        return 0
    fi
    
    # 기존 클러스터 확인
    if kubectl cluster-info &> /dev/null 2>&1; then
        warning "이미 클러스터가 초기화되어 있습니다"
        save_state 3
        return 0
    fi
    
    # kubeadm init 실행
    local init_cmd="kubeadm init --pod-network-cidr=$POD_CIDR"
    
    info "kubeadm init 실행 중... (몇 분 소요될 수 있습니다)"
    if execute_command "$init_cmd" "Kubernetes 클러스터 초기화"; then
        # kubeconfig 설정
        mkdir -p $HOME/.kube
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config
        
        success "kubeconfig 설정 완료"
        
        # join 명령어 저장
        echo -e "\n${YELLOW}Worker 노드 조인을 위한 명령어:${NC}"
        kubeadm token create --print-join-command | tee /tmp/kubeadm_join_command.txt
        
        save_state 3
        complete_step "Kubernetes 클러스터 초기화"
        return 0
    else
        return 1
    fi
}

# 단계 4: Worker 노드 조인 (Worker 노드만)
step4_kubeadm_join() {
    start_step "Worker 노드 조인"
    
    read -p "이 노드가 Worker 노드입니까? (y/n): " is_worker
    if [[ "$is_worker" != "y" ]]; then
        info "Master 노드는 이 단계를 건너뜁니다"
        save_state 4
        return 0
    fi
    
    # 이미 조인되었는지 확인
    if systemctl is-active kubelet &> /dev/null && [[ -f /etc/kubernetes/kubelet.conf ]]; then
        warning "이미 클러스터에 조인되어 있습니다"
        save_state 4
        return 0
    fi
    
    echo "Master 노드에서 생성된 join 명령어를 입력하세요:"
    read -p "kubeadm join 명령어: " join_command
    
    if [[ -z "$join_command" ]]; then
        error "join 명령어가 입력되지 않았습니다"
        return 1
    fi
    
    if execute_command "$join_command" "클러스터 조인"; then
        save_state 4
        complete_step "Worker 노드 조인"
        return 0
    else
        return 1
    fi
}

# 단계 5: Calico manifest 다운로드
step5_download_calico() {
    start_step "Calico manifest 다운로드"
    
    # Master 노드에서만 실행
    if ! kubectl cluster-info &> /dev/null 2>&1; then
        info "Worker 노드는 이 단계를 건너뜁니다"
        save_state 5
        return 0
    fi
    
    local calico_url="https://docs.projectcalico.org/archive/${CALICO_VERSION}/manifests/calico.yaml"
    local calico_file="calico.yaml"
    
    if [[ -f "$calico_file" ]]; then
        warning "calico.yaml 파일이 이미 존재합니다"
        read -p "다시 다운로드하시겠습니까? (y/n): " redownload
        if [[ "$redownload" != "y" ]]; then
            save_state 5
            return 0
        fi
    fi
    
    execute_command "curl -O $calico_url" "Calico manifest 다운로드" || return 1
    
    save_state 5
    complete_step "Calico manifest 다운로드"
    return 0
}

# 단계 6: Calico manifest 수정
step6_modify_calico() {
    start_step "Calico manifest 수정"
    
    # Master 노드에서만 실행
    if ! kubectl cluster-info &> /dev/null 2>&1; then
        info "Worker 노드는 이 단계를 건너뜁니다"
        save_state 6
        return 0
    fi
    
    local calico_file="calico.yaml"
    
    if [[ ! -f "$calico_file" ]]; then
        error "calico.yaml 파일이 존재하지 않습니다"
        return 1
    fi
    
    # 백업 생성
    cp "$calico_file" "${calico_file}.backup"
    info "백업 파일 생성: ${calico_file}.backup"
    
    # CALICO_IPV4POOL_CIDR 수정
    info "Pod CIDR 설정 수정 중..."
    sed -i -e "/# - name: CALICO_IPV4POOL_CIDR/,+1 s/# - name: CALICO_IPV4POOL_CIDR/- name: CALICO_IPV4POOL_CIDR/" \
           -e "/# - name: CALICO_IPV4POOL_CIDR/,+1 s/#   value: \"192.168.0.0\/16\"/  value: \"$POD_CIDR\"/" \
           -e "/- name: CALICO_IPV4POOL_CIDR/,+1 s/value: \"192.168.0.0\/16\"/value: \"$POD_CIDR\"/" "$calico_file"
    
    # PodDisruptionBudget API 버전 수정
    info "PodDisruptionBudget API 버전 수정 중..."
    sed -i 's/apiVersion: policy\/v1beta1/apiVersion: policy\/v1/g' "$calico_file"
    
    success "Calico manifest 수정 완료"
    
    # 수정 내용 확인
    echo -e "\n${BLUE}수정된 내용 확인:${NC}"
    echo "1. Pod CIDR 설정:"
    grep -A1 "CALICO_IPV4POOL_CIDR" "$calico_file" | grep -v "#" | head -2
    echo -e "\n2. PodDisruptionBudget API 버전:"
    grep -B1 "kind: PodDisruptionBudget" "$calico_file" | head -2
    
    save_state 6
    complete_step "Calico manifest 수정"
    return 0
}

# 단계 7: Calico 설치
step7_install_calico() {
    start_step "Calico CNI 설치"
    
    # Master 노드에서만 실행
    if ! kubectl cluster-info &> /dev/null 2>&1; then
        info "Worker 노드는 이 단계를 건너뜁니다"
        save_state 7
        return 0
    fi
    
    local calico_file="calico.yaml"
    
    if [[ ! -f "$calico_file" ]]; then
        error "calico.yaml 파일이 존재하지 않습니다"
        return 1
    fi
    
    # Calico 설치
    if execute_command "kubectl apply -f $calico_file" "Calico CNI 설치"; then
        info "Calico Pod 상태 확인 중... (최대 5분 소요)"
        
        # Calico Pod가 Running 상태가 될 때까지 대기
        local timeout=300  # 5분
        local interval=10
        local elapsed=0
        
        while [[ $elapsed -lt $timeout ]]; do
            local not_ready=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers | grep -v "Running" | wc -l)
            
            if [[ $not_ready -eq 0 ]]; then
                success "모든 Calico Pod가 Running 상태입니다"
                break
            fi
            
            info "Calico Pod 대기 중... ($not_ready 개 Pod가 아직 준비되지 않음)"
            sleep $interval
            elapsed=$((elapsed + interval))
        done
        
        if [[ $elapsed -ge $timeout ]]; then
            warning "일부 Calico Pod가 아직 준비되지 않았습니다"
            kubectl get pods -n kube-system -l k8s-app=calico-node
        fi
        
        save_state 7
        complete_step "Calico CNI 설치"
        return 0
    else
        return 1
    fi
}

# 단계 8: 클러스터 상태 확인
step8_verify_cluster() {
    start_step "클러스터 상태 확인"
    
    # Master 노드에서만 실행
    if ! kubectl cluster-info &> /dev/null 2>&1; then
        info "Worker 노드는 이 단계를 건너뜁니다"
        save_state 8
        return 0
    fi
    
    echo -e "\n${BLUE}=== 클러스터 상태 ===${NC}"
    
    # 노드 상태
    info "노드 상태:"
    kubectl get nodes -o wide
    
    # 시스템 Pod 상태
    echo -e "\n"
    info "시스템 Pod 상태:"
    kubectl get pods -n kube-system
    
    # Calico 상태
    echo -e "\n"
    info "Calico 구성 요소 상태:"
    kubectl get pods -n kube-system -l k8s-app=calico-node
    kubectl get pods -n kube-system -l k8s-app=calico-kube-controllers
    
    # 네트워크 정책 확인
    echo -e "\n"
    info "네트워크 정책:"
    kubectl get networkpolicies --all-namespaces
    
    save_state 8
    complete_step "클러스터 상태 확인"
    return 0
}

# ===============================================================================
# 메인 실행 부분
# ===============================================================================

main() {
    echo -e "${GREEN}===============================================================================${NC}"
    echo -e "${GREEN}Kubernetes Cluster Setup with Calico CNI${NC}"
    echo -e "${GREEN}===============================================================================${NC}"
    echo -e "로그 파일: $LOG_FILE\n"
    
    # 시스템 정보 확인
    check_system_info
    
    # 작업 단계 목차 표시
    echo -e "\n${BLUE}=== 작업 단계 목차 ===${NC}"
    echo "1. 사전 요구사항 확인"
    echo "2. Container Runtime 확인"
    echo "3. Kubernetes 클러스터 초기화 (Master 노드)"
    echo "4. Worker 노드 조인 (Worker 노드)"
    echo "5. Calico manifest 다운로드"
    echo "6. Calico manifest 수정"
    echo "7. Calico CNI 설치"
    echo "8. 클러스터 상태 확인"
    
    # 현재 상태 확인
    local current_state=$(get_current_state)
    
    if [[ "$current_state" -gt 0 ]]; then
        warning "\n이전 실행에서 단계 $current_state 까지 완료되었습니다."
        read -p "단계 $((current_state + 1))부터 계속하시겠습니까? (y/n): " continue_from_state
        
        if [[ "$continue_from_state" != "y" ]]; then
            read -p "처음부터 다시 시작하시겠습니까? (y/n): " restart
            if [[ "$restart" == "y" ]]; then
                rm -f "$STATE_FILE"
                current_state=0
            else
                echo "작업을 취소합니다."
                exit 0
            fi
        fi
    else
        echo -e "\n"
        read -p "설치를 시작하시겠습니까? (y/n): " start_install
        if [[ "$start_install" != "y" ]]; then
            echo "작업을 취소합니다."
            exit 0
        fi
    fi
    
    # 각 단계 실행
    local steps=(
        "step1_prerequisites"
        "step2_container_runtime"
        "step3_kubeadm_init"
        "step4_kubeadm_join"
        "step5_download_calico"
        "step6_modify_calico"
        "step7_install_calico"
        "step8_verify_cluster"
    )
    
    for i in "${!steps[@]}"; do
        local step_num=$((i + 1))
        
        # 이미 완료된 단계는 건너뛰기
        if [[ $step_num -le $current_state ]]; then
            continue
        fi
        
        # 단계 실행
        if ! ${steps[$i]}; then
            error "단계 $step_num 에서 실패했습니다."
            error "오류를 수정한 후 스크립트를 다시 실행하면 이 단계부터 계속됩니다."
            exit 1
        fi
    done
    
    # 모든 단계 완료
    echo -e "\n${GREEN}===============================================================================${NC}"
    success "모든 설치 단계가 성공적으로 완료되었습니다!"
    echo -e "${GREEN}===============================================================================${NC}"
    
    # 상태 파일 삭제
    rm -f "$STATE_FILE"
    
    info "\n다음 단계:"
    echo "1. Worker 노드가 있다면 해당 노드에서 이 스크립트를 실행하여 클러스터에 조인하세요."
    echo "2. 'kubectl get nodes' 명령으로 모든 노드가 Ready 상태인지 확인하세요."
    echo "3. 'kubectl get pods -n kube-system' 명령으로 모든 시스템 Pod가 Running 상태인지 확인하세요."
}

# 스크립트 실행
main "$@"