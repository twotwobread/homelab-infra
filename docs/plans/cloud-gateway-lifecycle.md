# 공유 Cloud Environment와 온디맨드 Gateway 설계

## 상태와 이어받기

**설계 제안/진행 방향 합의이며 구현·배포·통합 검증 결과가 아니다.** 다른 개발 머신에서 작업을 이어갈 수 있도록 논의한 책임, 패킷 경로, 비용과 다음 검증을 기록한다.

- 전체 순서: [AWS Karpenter → Volcano → Workload Operator](gpu-autoscaling-roadmap.md).
- 완료된 정적 조사: [AWS provider/K3s 호환성](aws-provider-k3s-feasibility.md).
- 이번 결정: 기존 노드의 LAN 주소를 유지하는 site-to-site routing을 우선안으로 설계하고, 최종적으로 gateway도 CR 기반 수요/생명주기 관리에 포함한다.
- 미확정: 최종 CRD 이름/스키마, 실제 CIDR/CNI, AWS region/AZ·AMI, bootstrap credential, worker 인터넷 egress, 구현 저장소/패키지 구조.
- 실행하지 않은 것: AWS 자원 생성, 클러스터/라우터 변경, Operator 구현, 실제 전송 성능 측정.

설계 합의는 유료 실행 승인이나 기존 클러스터 변경 승인이 아니다. 실행은 사용자가 승인한 범위에서 수행한다. 코드·명령에는 실제 secret을 넣지 않는다.

### 다른 노트북에서 시작

PR 병합 전에는 다음 브랜치에 로드맵, 정적 조사, 본 설계가 함께 있다.

```bash
git clone https://github.com/twotwobread/homelab-infra.git
cd homelab-infra
git switch --track origin/docs/gpu-autoscaling-roadmap
```

병합 후에는 `develop`을 사용한다. 먼저 `AGENTS.md`와 `.harness/` 지침을 읽고 이 문서 및 위 두 문서를 검토한다. 저장소 경로는 머신마다 다를 수 있으므로 기존 절대 경로를 전제하지 않는다. kubeconfig, AWS/Tailscale 자격 증명은 clone으로 제공되지 않으며 별도 안전한 방식으로 준비한다.

## 1. 하나의 subnet이 아니라 두 네트워크 사이의 routing

Tailscale subnet router는 L3 IP routing을 제공한다. 집 LAN과 AWS VPC를 Ethernet bridge처럼 하나의 L2 subnet으로 합치지 않는다. Kubernetes 노드가 반드시 같은 LAN에 있을 필요는 없지만 필요한 노드/Pod 경로가 양방향으로 성립해야 한다.

아래 주소는 모두 설명용이다. 실제 배포에는 LAN/VPC/Pod/Service/Tailscale 대역의 충돌을 확인한 값으로 바꾼다.

```text
집 LAN: 192.168.10.0/24
┌─────────────────────────────────────────────┐
│ minipc: 192.168.10.10                        │
│ ├─ K3s control-plane                        │
│ ├─ Karpenter / 우리 Operator (목표 배치)     │
│ └─ Tailscale subnet router                  │
│                                             │
│ pi: 192.168.10.11 — 기존 K3s worker          │
└─────────────────┬───────────────────────────┘
                  │ Tailscale 암호화 연결
                  │ 직접 연결 또는 relay (실측 필요)
┌─────────────────┴───────────────────────────┐
│ AWS VPC: 10.80.0.0/16                       │
│                                             │
│ Gateway subnet: 10.80.0.0/24                │
│ Gateway EC2: 10.80.0.10                     │
│ ├─ 공인 IPv4: Tailscale 연결용 egress       │
│ ├─ Tailscale subnet router                 │
│ └─ IP forwarding                          │
│                  │ VPC routing              │
│ Worker subnet: 10.80.1.0/24                 │
│ GPU EC2: 10.80.1.20                        │
│ ├─ K3s agent                              │
│ └─ GPU Pod                                │
└─────────────────────────────────────────────┘
```

minipc가 집 gateway를 겸하는 후보안이다. GPU worker에는 이 방식에서 Tailscale 설치가 필요하지 않다. AWS gateway는 worker 이전에 존재해야 하므로 Karpenter가 GPU 수요에 따라 회수하는 일반 worker로 취급하지 않는다.

