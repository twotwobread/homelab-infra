# AWS Karpenter provider → Volcano → Workload Operator 계획

## 상태와 범위

**상태: 사용자와 합의한 진행 방향을 기록한 계획. 구현·통합 검증 완료가 아니다.**

첫 실험 공급자는 AWS로 선택한다. AWS Karpenter provider의 확장·축소를 먼저 검증하고 Volcano 스케줄링을 결합한 뒤, 사용자 Workload CR을 처리하는 Operator를 구축한다. 추후 비용/공급 조건이 더 좋은 벤더가 있으면 기존 provider 구현을 분석해 새 provider 개발을 검토한다.

이번 변경은 문서화만 수행한다. 클러스터 변경, 클라우드 자원 생성, 자격 증명 발급, 유료 서비스 가입을 승인한 것으로 해석하지 않는다. 서버 작업은 사용자가 실행하며 실행 안내 시 context/namespace와 비용·영향을 명시한다.

이 문서는 단계 간 의존성, 인프라 검증 기준과 결정의 기준 위치다. 스케줄링 연구의 상세 결과와 Operator 내부 구현은 각각 담당 저장소에서 관리하고 여기에는 통합 계약과 확인 결과만 연결한다. 저장소 간 통합이나 Argo CD 설치가 이미 완료되었다고 가정하지 않는다.

## 1. Provider 용어와 선택 배경

### OCI는 인터페이스 규격이 아니다

여기서 OCI는 **Oracle Cloud Infrastructure**이며 AWS/GCP와 같은 클라우드 서비스 이름이다. Karpenter Provider OCI는 Oracle 클라우드 자원을 다루는 구현이다. 컨테이너 표준인 Open Container Initiative와도 구분한다.

CNI처럼 공통 규약과 구현을 분리한다는 비유는 가능하지만, 정확한 대응은 다음과 같다.

| 영역 | 공통 규약/추상화 | 구현 |
| --- | --- | --- |
| 컨테이너 네트워크 | CNI 명세 | CNI 플러그인 |
| Karpenter | CloudProvider 인터페이스 및 공통 controller/API | AWS/GCP/OCI provider |

CNI 실행 파일 호출 규약과 Karpenter의 Go 코드 수준 인터페이스는 동일한 플러그인 모델이 아니다. 새 벤더를 붙일 때 구현하는 대상은 OCI가 아니라 해당 버전의 Karpenter provider 계약이다.

### 조사 근거와 한계

직전 대화에서 공개 저장소 메타데이터와 main README를 조회했다. 아래는 그때 확인한 범위이며 릴리스별 GPU 동작이나 K3s 호환성 검증은 아니다. 구현 착수 시 사용할 tag/commit을 고정하고 재확인한다.

