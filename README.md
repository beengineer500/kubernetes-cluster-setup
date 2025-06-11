## Intro
* Kubernetes 학습을 위한 테스팅 환경을 직접 구성해보며, 더욱 깊은 이해를 해보고자 합니다.
<br>

## Spec
* CPU : intel(R) i7-8665U CPU @ 1.90GHz, 2112Mhz, 4 Core, 8 Logical Processors
* Memory : 32GB
* Disk : 약 450GB
* Hypervisor
  * VMware Workstation Pro, VMware ESXi 7
* OS
  * RHEL 8.4, 9.4
  * Rocky Linux 8.4, 9.4
<br>

## Cluster info
* Control Plane (Master Node) : 1
* Data Plane (Worker Node)
  * cpu-node : 2
  * gpu-node : 1
<br>

## Log
### [2025-5-27 ~ 2025-6-1]
  1. Hypervisor 설치 (VMware EXSi, VirtualBox)
  2. VM 생성/설정 & OS 설치
  3. OS 설정
  4. Kubernetes Cluster - Online 구축
<br>

### [2025-6-2 ~ 2025-6-8]
  1. Kubernetes Cluster - Offline 구축
<br>

### [2025-6-10 ~ ]
  1. Test Server CPU 장착 (NVIDIA Tesla V100 PCIe * 1)
  2. NVIDIA Driver, CUDA toolkit 호환성 및 버전 확인, 설치
  3. k8s-gpu-worker 노드 구성 및 클러스터 join
  4. (ing) NVIDIA Container toolkit 호환성 및 버전 확인, 설치 
<br>
<br>
