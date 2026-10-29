# 단계 0 조사: AWS Karpenter provider와 홈랩 K3s

## 결론

**소스/문서 조사 결과: upstream AWS provider를 수정하지 않고 Custom AMI/bootstrap으로 CPU PoC를 시도할 근거가 있다. EKS 전환이나 새 provider 개발을 선행하지 않는다.**

단, 이는 K3s 통합 지원 인증이나 실행 성공 판정이 아니다. 네트워크, 자격 증명, 실제 NodeClaim 등록/초기화/종료는 CPU PoC에서 검증한다. 단계 0의 정적 조사를 완료하고 단계 1A 준비로 진행할 것을 제안한다. 유료 자원 생성은 별도 승인이 필요하다.

## 조사 기준

- AWS provider: stable release `v1.15.1`, commit `2b6449d0a2d8eec32df41b36eb292e76359dfe1e`.
- Karpenter core: `v1.15.1`, commit `8fb3abde2be3111cd26e0c0f45ac0babdeb8e9c0`. Provider go.mod의 의존성과 맞춰 조회했다.
- K3s: 과거 사용자 보고 버전 `v1.36.5+k3s1`의 cloudprovider/agent 소스. 현재 서버 버전은 재조회하지 않았다.
- 저장소의 `hosts/minipc/k3s/config.yaml.example`는 LAN node-ip/advertise-address 및 TLS SAN 템플릿이다. 실행 중 설정이나 CNI의 증거로 취급하지 않는다.
- README만 보는 것이 아니라 operator 초기화, AMI/bootstrap, NodeClass 검증, providerID, core 등록/초기화, K3s CCM의 관련 분기를 읽었다. 컴파일/통합 테스트와 AWS API 호출은 수행하지 않았다.

## 1. EKS 의존성을 우회하는 명시적 경로

| 확인 항목 | 소스에서 확인한 동작 | 적용 판단 |
| --- | --- | --- |
| Cluster endpoint | 옵션이 있으면 그대로 반환, 없을 때 EKS DescribeCluster | 접근 가능한 K3s endpoint를 명시 |
| Kubernetes version | EKSControlPlane=false이면 Kubernetes discovery 사용 | false 유지 |
| CA | 명시 옵션 또는 controller REST config의 CA 사용 | K3s CA와 worker의 신뢰 검증을 정합하게 구성 |
| Region | AWS SDK 설정이 비어 있으면 EC2 IMDS 조회 | 온프레미스 controller에 AWS_REGION 명시 |
| Credentials | AWS SDK 기본 credential chain 사용, 기동 중 EC2 연결 검사 | IRSA/EKS Pod Identity를 자동 사용할 수 있다고 가정하지 않음 |
| AL2023 CIDR | AL2023 family만 EKS Cluster CIDR 조회 분기 실행 | Custom family 사용, EKS nodeadm 경로 미사용 |
| Zonal shift | 활성화 시 EKS 조회/ARC 경로 진입 | 초기 PoC에서는 비활성화 |
| Instance profile | NodeClass는 role 또는 instanceProfile 필요 | 최소 권한의 사전 생성 profile을 우선 검토 |

AWS provider의 clusterName과 EKS 이름 형식의 리소스 태그를 사용한다는 것 자체가 EKS 클러스터 실재 요구는 아니다. 반대로 위 우회 경로가 있다는 이유로 모든 선택 기능의 EKS 의존성이 없다고 주장하지 않는다.

**근거:** [operator 초기화/endpoint/CA](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/pkg/operator/operator.go), [version provider](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/pkg/providers/version/version.go), [NodeClass validation](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/pkg/controllers/nodeclass/validation.go), [chart values](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/charts/karpenter/values.yaml).

## 2. 버전 판정

선택한 release 소스에 포함된 compatibility matrix는 Kubernetes 1.36에 Karpenter >=1.13을 명시한다. v1.15.1 version provider의 허용 범위에도 1.36이 포함된다. 그러므로 과거 보고된 K3s minor는 정적 버전 검사에서 배제되지 않는다.