| Provider | 근거 | 확인 범위 |
| --- | --- | --- |
| AWS | [aws/karpenter-provider-aws](https://github.com/aws/karpenter-provider-aws) | AWS 구현. 첫 실험 및 코드 분석 기준으로 선택 |
| GCP | [cloudpilot-ai/karpenter-provider-gcp](https://github.com/cloudpilot-ai/karpenter-provider-gcp) | README는 GKE Standard를 대상으로 설명. Google 조직 저장소가 아님 |
| OCI | [oracle/karpenter-provider-oci](https://github.com/oracle/karpenter-provider-oci) | Oracle 조직 저장소. README는 OKE를 대상으로 설명 |

OCI 문서에 custom cloud-init/bootstrap 항목이 있어도 K3s 지원의 증거는 아니다. Provider가 존재하는 것, GPU VM 생성 지원, 관리형 클러스터 외부에서의 지원은 각각 확인한다. GCP/OCI 설치는 현재 범위에서 제외한다.

## 2. 목표 구조와 책임

후속 합의로 gateway도 온디맨드 생명주기 관리에 포함한다. [공유 Cloud Environment와 gateway 설계](cloud-gateway-lifecycle.md)에 site-to-site 패킷 경로, 공유/중복 생성 방지, worker 종료 후 gateway 회수, 비용 및 다른 개발 머신의 이어받기 절차를 기록했다. Gateway 네트워크를 먼저 수동/IaC로 검증하고, 단계 3에서 Environment/Workload controller로 자동화한다.

```text
Workload CR
    ↓ 우리 Operator
Job 또는 Volcano Job / PodGroup
    ↓ GPU resource request를 가진 Pod
스케줄링 불가 수요
    ↓ Karpenter core + AWS provider
NodeClaim / EC2 생성 및 bootstrap
    ↓ K3s worker 등록 또는 별도 승인된 클러스터 등록
Node Ready + GPU allocatable 확인
    ↓ 기본 scheduler 또는 Volcano
워크로드 실행
```

| 구성 요소 | 책임 |
| --- | --- |
| Operator | 사용자 의도 검증, 하위 워크로드 생성·소유권·상태·취소 |
| Karpenter | Pod 수요를 바탕으로 노드 용량 선택, 프로비저닝, disruption/정리 |
| AWS provider | AWS 자원·이미지·bootstrap·인스턴스 생명주기 구현 |
| Volcano | 큐, gang scheduling 등 배치 정책 |
| GPU 스택 | 드라이버, runtime, device plugin 및 GPU 자원 광고 |
| 인프라 운영 | 네트워크, IAM, 설치, 비용 제한, 고아 자원 탐지·복구 |

Operator가 별도의 GPU 부족 계산기/스케줄러/EC2 삭제기를 중복 구현하지 않는 것이 기본 방향이다. 첫 구현은 표준 워크로드 수요를 만들고 상태를 추적한다.

## 3. 단계 0 — AWS와 기존 K3s의 호환성 조사

**정적 조사 완료:** [AWS provider/K3s 조사 결과](aws-provider-k3s-feasibility.md). AWS provider/core v1.15.1과 보고된 K3s 버전 소스에서 비-EKS endpoint/version 경로, Custom bootstrap, providerID 보존을 확인했다. **upstream 수정 없이 Custom AMI/bootstrap CPU PoC를 우선 진행**한다. 네트워크·자격 증명 확정과 유료 실행 승인은 별도이며, 런타임 호환성은 아직 미검증이다.

**목표:** 집의 기존 K3s control-plane에 EC2 worker를 붙이는 구성이 선택한 AWS provider 버전에서 가능한지 판정한다. EKS 실습으로 조용히 대체하지 않는다.

### 조사 항목

- 현재 Kubernetes/K3s 버전과 Karpenter core/provider 호환성
- EKS endpoint/cluster discovery, 인증, 이미지, node bootstrap의 결합도
- custom user data/이미지로 K3s agent 가입을 구성할 수 있는지
- NodeClaim → EC2 → Kubernetes Node의 providerID 매핑 및 등록/초기화 조건
- EC2에서 control-plane으로, control-plane에서 kubelet으로, 노드/Pod 사이에 필요한 통신
- Tailscale을 이용할 경우 기기 등록·route·CNI·MTU·DNS·정리 및 기기 자격 증명 수명
- K3s agent 가입 토큰과 AWS 자격 증명을 최소 권한으로 전달·회수하는 방법
- AWS GPU 인스턴스/리전/쿼터, On-Demand/Spot 공급과 이미지 지원
- GPU 드라이버/runtime/device plugin 초기화, startup taint 제거 주체

### 코드 분석 순서

1. [Karpenter core](https://github.com/kubernetes-sigs/karpenter)의 NodePool/NodeClaim 및 CloudProvider 계약
2. AWS의 instance type discovery, NodeClass, 가격/가용성, 이미지/user data 생성
3. Create/Get/List/Delete 및 NodeClaim 등록·초기화·종료 연결
4. EKS 고유 의존성과 대체 가능한 bootstrap 경계 정리

파일 경로와 인터페이스 메서드는 선택한 버전의 실제 소스를 기준으로 기록하며 현 시점에 고정된 API라고 추정하지 않는다.

### 통과/중단 기준

- **통과:** 지원 설정 또는 작고 설명 가능한 변경으로 K3s 가입·식별·종료가 가능하다는 근거 확보.
- **조건부:** 필요한 provider 수정 범위와 유지보수 부담을 별도 설계로 리뷰.
- **중단/재결정:** 관리형 클러스터 의존성이 커서 현재 목표와 맞지 않으면 사용자와 선택. (A) 제한된 EKS 실습, (B) K3s용 provider/bootstrap 개발을 별도 선행 과제로 분리.

EKS 클러스터 비용이나 새 provider 개발을 기존 승인 범위에 포함하지 않는다. 이 단계의 산출물은 호환성 판단과 비용/권한 제안이며, 자원 생성은 아니다.

## 4. 단계 1 — AWS provider 확장·축소 검증

### 1A. CPU VM으로 네트워크와 생명주기 검증

GPU 비용을 쓰기 전에 저렴한 CPU VM으로 다음을 확인한다.

- 최소 네트워크·IAM·bootstrap 구성의 재현 가능한 선언
- EC2 생성 → 가입 → Node Ready → 일반 Pod 실행
- control-plane/kubelet 및 노드 간 Pod 통신, DNS, 이미지 pull
- 생성 실패/가입 실패의 timeout과 잔존 인스턴스 식별
- 노드/NodeClaim 삭제와 EC2 실제 종료, 관련 디스크·네트워크 자원 정리

직접 VM 가입 검증은 Karpenter 통합 성공과 구분한다. 이후 기본 scheduler의 Pending Pod가 Karpenter를 통해 노드를 생성하고 수요 제거 후 정리되는 과정을 별도로 확인한다.

### 1B. GPU 확장

- 허용 인스턴스 종류·지역·capacity type을 좁게 지정
- GPU 요청 Pod 하나로 노드 생성
- Node Ready 외에 기대한 GPU allocatable과 device plugin 정상 확인
- 작은 GPU 작업으로 장치 사용 검증
- 초기화 실패 시 반복 노드 생성/방치가 없는지 확인
- 작업 삭제 후 정책에 따른 유휴 정리와 EC2 종료 확인

### 통과 기준

일반 scheduler에서 생성→실행→삭제→유휴 정리의 한 사이클을 반복 가능하게 검증한다. 증거에는 각 단계 시간, NodeClaim/Node 상태, GPU 자원, 인스턴스 종료와 잔존 자원 확인을 포함한다. 민감 정보가 포함된 전체 로그는 커밋하지 않는다.

### 롤백

새 수요를 중지하고 실험 워크로드를 제거한 뒤, 사용 버전의 정상 NodeClaim/노드 종료 경로를 따른다. 마지막으로 EC2와 부수 자원을 조회한다. Controller/IAM을 먼저 제거해 finalizer 정리를 불가능하게 만들지 않는다. Finalizer 강제 삭제는 외부 자원 회수를 확인한 비상 절차로만 다룬다.

## 5. 단계 2 — Volcano 스케줄링과 autoscaling 결합

기본 scheduler의 정상 baseline을 유지한 상태에서 별도 실험 namespace와 명시적인 schedulerName을 사용한다. 기존 시스템 Pod를 Volcano로 일괄 전환하지 않는다.

| 실험 | 확인할 내용 |
| --- | --- |
| 단일 GPU 작업 | Volcano 경로에서도 기본 실행 가능 |
| 다중 Pod gang | minMember 등의 조건 만족 전 실행 보류, 필요한 용량 확보 후 실행 |
| Queue 경쟁 | 큐 정책으로 대기하는 수요와 물리 용량 부족 구분 |
| 용량 부족 | 선택 버전에서 Volcano의 Pending/Unschedulable 상태가 Karpenter에 인식되는지 |
| 과잉 생성 | 큐 차단 수요 때문에 불필요한 VM이 생성되는지 |
| 작업 취소 | 취소된 gang의 잔존 Pod/노드 수요 정리 |
| 노드 손실 | 재시도·작업 복구·용량 보충 동작 |

**통과 기준:** scheduler와 provisioner 사이의 상태 계약을 실제 이벤트로 확인하고, 확장 누락·과잉 확장이 없는 지원 조합을 정한다. 설치 성공을 통합 성공으로 취급하지 않는다. 연동이 맞지 않으면 원인을 분리하고 기본 scheduler baseline으로 복귀한다.

상세 스케줄링 분석은 연구 저장소에 두며 이 문서에는 검증된 버전과 통합 제약만 연결한다.

## 6. 단계 3 — Workload CR Operator

### 첫 API의 범위

API 이름/그룹은 아직 확정하지 않는다. 다음은 후보 필드이며 구현된 CRD 스키마가 아니다.

- image와 command/args
- GPU 수, CPU/memory requests/limits
- queue와 실행 timeout
- 병렬도/gang 크기 (필요한 경우)
- 재시도 정책과 결과 보존 기간

첫 단계는 공유 용량 기반으로 설계한다. CR마다 특정 VM을 직접 소유하는 모델은 별도 확장이다.

### Controller 계약

공유 `CloudEnvironment`를 참조하고 gateway/route 준비 이후에 하위 Job을 만든다. Environment controller는 별도 책임으로 gateway와 연결의 준비·유휴·회수를 관리한다. CR 이름/스키마는 아직 후보이며 상세 경계는 [gateway 설계](cloud-gateway-lifecycle.md)를 따른다.

- 유효하지 않은 요청과 허용 GPU/큐 범위 검증
- 하위 Job/Volcano Job/PodGroup의 명확한 소유권
- reconcile 재실행·controller 재시작에도 중복 생성하지 않는 동작
- Pending/Provisioning/Running/Succeeded/Failed 등 상태와 원인 보고
- 상태는 관측에 근거해 보고하며, Pending만으로 VM 생성 중이라고 단정하지 않음
- observedGeneration, Conditions, 하위 리소스 참조 등 추적 수단 검토
- 작업 취소·삭제, timeout, 실패, 이미지 pull 실패, GPU 부족 대응
- CR에 클라우드 자격 증명이나 가입 토큰을 직접 담지 않음

### 삭제와 VM 회수

```text
CR 삭제
  → 소유한 워크로드 중지·삭제
  → 해당 GPU 수요 제거
  → 다른 작업이 없고 정리 정책이 허용하면 Karpenter가 노드 회수
  → AWS 인스턴스 실제 종료 확인
```

CR 삭제 직후 VM 반환을 보장하지 않는다. 공유 노드의 다른 작업을 중단하지 않아야 하며 consolidation/disruption 정책, DaemonSet, PDB, 볼륨 등의 영향을 고려한다. Kubernetes Node 객체 삭제와 VM 종료는 동일하지 않다.

ownerReference로 해결되는 하위 리소스 정리에 불필요한 finalizer를 추가하지 않는다. 외부 결과 보존/자원 정리가 반드시 필요한 경우에만 finalizer를 사용하며 재시도·timeout·복구 경로를 설계한다. 공유 노드 전체의 종료를 CR finalizer 해제 조건으로 삼지 않는다.

### 통과 기준

정상 실행뿐 아니라 중복 reconcile, controller 재시작, 작업 실패/취소, provisioning 실패, 노드 손실, 삭제 도중 재시작을 검증한다. CR 소유 자원은 정리되고 무관한 워크로드는 유지되어야 한다. 상세 controller 설계·테스트는 구현 저장소에서 관리한다.

## 7. 비용·보안 가드레일

유료 실험 전에 사용자에게 아래 범위를 제시해 승인을 받는다.

- 계정/리전, 허용 인스턴스 종류, 최대 동시 노드/GPU 수
- 실험 시간과 예상 비용 범위, 중단 시각
- EC2 외 디스크, NAT, 공인 IP, 데이터 전송, 선택 시 관리형 control-plane 비용
- GPU 쿼터와 capacity 확보 가능성
- 최소 IAM 권한 및 임시 자격 증명/회수 방식
- 자원 태그와 실험 종료 후 고아 인스턴스/볼륨/네트워크 자원 확인 방법

NodePool limits와 예산 알림만으로 엄격한 결제 상한을 보장하지 않는다. 동시 프로비저닝이나 알림 지연도 고려해 작은 실험 단위, timeout, 직접 자원 조회를 결합한다. VM의 사용자 데이터/로그/이미지에 장기 관리자 자격 증명을 남기지 않는다.

## 8. 선언적 관리와 변경 단위

- AWS 네트워크/IAM 등: 적절한 IaC 도구로 별도 관리.
- Karpenter/Volcano/Operator 설치와 NodePool/NodeClass/실험 리소스: Helm/Kustomize 등으로 선언화.
- Argo CD가 준비되면 Kubernetes 리소스를 동기화할 수 있으나, Argo CD 도입 자체를 첫 CPU 검증의 필수 선행 조건으로 만들지 않는다.
- GitOps controller가 실험 중지 후 자원을 재생성하지 않도록 원하는 상태 변경과 수동 정리의 순서를 맞춘다.
- Vault 등 기존 인증 인프라의 변경과 GPU 실험을 하나의 PR에 섞지 않는다.

추천 변경 단위:

1. AWS provider/K3s 호환성 조사 및 실행 범위 승인
2. CPU bootstrap·네트워크·자원 정리 runbook/IaC
3. Karpenter CPU baseline
4. GPU 이미지/런타임와 NodePool 및 단일 작업
5. Volcano 설치·호환성 실험 선언
6. Operator 구현 저장소의 CRD/controller 및 인프라 배포 연동

각 단위는 설치 선언, 정상/실패 검증 기준, 롤백과 실제 실행 결과를 분리해 기록한다.

## 9. 후속 벤더 provider의 판단 기준

AWS에서 관측한 생명주기를 기준으로 GCP/OCI 구현과 비교하되, 새 벤더 개발은 현재 구현 범위에 포함하지 않는다.

가격 외에도 생성/삭제 API, GPU 가용성, 최소 과금, bootstrap/privileged 작업 가능성, 네트워크, custom image, VM 식별/고아 자원 회수 기능을 평가한다. 새 provider에는 VM 생성 API 호출뿐 아니라 자원 모델, 용량 정보, idempotency, 초기화 및 종료 계약이 필요하다. 코드 재사용 시 각 저장소의 라이선스/고지 의무를 확인한다.

## 검증 기록

초기 계획에 더해 단계 0의 소스 코드 수준 조사를 수행하고 별도 근거 문서에 버전·판정·제약을 기록했다. AWS 계정/쿼터·현재 클러스터 상태는 재조회하지 않았으며, Karpenter/Volcano 설치, GPU 실행, VM 종료 검증은 수행하지 않았다.
