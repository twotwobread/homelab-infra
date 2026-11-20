# Tailscale 정책 템플릿

## 출처와 상태

[정책 예제](../../network/tailscale/policy.hujson.example)는 2026-11-20 검증에 사용한 직접 연결 구성을 반영한다. 관리 노트북에서 Pi의 Tailscale 주소로 SSH 접속했고, 두 온프레미스 노드와 EC2 사이의 파드 HTTP 및 EC2의 클러스터 DNS를 확인했다. [검증 기록](../validation/k3s-seoul-ec2-vxlan.md)

이 템플릿은 기기 등록·경로 광고·경로 승인을 수행하지 않는다. placeholder가 남은 상태로는 적용할 수 없다. IP 주소 자체는 인증 비밀이 아니지만 환경 정보를 분리하고 재사용하기 위해 템플릿화했다.

## 허용 범위

| 출발지 | 목적지 | 허용 |
| --- | --- | --- |
| 관리 노트북, iPhone, iPad | minipc Tailscale IPv4 | TCP 22, 443, 6767, 8443, 8200 |
| 관리 노트북 | minipc LAN IPv4 | TCP 22, 6443 |
| 관리 노트북 | Pi Tailscale IPv4 | TCP 22 |
| iPhone, iPad, minipc | 관리 노트북 | TCP 22, 6767 |
| EC2 워커 태그 | minipc LAN IPv4 | TCP 6443, UDP 8472 |
| minipc Tailscale 및 LAN IPv4, Pi LAN IPv4, EC2 워커 태그 | EC2 워커 태그 | UDP 8472 |
| EC2 워커 태그 | Pi LAN IPv4 | UDP 8472 |

- `hosts`는 정책 내부의 주소 별칭이며 MagicDNS나 SSH config 설정이 아니다.
- Windows가 VPN을 담당하며 WSL은 그 경로로 접속한다.
- 기존 LAN 주소를 유지하기 위해 minipc가 자기 LAN IPv4의 `/32` 경로를 광고하고 관리 화면에서 승인해야 한다. 현재 사용자는 해당 구성의 연결 성공을 보고했다.
- Flannel은 온프레미스 노드의 LAN 주소를 사용한다. Pi도 자기 LAN 주소 한 개를 /32로 광고하고 승인한다. EC2는 승인된 경로를 수락한다. UDP 규칙은 실제 VXLAN 출발지와 목적지 주소에 맞춘다.
- 일반 LAN으로 직접 전달되는 트래픽은 이 정책의 통제 대상이 아니다.
- 같은 사용자 계정의 새 기기라도 지정 출발지 주소가 아니면 이 규칙으로 접근할 수 없다. 기기 삭제·재등록 시 주소 매핑을 확인한다.
- Tailscale SSH 정책은 없으며 기존 OpenSSH 인증을 사용한다.
- TCP 6443 접근 허용은 Kubernetes 인증/RBAC를 우회하지 않는다.

## 구성 재현과 롤백

다음은 사용자가 실행할 운영 절차다. 이 문서 작성 과정에서 서버 변경을 실행하지 않았다.

1. Windows에는 공식 Tailscale 클라이언트를 설치하고 개인 계정으로 로그인한다. WSL에는 중복 설치하지 않는다. https://tailscale.com/download/windows
2. minipc OS에는 배포판에 맞는 공식 패키지를 설치한다. 설치 명령은 공식 안내를 확인한다. https://tailscale.com/download/linux
3. 기존 LAN SSH로 minipc에 접속하여 등록한다. 로그인 URL과 인증 정보는 저장소나 채팅에 남기지 않는다.

```bash
# minipc에서 실행
sudo tailscale up
tailscale status
tailscale ip -4
```

4. 기존 LAN IP로 SSH/API를 사용하기 위해 한 주소만 광고한다. placeholder는 실제 LAN IPv4로 치환한다. 이 명령은 기존 광고 경로 목록을 설정하므로 다른 경로가 있으면 함께 검토한다.

```bash
sudo tailscale set --advertise-routes=<MINIPC_LAN_IPV4>/32
```

5. 관리 화면의 minipc 기기에서 해당 subnet route를 승인한다. Windows의 route 수락 상태와 WSL 도달성을 확인한다. Windows는 일반적으로 subnet route를 기본 수락한다.
6. 아래 정책을 적용한다. 기존 LAN IP를 사용하므로 SSH config와 kubeconfig endpoint, API TLS SAN을 VPN 전용으로 변경하지 않는다. kubeconfig의 로딩 방식과 context는 기존 환경에 맞춘다.