공인 IPv4는 인터넷에서 K3s API/SSH를 모두 열겠다는 뜻이 아니다. gateway의 실제 보안 그룹/egress와 Tailscale 직접 연결 조건은 별도 설계한다. 집 API 6443을 인터넷에 공개하는 것을 전제로 하지 않는다.

## 2. 양방향 경로 계약

목표는 원본 주소를 보존하는 site-to-site routing이다. Tailscale 기본 SNAT 동작만으로 양방향 경로가 자동 완성된다고 가정하지 않는다.

| 위치 | 목적지 | 다음 경로 |
| --- | --- | --- |
| 집 pi/필요한 LAN 노드 또는 집 라우터 | AWS worker subnet | minipc LAN 주소 |
| minipc | AWS worker subnet | Tailscale의 AWS subnet router |
| AWS worker subnet route table | 집 LAN | AWS gateway ENI |
| AWS gateway | 집 LAN | Tailscale의 minipc subnet router |
| minipc가 집 LAN으로 전달 | 집 LAN 노드 | LAN interface |

Tailscale 측에서는 집 LAN과 AWS worker subnet 경로를 각각 광고/승인하고 필요한 접근 정책을 정의한다. AWS gateway의 Tailscale 상태 확인 등 관리 경로에 gateway subnet이 필요하다면 범위를 따로 설계한다. 불필요하게 VPC 전체를 광고하지 않는다.

추가 설정/검증:

- 양측 IP forwarding, Tailscale accepted routes/광고/승인/ACL 또는 grants.
- site-to-site에 필요한 subnet route SNAT 비활성화와 반환 경로.
- EC2 gateway의 source/destination check 비활성화.
- AWS route table target ENI, security group/NACL 및 host firewall.
- pi에 직접 route를 넣을지, 집 라우터에서 route를 제공할지.
- 기존 관리용 minipc /32 route와 새 LAN route의 우선순위·접근 범위.
- gateway가 자기 subnet을 다시 VPN으로 보내는 route loop 방지.
- 노드가 광고하는 InternalIP, CNI underlay, MTU와 reverse-path filtering 영향.

**route 광고/승인은 pi의 OS route나 AWS route table을 자동 작성하지 않는다.** 각각의 책임과 적용 방법을 명시해야 한다.

## 3. 패킷 흐름: 단계별 설명

### 3.1 Worker가 K3s에 가입

```text
EC2 10.80.1.20
  → 목적지 192.168.10.10:6443
  → worker subnet route table: 집 LAN은 gateway ENI
  → AWS gateway: 집 LAN은 Tailscale
  → 암호화된 VPN 연결
  → minipc: 복호화 후 자신의 K3s API로 전달
```

응답은 minipc의 AWS worker subnet 경로 → Tailscale → AWS gateway → VPC worker로 돌아간다. API TLS 이름/주소 검증과 K3s 가입 자격 증명은 routing과 별개다.

### 3.2 집 pi가 cloud worker에 접근

```text
pi 192.168.10.11
  → 목적지 10.80.1.20
  → pi/집 라우터의 route에 따라 minipc로 전달
  → minipc Tailscale
  → AWS gateway
  → VPC 내부 경로
  → worker
```

worker의 응답은 집 LAN route를 사용해 AWS gateway → Tailscale → minipc → pi로 돌아간다. control-plane/kubelet 연결도 필요한 실제 주소/포트/터널 동작을 구분해 검증한다.

### 3.3 Pod 간 통신

실제 backend가 Flannel VXLAN일 경우의 예시이며 현재 환경의 backend를 확인했다는 의미는 아니다.

```text
pi의 Pod
  → CNI가 Pod 패킷을 노드 간 VXLAN 패킷으로 캡슐화
  → 바깥 목적지: cloud worker Node IP
  → minipc → Tailscale → AWS gateway → worker
  → CNI가 decapsulation
  → GPU Pod
```

CNI가 Pod 경로를 제공하고 Tailscale/site routing은 Node 간 underlay 경로를 제공한다. 이런 overlay에서는 모든 Pod CIDR을 Tailscale에 직접 광고하는 것이 필수는 아니다. 다른 CNI/backend는 요구 경로가 다를 수 있다.