이 표는 K3s distribution, CNI, custom image, Volcano와의 통합을 보장하지 않는다. 설치 직전 서버 버전을 확인하고 chart/CRD/controller를 같은 release로 고정한다. `latest`나 main 이미지를 실행 기준으로 사용하지 않는다.

근거: [compatibility](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/website/content/en/docs/upgrading/compatibility.md), [provider go.mod](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/go.mod).

## 3. Custom bootstrap은 자동 EKS bootstrap을 완전히 대체한다

`amiFamily: Custom`은 userData를 자동 생성/merge하지 않고 전달한다. NodeClass의 kubelet 설정이 실제 K3s kubelet에 자동 적용되는 것도 아니다.

CPU PoC bootstrap의 책임:

1. 승인된 OS/AMI 및 고정 K3s 버전 준비.
2. EC2 IMDSv2에서 인스턴스 ID/AZ 등 비밀이 아닌 메타데이터 확보.
3. 사설 연결을 먼저 구성하고 K3s endpoint/CA 검증.
4. 보호된 경로에서 worker 전용 가입 자격 증명 획득.
5. K3s agent 설정에 providerID, 등록 taint, 적절한 node-ip/이름과 CNI 경로 반영.
6. NodeClass가 가정한 maxPods/예약 자원/스토리지와 실제 kubelet 설정 정합 확인.
7. 실패 시 무한 재시작·인스턴스 누적을 탐지하고 회수.

NodeClass에 AMI를 명시적으로 선택하고 EKS 최적화 AMI alias를 그대로 K3s 이미지라고 간주하지 않는다. 첫 실험은 GPU 없는 x86_64 CPU 이미지와 하나의 인스턴스 종류로 제한한다. userData/Git/콘솔 로그에 가입 토큰과 VPN 키를 평문으로 넣지 않는다.