이번 경로의 목적지는 router 자신인 minipc의 LAN 주소다. 다른 LAN 장치로 forwarding하는 일반 subnet router 구성과 구분하며, IP forwarding sysctl을 변경했다고 주장하지 않는다. 추후 다른 호스트로 확장할 때는 forwarding·SNAT·방화벽을 별도 검토한다.

문제 발생 시 minipc의 로컬 콘솔 또는 유지 중인 LAN SSH에서 다음을 사용할 수 있다.

```bash
# 현재 설계처럼 광고 경로가 이 한 개뿐인 경우 광고 해제
sudo tailscale set --advertise-routes=

# 필요할 때만 VPN 연결 해제 (VPN SSH 세션은 끊어짐)
sudo tailscale down
```

관리 화면의 route 승인도 함께 정리한다. VPN을 내리면 WSL의 VPN 경로는 사용할 수 없으며 로컬 LAN/콘솔로 복구한다. Tailscale 문제를 이유로 K3s DB를 복원하거나 UFW를 임의로 활성화하지 않는다. 다른 LAN과 주소가 겹칠 수 있으므로 `/32`의 구체성만으로 모든 경로 충돌이 해결된다고 가정하지 않는다.

## 로컬 파일 준비

실행 위치: 관리 클라이언트의 `homelab-infra` 저장소 루트.

```bash
cp network/tailscale/policy.hujson.example network/tailscale/policy.local.hujson
```

로컬 파일에서 다음 값을 치환한다.

| Placeholder | 값 확인 위치 |
| --- | --- |
| `<ADMIN_LAPTOP_TAILSCALE_IPV4>` | Windows PowerShell의 `tailscale ip -4` |
| `<MINIPC_TAILSCALE_IPV4>` | minipc의 `tailscale ip -4` |
| `<MINIPC_LAN_IPV4>` | 기존 SSH/API가 사용하는 minipc LAN 주소 |
| `<PI_TAILSCALE_IPV4>` | Pi의 `tailscale ip -4` |
| `<PI_LAN_IPV4>` | Pi의 기존 LAN 주소 |
| `<IPHONE_TAILSCALE_IPV4>`, `<IPAD_TAILSCALE_IPV4>` | 각 기기의 Tailscale IPv4 |

`policy.local.hujson`은 Git에서 제외한다. 토큰·키·OAuth secret을 정책에 넣지 않는다. 기존 문서의 과거 조사에 있는 LAN 주소까지 소급 익명화한 것은 아니다.

## 적용 및 검증

1. 현재 관리 화면 정책을 별도 로컬 파일로 백업한다. 다른 정책이 추가되었다면 무조건 전체 교체하지 않는다.
2. 치환한 파일을 Tailscale Access controls에 입력한다. 기존 전체 허용 grant가 남아 있지 않은지 확인한다.
3. 관리 화면의 구문·정책 tests 검증을 통과한 뒤 저장한다. tests는 실제 패킷 전송 검증이 아니다.
4. 기존 LAN 세션을 유지하고 새 SSH 세션으로 VPN IP와 LAN IP 접근을 각각 확인한다.
5. 기존 kubeconfig/context로 API 접근 및 노드 상태를 확인한다. 다른 클러스터 context에 명령하지 않는다.
6. 외부 네트워크에서도 기존 LAN 주소 기반 SSH/API를 확인한다. 집 LAN에서의 성공만으로 subnet routing을 증명하지 않는다.
7. 필요하면 열려 있는 서비스의 비허용 포트도 연결 차단을 검증한다. 서비스가 꺼진 포트의 실패만으로 정책의 차단 효과를 판정하지 않는다.

일반 ICMP ping은 허용하지 않았으므로 실패할 수 있다. SSH와 API는 TCP로, VXLAN은 EC2와 각 온프레미스 노드 사이의 Pod IP 직접 HTTP 및 경로 확인으로 검증한다. 문제가 생기면 관리 화면에서 이전 정책으로 되돌릴 수 있지만, 전체 허용 정책으로 복구하는 경우 넓은 권한도 함께 복구됨을 유의한다.

공식 참고: https://tailscale.com/docs/reference/syntax/policy-file