작은 ping/API 요청 성공뿐 아니라 DNS, Pod 간 TCP, 큰 패킷, 이미지/결과 전송도 검증한다. VPN+CNI 캡슐화의 MTU와 relay 경로 대역폭을 측정한다.

### 3.4 인터넷 egress는 별도

worker의 이미지 pull, 패키지 설치, AWS API 접근은 집 LAN route로 자동 해결되지 않는다. 다음 중 선택해야 한다.

- worker 공인 IP + 필요한 인바운드만 허용.
- gateway에 NAT 기능을 별도로 구성.
- 필요한 서비스용 VPC endpoint 및 그 외 egress 경로.

관리형 NAT Gateway를 자동으로 추가하지 않는다. AWS gateway가 VPN subnet router인 것과 일반 인터넷 NAT gateway인 것은 별개다. 선택에 따라 과금/보안/복구 범위가 달라진다.

## 4. CR과 controller 책임

이름은 후보이며 구현된 CRD가 아니다.

```text
GPUWorkload A ─┐
              ├─ environmentRef: aws-lab
GPUWorkload B ─┘
                       ↓
              CloudEnvironment/aws-lab
                       ↓
              Environment controller
                       ↓
              공유 gateway 한 대
```

| 구성 요소 | 소유 책임 |
| --- | --- |
| CloudEnvironment controller | gateway, 동적 route/VPN 연결, 준비·유휴·종료 상태 |
| Workload controller | 요청 검증, 환경 사용 수요, 하위 Job/PodGroup, 상태·취소 |
| Karpenter | NodeClaim과 GPU/CPU worker 프로비저닝·회수 |
| Volcano | Queue/gang 등 워크로드 배치 |
| IaC/운영 | 장기 VPC/subnet/IAM 및 controller credential 기반 |

초기에는 두 controller를 하나의 Operator 프로세스로 배포해도 된다. 공유 Environment를 특정 Workload의 자식으로 만들어 그 CR 삭제와 함께 GC시키지 않는다. Environment/Workload의 scope와 참조 권한은 CRD 설계에서 확정한다.

최소 후보 필드:

```yaml
# 개념용. apiVersion/확정 schema가 없으며 kubectl apply 대상 아님.
kind: CloudEnvironment
spec:
  provider: aws
  region: ap-northeast-2
  lifecycle:
    mode: OnDemand
    idleTimeout: 10m
---
kind: GPUWorkload
spec:
  environmentRef:
    name: aws-lab
  gpuCount: 1
```

실제 secret은 값 대신 참조를 사용한다. 비용이 없는 기반까지 매번 생성/삭제할 필요는 없으며 VPC/subnet/보안 그룹/IAM은 별도 선언으로 유지할 수 있다. 유지 자원별 과금 여부는 확인한다.

## 5. 존재 확인만으로는 부족: idempotency와 소유권

Workload마다 EC2를 조회하고 없으면 생성하는 방식은 동시 reconcile에서 중복을 만들 수 있다. Environment controller를 생성의 단일 책임자로 두고 다음을 구현한다.

- Environment UID를 자원 태그/소유권 기준으로 사용.
- EC2 생성의 client token 등 idempotent API 사용.
- EC2 생성 성공 후 status 저장 전에 죽어도 기존 자원을 재검색할 수 있게 설계.
- 재생성 세대별 요청 token 관리. 영구 token 하나를 모든 교체에 재사용하지 않음.
- 동명의 외부 자원을 임의로 가져오거나 삭제하지 않음. 소유권 불일치는 오류로 보고.
- 하나보다 많은 gateway 발견 시 추가 생성을 멈추고 복구 경로 제공.
- status의 ID, 실제 EC2 상태, VPN 상태, route 상태를 대조.

사용 수요는 CR 단순 개수가 아니라 실행/대기/종료 중인 작업과 실제 잔존 worker로 판단한다. 증가/감소 counter만 유일한 진실로 삼지 말고 관측으로 재구성할 수 있게 한다. controller 재시작·API timeout·중복 이벤트를 정상 상황으로 취급한다.

## 6. 상태 전이와 생성 순서

후보 상태:

```text
Dormant → Provisioning → Connecting → Ready
                                  ↘ Failed
Ready → Idle → Draining → Deleting → Dormant
```