근거: [Custom family 구현](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/pkg/providers/amifamily/custom.go), [Custom bootstrap](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/pkg/providers/amifamily/bootstrap/custom.go), [Custom userData 문서](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/website/content/en/docs/concepts/nodeclasses.md#custom).

## 4. 가장 중요한 가입 계약: providerID와 taint

### providerID

AWS provider는 NodeClaim.status.providerID를 다음 형식으로 만든다.

```text
aws:///<availability-zone>/<instance-id>
```

K3s embedded CCM은 기본적으로 `k3s://<node-name>`을 제공하지만, Node.spec.providerID가 이미 설정되어 있으면 이를 보존한다. 따라서 kubelet의 provider-id를 최초 등록부터 AWS 형식으로 설정하는 경로를 PoC에서 검증한다. K3s agent는 `--kubelet-arg` 전달을 지원한다.

**기본 CCM이 무조건 AWS ID를 덮어쓴다고 가정하거나, 이 이유만으로 기존 클러스터 CCM을 전역 비활성화하지 않는다.** 최초 등록 시 ID 반영과 CCM reconciliation 이후의 보존 여부를 확인한다. 기존 minipc/pi Node를 Karpenter 소유로 바꾸지 않는다.

### 등록 taint

Custom bootstrap은 아래 taint가 있는 상태로 노드를 등록해야 한다.

```text
karpenter.sh/unregistered:NoExecute
```

Core registration은 이를 확인하고 소유권/등록 처리 과정에서 제거한다. K3s의 node-taint/kubelet 설정을 이용하되 실제 등록 순간부터 적용되는지 검증한다. 원래 용도의 workload taint 및 startup taint와 구분한다.

### GPU 초기화

Core initialization은 Registered, Node Ready, startup taint 제거, 요청된 자원의 등록 등을 확인한다. GPU 초기화 taint를 쓴다면 누가 제거하는지 정의하고 device plugin/GPU 초기화 DaemonSet이 관련 taint를 toleration하도록 한다. Node Ready만으로 GPU 준비 완료라 보고하지 않는다.

근거: [AWS providerID/삭제](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/pkg/cloudprovider/cloudprovider.go), [core registration](https://github.com/kubernetes-sigs/karpenter/blob/v1.15.1/pkg/controllers/nodeclaim/lifecycle/registration.go), [core initialization](https://github.com/kubernetes-sigs/karpenter/blob/v1.15.1/pkg/controllers/nodeclaim/lifecycle/initialization.go), [K3s CCM](https://github.com/k3s-io/k3s/blob/v1.36.5%2Bk3s1/pkg/cloudprovider/instances.go), [K3s agent 옵션](https://github.com/k3s-io/k3s/blob/v1.36.5%2Bk3s1/pkg/cli/cmds/agent.go).

## 5. 네트워크는 provider와 별도인 핵심 gate

현재 관리용 minipc /32 subnet route는 control-plane의 한 주소를 가리키는 접근 경로이지, cloud worker와 모든 기존 노드/Pod의 양방향 연결을 자동 제공하지 않는다. 과거 노트북 접속 검증을 EC2 worker 네트워크 검증으로 대체하지 않는다.

CPU PoC 전 읽기 전용으로 확인할 항목:

- 실제 CNI/backend, Pod/Service CIDR, Node InternalIP 및 인터페이스.
- API endpoint의 TLS SAN 및 EC2에서 검증 가능한 접속 이름/주소.
- kubelet 통신, 노드 간 encapsulation/Pod 통신, DNS·MTU.
- minipc뿐 아니라 pi에 배치된 Pod까지 오갈 수 있는 경로.
- VPN 기기의 생성·삭제, route 승인·접근 정책, 부팅 시 등록 지연.

후보는 Tailscale 기반 사설 연결이다. 그러나 **EC2에 Tailscale만 설치하면 해결된다고 확정하지 않는다.** 노드별 Tailscale 주소를 underlay로 쓰는 방식은 기존 Node IP/CNI 설정 변경을 요구할 수 있다. LAN↔VPC 경로를 만드는 방식은 route·SNAT·반대 방향의 도달성을 검증해야 한다.

이 단계에서 기존 클러스터를 전역 재설정하거나 6443/10250/CNI 포트를 인터넷 전체에 열지 않는다. 정확한 backend와 route를 확인한 뒤 작은 네트워크 변경안으로 승인받는다. K3s native VPN 옵션도 존재하지만 기존 노드 전환 영향과 실제 구성을 읽지 않은 상태에서 채택하지 않는다.

## 6. 자격 증명 설계

서로 다른 세 종류를 분리한다.

| 자격 증명 | 소비자 | 제약 |
| --- | --- | --- |
| AWS provisioning 권한 | minipc 쪽 Karpenter controller | AWS SDK가 사용할 자격 증명 공급 필요. EKS 전용 방식 전제 금지 |
| EC2 instance profile | 새 worker | bootstrap에 필요한 최소 자원만 접근; controller 전체 권한 재사용 금지 |
| K3s 가입/VPN 등록 자격 증명 | bootstrap | 접근 범위·수명·로그 노출·재발급·삭제 정의 |

임시 AWS credential 공급 또는 제한된 실험 credential의 안전한 주입 방식을 별도 선택한다. 자동으로 AssumeRole을 호출하려면 그 호출의 최초 신원도 필요하다. Vault가 이미 존재한다고 자동으로 AWS dynamic credential/노드 bootstrap이 구성된 것은 아니다.

Bootstrap secret의 후보 공급처로 제한된 SSM Parameter Store/Secrets Manager 접근을 검토할 수 있지만 이번에 채택/생성하지 않는다. 토큰을 controller가 EC2 userData에 직접 치환하는 방법을 기본안으로 삼지 않는다. server 관리자 토큰 대신 실제 지원되는 worker 가입용 자격 증명을 선정하고 새 VM 침해 시 클러스터 가입 위험을 평가한다.

## 7. 회수 경로와 외부 잔존 자원

AWS CloudProvider.Delete는 providerID에서 인스턴스 ID를 해석해 instance provider의 삭제 경로로 전달하며, instance provider는 EC2 TerminateInstances를 사용한다. 코드에 삭제 경로가 존재한다는 것과 IAM/실제 API가 성공한다는 것은 다르다.

PoC에서 확인할 잔존 대상:

- EC2 종료 상태, root/data EBS의 DeleteOnTermination 및 잔존 volume.
- NodeClaim/Node finalizer와 종료 지연.
- Tailscale 기기 레코드·등록 자격 증명.
- K3s 노드 비밀번호 Secret 등 재가입 관련 자원.
- 실험 전용 네트워크/IP/launch template 등의 소유권과 정리 주체.

Karpenter가 Tailscale 기기나 모든 외부 bootstrap 자원까지 자동 삭제한다고 가정하지 않는다. Bootstrap/cleanup 구현 범위에 포함한다. Controller와 IAM은 정상 회수가 끝날 때까지 유지한다.

근거: [instance provider 삭제](https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/pkg/providers/instance/instance.go).

## 8. 업데이트된 실행 계획과 승인 지점

### 다음 변경 A — 비용 없는 bootstrap/네트워크 설계

1. 사용자가 현재 K3s 버전/CNI/Node IP/route를 읽기 전용으로 확인.
2. AWS 계정·리전·가용 쿼터 및 CPU 단일 인스턴스 실험 예산 선정.
3. AWS controller credential, EC2 profile, 가입/VPN credential 공급 방식 확정.
4. 네트워크 변경 범위와 OS/AMI·bootstrap·정리 스크립트 템플릿 작성.
5. 비밀 유출 검사와 사용자 리뷰. 실제 secret은 Git 밖에 둔다.

### 다음 변경 B — 승인된 단일 CPU PoC

1. 한 대의 수동 EC2로 bootstrap·양방향 통신·정리를 검증. 이 성공은 아직 Karpenter 성공이 아님.
2. 동일 bootstrap과 provider v1.15.1을 사용해 NodeClass/NodePool 구성.
3. 기본 scheduler의 단일 CPU Pending Pod로 생성 유도.
4. NodeClaim Launched/Registered/Initialized, Node providerID와 소유권을 확인.
5. Pod 실행 및 다른 노드와 DNS/통신 검증.
6. 수요 제거 → 정상 노드 회수 → EC2 종료 → VPN/부수 자원 정리 검증.
7. 가입 실패/중단 시 과잉 생성 방지와 직접 회수 경로 확인.

### GPU/Volcano/Operator로 넘어가는 기준

위 생명주기가 반복 가능해야 GPU 이미지와 device plugin을 추가한다. 이후 Volcano와 Operator는 [전체 로드맵](gpu-autoscaling-roadmap.md)의 순서를 유지한다.

### 조사로 해결한 것과 남은 것

| 항목 | 결과 |
| --- | --- |
| EKS가 반드시 필요한가? | 주요 초기화/Custom bootstrap 경로에 비-EKS 구성이 존재함을 소스로 확인 |
| 기존 provider를 바로 fork해야 하는가? | 현재 발견한 조건만으로는 필요 없음. upstream + custom bootstrap 우선 |
| K3s가 AWS providerID를 무조건 덮어쓰는가? | 읽은 CCM 소스는 기존 ID를 보존함 |
| 버전이 명백히 배제되는가? | 보고된 1.36은 선택한 provider의 허용 범위 |
| 지금 바로 자동 가입이 보장되는가? | 아니오. 실제 네트워크/credential/등록/회수 PoC 필요 |
| GPU 가격·쿼터가 확보되었는가? | 미조회. 공급량과 예산은 실행 승인 전 확인 |
| 실행 완료인가? | 아니오. 정적 조사만 완료 |