1. Workload가 Environment에 수요를 만든다.
2. Environment controller가 기존 gateway를 재사용하거나 생성한다.
3. Tailscale 가입·route·접근 정책·집 측 연결을 확인한다.
4. `Ready=True`를 보고한다. EC2 running만으로 Ready라 하지 않는다.
5. Workload controller가 Job을 생성한다.
6. Pending 수요를 Karpenter가 처리하고 worker를 생성한다.
7. worker는 준비된 사설 경로로 가입한다.
8. NodeClaim 등록/초기화와 GPU allocatable을 확인한 뒤 작업 실행 상태를 보고한다.

Environment Ready는 연결 기반 준비이며 아직 없는 worker의 모든 통신을 보장하지 않는다. 최초 worker 기반 종단 검증 결과를 별도 Condition으로 표현할 수 있다.

새 환경 전용 NodePool과 worker의 소유 범위를 명확히 한다. 우리 CR 외부에서 해당 NodePool을 사용하는 Pod가 있다면, Job 생성 gate만으로 모든 새 worker 생성을 통제할 수 없다. 종료 단계에는 신규 수요 차단/NodePool 제어를 사용 버전에 맞게 설계하고 잔존 수요를 재확인한다.

## 7. 회수 순서와 장애 처리

정상 회수:

```text
마지막 활성 수요 종료
  → 유휴 정책에 따라 새 작업 가능성 대기
  → 새 배치/프로비저닝을 안전하게 차단하고 수요 재확인
  → Karpenter가 worker를 회수
  → NodeClaim/EC2 잔존 확인
  → 동적 route 제거/광고 철회 등 연결 정리
  → gateway EC2 종료 및 EBS/공인 IP 회수
  → VPN 기기/등록 상태 정리
  → Dormant
```

유휴 타이머와 worker 축소는 일부 겹칠 수 있지만 **gateway 종료는 worker 실제 종료 뒤**가 원칙이다. 집의 기존 관리용 Tailscale 기기/route를 통째로 삭제하지 않는다.

- 새 요청이 Idle에서 도착: 정상 가동으로 복귀.
- Draining/Deleting에서 도착: 임계 단계에 따라 종료 취소 또는 정리 후 재생성. Ready로 성급히 되돌리지 않음.
- EC2 생성 실패: bounded backoff와 timeout, 중복 자원 확인.
- VPN 가입 실패: GPU Job 생성을 보류하고 gateway 비용 누적을 제한.
- route 적용 실패: 실제 상태를 비교하며 재시도, 부분 완료 상태 기록.
- worker가 회수되지 않음: gateway 유지/비용 경고, 별도 강제 회수 정책 없이는 연결을 끊지 않음.
- Environment 삭제: 외부 자원 finalizer로 정리하되 의존 Workload 처리 정책(거부/취소/유예)을 명시.
- controller가 집 장애로 정지: CR만으로 비용 종료가 보장되지 않음. AWS 측 만료 태그/독립 cleanup을 후속 안전장치로 설계.

강제 정리는 활성 작업/데이터 손실 위험을 명시하고 사용자 승인을 받는다. 공용 환경에서 Workload 하나의 finalizer가 gateway 전체를 삭제하거나 다른 작업의 worker 종료를 기다리게 하지 않는다.

## 8. 비용 추정과 운영 전제

서울 Linux On-Demand 공개 가격 데이터 조회 기준이며 견적 보장/실청구 확인이 아니다. 월 730시간, 공인 IPv4 한 개, 세금/크레딧 제외.

| 항목 | 시간당 | 월 환산 |
| --- | --- | --- |
| t4g.micro (1 GiB, ARM) | USD 0.0104 | USD 7.592 |
| 공인 IPv4 | USD 0.005 | USD 3.65 |
| 합계 (디스크/전송 제외) | USD 0.0154 | USD 11.242 |

소형 root gp3 디스크의 월 USD 1~2는 여유 예산 추정일 뿐 서울 단가를 검증한 숫자가 아니다. 고정비 예산은 대략 USD 12~14/월로 안내했으나 실제 용량·최소 AMI 디스크·요금으로 다시 계산한다. 20시간의 EC2+IPv4만 계산하면 USD 0.308이다.

- EC2 정지 후 EBS 보관료와 할당된 Elastic IP 과금이 남을 수 있음.
- VPN을 타도 AWS 인터넷 아웃바운드 전송료는 존재.
- AWS의 일반적인 월 100GB 인터넷 아웃바운드 무료량은 서비스/리전 합산 조건이며 독립 리전별 혜택이 아님.
- 다른 AZ의 gateway/worker 통신 비용을 줄이기 위해 초기 실험은 같은 AZ 우선.
- t4g는 CPU credit/Unlimited 과금과 지속 VPN 처리량 검증 필요. 최대 네트워크 표기를 실효 성능으로 보장하지 않음.
- Tailscale 플랜/사용자·기기 제한 적합성, 인터넷 egress 선택 비용, 부수 리소스를 별도 확인.
- 온디맨드 gateway는 첫 작업 cold-start 지연과 비용 사이의 trade-off. 공유 유휴 대기 시간을 조정해 재생성 반복을 줄임.

출처:

- [EC2 On-Demand 요금](https://aws.amazon.com/ec2/pricing/on-demand/)
- [서울 Linux EC2 가격 데이터](https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/Asia%20Pacific%20%28Seoul%29/Linux/index.json)
- [공인 IPv4 요금](https://aws.amazon.com/vpc/pricing/)
- [EBS 요금](https://aws.amazon.com/ebs/pricing/)

앞선 세션에서 EC2 가격 JSON 및 공식 VPC/EC2 가격 페이지를 조회했다. 가격은 변경 가능하며 이번 문서 저장 시 재견적하지 않았다.

## 9. 다음 실행 단위와 검증 기준

최종 Operator 자동화와 초기 실험 순서를 분리한다.

### A. 읽기 전용 현황 확인 (다음 작업)

- 사용할 kube context/namespace 확인, 실제 K3s 버전·CNI backend·CIDR·Node IP 수집.
- minipc/pi의 route·forwarding·방화벽·Tailscale 구성과 집 라우터의 정적 route 지원 확인.
- AWS 계정/리전/AZ·쿼터·gateway/CPU 실험 예산 확인.
- 정확한 route 표와 주소 충돌 검사, credential 공급 방식, worker egress 방식 확정.

전체 kubeconfig/토큰/원본 방화벽 로그를 커밋하지 않는다. 운영 변경이 필요한 항목은 결과에 따라 별도 제안한다.

### B. Gateway + 단일 CPU worker 수동/IaC PoC

- 사용자 승인 후 gateway 생성, route/접근 정책 적용.
- CPU EC2 가입 및 minipc/pi와 양방향 통신 검증.
- API TLS, DNS, 노드/Pod 간 통신·MTU·직접/relay 경로 검증.
- worker → gateway 순으로 종료, 유료/외부 잔존 자원 확인.
- 실패 시 새 route를 제거하고 기존 관리 경로를 보존하는 롤백 검증.

### C. Karpenter → GPU → Volcano

동일 bootstrap/네트워크 기반에서 전체 로드맵의 단계별 gate를 수행한다. worker 생성/축소를 먼저 검증하고 스케줄러 연동을 추가한다.

### D. Operator 자동화

수동으로 검증한 절차를 CloudEnvironment/Workload reconcile로 구현한다. 단일 생성, 공유 재사용, 부분 실패, 중복 reconcile, controller 재시작, 종료 중 새 수요, orphan cleanup을 테스트한다. 초기 네트워크 실험을 Operator 완성에 의존시키지 않는다.

## 10. 구현 전 결정해야 할 질문

1. 집 pi에 route를 직접 넣을지, 라우터의 정적 route를 이용할지?
2. 현재 CNI/backend와 노드 주소를 유지한 채 site-to-site 경로가 성립하는지?
3. worker 인터넷 egress를 어떻게 제공할지?
4. gateway/worker의 bootstrap 자격 증명을 누가 발급·회수할지?
5. Environment의 namespace/scope와 참조 권한을 어떻게 제한할지?
6. idle timeout, 최대 준비 시간, 종료 실패 비용 한도는 얼마인지?
7. 실행 노드가 남았는데 집 controller가 중단된 경우 독립 cleanup 정책은 무엇인지?

이 질문들을 완료된 설정으로 추정하지 않는다. 첫 후속 작업은 A의 읽기 전용 점검과 네트워크 변경안 확정이다.
