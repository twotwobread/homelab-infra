# 보안 구축 초기 조사

## 범위와 근거

- 관측 시각: 2026-10-27 07:29 UTC (실행 환경 시계 기준).
- 대상: `homelab` context / `homelab-k3s`, 기본 namespace `default`. 목록 조사에만 명시적으로 전체 namespace 사용.
- 로컬 kubeconfig를 명시하여 Kubernetes API의 읽기 작업과 SelfSubjectReview/SelfSubjectAccessReview를 수행했다. 운영 리소스 설정 변경은 하지 않았다.
- 인증서의 subject/issuer/유효기간만 추출했다. 개인키, 토큰, 인증서 원문 및 Secret 값은 수집·저장하지 않았다.
- 이 문서는 초기 관측이며 전체 보안 감사나 외부 침투 검증이 아니다.

## 확인된 상태

| 항목 | 결과 |
| --- | --- |
| API | `https://172.30.1.70:6443`, CA 설정 있음, TLS 검증 비활성화 아님 |
| 현재 신원 | 인증서 CN 및 `auth whoami`: `system:admin` |
| 현재 그룹 | 인증서 O: `system:masters`; API 응답에 `system:authenticated`도 포함 |
| 인증서 유효기간 | 2026-10-26 04:51:21 ~ 2027-10-26 04:51:21 UTC |
| 광범위한 권한 검사 | `auth can-i '*' '*' --all-namespaces`: yes |
| minipc | Ready, control-plane, 172.30.1.70, Ubuntu 24.04.3, amd64 |
| homelab-pi | Ready, 명시적 role label 없음, 172.30.1.71, Debian 13, arm64 |
| 버전 | 서버 v1.36.5+k3s1, 로컬 kubectl v1.37.1 |
| namespace | default, kube-node-lease, kube-public, kube-system |
| NetworkPolicy | 전체 namespace 조회 결과 없음 |
| Pod Security labels | 현재 namespace에 `pod-security.kubernetes.io/*` label 없음 |
| 시스템 워크로드 | CoreDNS, local-path-provisioner, metrics-server, Traefik Deployment 및 Traefik ServiceLB DaemonSet 확인 |
| Traefik Service | LoadBalancer, 노드 IP 두 개 표시, 80/443 및 NodePort 31685/30837 |

Pod Security label 부재만으로 admission 기본 정책이 없다고 단정할 수 없다. NetworkPolicy 목록만으로 CNI의 정책 지원·실제 통신 격리 여부를 판정할 수 없다. Service의 주소·포트 선언만으로 인터넷 노출 여부를 판정할 수 없다.

## 우선 검토할 권한

현재 인증서는 `system:masters` 소속이다. 이 그룹은 일반 RBAC 권한 회수로 통제할 일상 사용자 그룹이 아니며, Kubernetes의 특권 그룹이다. 해당 kubeconfig를 공유하지 않고 일상용 OIDC 신원과 분리해야 한다. Binding을 삭제하는 것만으로 이 인증서를 안전하게 폐기할 수 있다고 가정하지 않는다. 인증서 유출 시 CA 관련 대응까지 별도 계획해야 한다.

선택적으로 조회한 ClusterRoleBinding 중 다음이 `cluster-admin`을 참조한다.

- `cluster-admin`: `system:masters` 그룹
- `helm-kube-system-traefik`: `kube-system/helm-traefik` ServiceAccount
- `helm-kube-system-traefik-crd`: `kube-system/helm-traefik-crd` ServiceAccount

Helm 관련 권한은 K3s 애드온 관리의 의존성을 먼저 확인한다. 발견만으로 침해라고 판단하거나 즉시 삭제하지 않는다. 전체 역할 규칙 및 모든 ServiceAccount 토큰 사용 방식은 아직 감사하지 않았다.

## 최초 조사 당시 접근 제한 및 미확인 항목

아래 SSH 실패는 최초 조사 결과다. 이후 agent 등록으로 접속이 복구되었으며 후속 조사 결과는 문서 마지막에 기록한다.

- 두 호스트 모두 `BatchMode=yes`, `StrictHostKeyChecking=yes` SSH 시도에서 `Permission denied (publickey)` 발생.
- 호스트 키 검증을 끄거나 비밀번호·키 설정을 변경하지 않았다.
- 따라서 OS 방화벽, 리스닝 포트, 서비스, K3s 실행 설정, datastore 종류, 백업, 디스크 암호화 상태는 미확인이다.
- 공유기 WAN/CGNAT, 포트포워딩, UPnP, IPv6 외부 노출도 미확인이다.
- 기본 `~/.kube/config`는 context 이름만 지정하며 연결 설정은 별도 파일에 있다. 조사 명령은 파일을 명시했다. 사용자 셸의 자동 병합 방식은 미확인이다.
- VPN/Dex/Vault 설치 여부는 이번 조사만으로 확정하지 않는다. Kubernetes 목록에 없더라도 OS나 다른 환경에 존재할 수 있다.

## 다음 조사

1. 사용자의 정상 SSH 세션과 현재 실행 환경의 agent/key 접근 차이를 확인한다. 개인키 전달이나 평문 추출은 요청하지 않는다.
2. SSH 복구 후 OS 네트워크·방화벽·K3s 설정을 필요한 필드만 추출하여 조사한다. 원본 config, 환경 변수, 프로세스 인자에는 토큰이 있을 수 있어 통째로 출력하지 않는다.
3. 로컬 콘솔과 백업 복구 경로를 확보한다.
4. 공유기와 외부 네트워크 관점의 노출을 확인한다.

## 재검증 명령

실행 위치는 관리 클라이언트다. 아래 명령은 Secret 값을 출력하지 않으며 운영 설정을 변경하지 않는다. context와 namespace를 고정하고 요청 timeout을 설정한다.

```bash
K="$HOME/.kube/contexts/minipc-k3s.yaml"
kubectl --kubeconfig="$K" --context=homelab --namespace=default --request-timeout=10s auth whoami
kubectl --kubeconfig="$K" --context=homelab --namespace=default --request-timeout=10s auth can-i '*' '*' --all-namespaces
kubectl --kubeconfig="$K" --context=homelab --namespace=default --request-timeout=10s get nodes -o wide
kubectl --kubeconfig="$K" --context=homelab --namespace=default --request-timeout=10s get networkpolicies -A
```

관측 당시 예상 결과는 위 표와 같다. 이후 OIDC 검증은 별도 context에서 수행하며, 관리자 context의 결과를 제한된 사용자의 권한 증거로 사용하지 않는다.

## 후속 OS 조사: SSH 접근 복구

2026-10-27 07:36 UTC 이후, 사용자가 현재 agent에 키를 등록한 뒤 두 서버의 SSH 공개키 인증이 성공했다. `BatchMode=yes`, `StrictHostKeyChecking=yes`를 유지했으며 원격 설정을 변경하지 않았다.

- `minipc`: `k3s.service` active. `homelab-pi`: `k3s-agent.service` active.
- 두 서버 모두 `tailscaled`, `vault`, `dex`라는 system service는 `not-found`. 다른 이름·컨테이너·사용자 서비스로 실행 중인지까지 확인한 것은 아니다.
- 두 서버 모두 `sudo -n true`가 `a password is required`로 실패. 방화벽 root 규칙, K3s datastore 및 백업은 아직 미확인이다. 비밀번호 수집이나 sudoers 변경은 하지 않았다.
- 두 서버의 기본 IPv4 게이트웨이는 `172.30.1.254`; minipc는 `wlp2s0`, pi는 `wlan0`를 사용한다.
- minipc는 global scope IPv6 주소가 1개, pi는 0개다. scope global에는 ULA도 포함될 수 있으므로 공인 IPv6 또는 인터넷 도달성을 뜻하지 않는다.
- `lsblk` 결과 minipc 루트는 LVM 위 ext4, pi 루트는 SD 카드 ext4다. 표시된 계층에 dm-crypt는 없으나 이를 모든 저장 데이터의 암호화 부재로 일반화하지 않는다.

### 리스닝 포트 관측

| 호스트 | 관측 |
| --- | --- |
| 공통 | TCP 22 IPv4/IPv6 wildcard, TCP 10250 wildcard, UDP 8472 IPv4 wildcard |
| minipc | TCP 6443 wildcard, TCP 631 IPv4/IPv6 wildcard, TCP 18789 IPv4 wildcard |
| minipc 18789 | 일반 사용자에게 보이는 프로세스 이름 `openclaw-gatewa` |

이는 소켓 바인딩 결과이며 방화벽 통과나 외부 접근 성공의 증거가 아니다. TCP 631의 실제 소유 프로세스는 root 권한으로 추가 확인해야 한다. 두 서버의 UDP 8472와 kubelet 10250은 노드 간 통신 요구사항을 고려해 제한하고 인터넷에 공개하지 않아야 한다. minipc의 18789 서비스는 사용자에게 용도와 필요한 접근 범위를 확인한 뒤 검토한다. 서비스 중단·바인딩 변경은 하지 않았다.

### 남은 진행 조건

1. 사용자가 직접 sudo를 수행하는 읽기 전용 점검 또는 명령별로 제한된 승인 방식 결정. 광범위한 `NOPASSWD: ALL`은 요구하지 않는다.
2. 공유기 WAN/포트포워딩/UPnP/IPv6 방화벽과 로컬 콘솔·백업 복구 경로 확인.
3. 사용자가 VPN 관리 기기는 우선 본인 노트북 한 대로 지정했다. 추후 추가 기기는 별도 승인·정책 검토 대상으로 한다.

## 사용자 제공 root 점검 결과

후속 대화에서 사용자가 minipc에서 직접 실행한 결과를 제공했다. 에이전트가 root로 재실행한 검증은 아니다.

- `sudo ufw status verbose`: inactive. UFW 비활성화이며 다른 nftables/iptables/K3s 규칙까지 없다는 의미는 아니다.
- `sudo ss -lntup`: TCP 631의 소유자는 `cupsd`, IPv4/IPv6 wildcard 바인딩. SSH 22, K3s API 6443 및 kubelet 10250 리스너 확인. OpenClaw 18789/18792는 출력에 없음.
- 기본 경로에서 `server/db/state.db` 존재, `server/db/etcd` 및 `server/db/snapshots` 부재. SQLite 사용의 강한 단서이나 실행 설정과 함께 확정해야 한다. 외부/사용자 지정 경로 백업 유무는 미확인.
- 사용자는 공유기 설정을 별도로 변경한 적이 없다고 보고했다. 포트포워딩/DMZ/UPnP/IPv6 방화벽 목록 자체를 확인한 것은 아니므로 외부 노출 여부는 여전히 미확인으로 유지한다.
- 다음 확인: 인쇄 서비스 필요성, 공유기 실제 규칙, datastore에 맞는 백업과 서버 token의 별도 보호·복원 절차. UFW는 아직 활성화하지 않는다.

## 사용자 수행 CUPS 정리 및 VPN 연결 보고

- 사용자는 포트 631의 소유 unit을 `snap.cups.cupsd.service`로 확인했다. 일반 `cups.service`/`cups-browsed.service`를 중지하려던 명령은 unit 부재로 실패했다.
- 이후 사용자 제공 결과에서 `cups.cupsd`, `cups.cups-browsed`가 disabled/inactive, TCP 631 리스너 없음, K3s active를 확인했다. 서버 변경은 사용자가 수행했다.
- 사용자는 Windows와 minipc에 Tailscale을 설치하고 WSL에서 VPN IP 기반 SSH·ping 성공을 보고했다. 이후 최소 정책에서는 ICMP를 허용하지 않으므로 초기 ping 결과를 최종 정책의 결과로 혼동하지 않는다.
- 기존 config 유지 요구로 minipc LAN IP의 `/32` subnet route를 도입했고, 사용자는 기존 LAN 주소 기반 SSH/API 연결 성공 및 실제 정책을 제공했다.
- 최종 정책과 적용 방법은 [Tailscale 정책 문서](tailscale-policy.md)를 기준으로 한다. 외부 핫스팟 검증 여부와 비허용 트래픽의 실측은 별도 확인이 필요하다.

## 승인된 변경: OpenClaw 중지

- 사용자 확인: OpenClaw는 불필요하며 내려도 됨.
- 2026-10-27 07:46 UTC, minipc의 사용자 systemd unit `openclaw-gateway.service`가 active/enabled이고 TCP 18789 및 loopback 18792의 소유 프로세스임을 확인했다.
- `systemctl --user disable --now openclaw-gateway.service` 실행. 이후 inactive/dead/disabled 및 두 TCP 리스너 부재 확인. `k3s`는 계속 active.
- 프로그램·설정·데이터는 삭제하지 않았다. 공유기나 방화벽 규칙은 변경하지 않았다.
- 실행 위치: minipc의 nika 사용자 세션. 롤백이 필요하면 `systemctl --user enable --now openclaw-gateway.service`를 실행할 수 있으나, 기존 wildcard 바인딩도 복구될 수 있으므로 재활성화 전 접근 정책을 검토한다.
- 변경 전 `0.0.0.0:18789` 바인딩은 모든 로컬 IPv4 인터페이스에서 수신 가능하다는 의미이며, 인터넷 노출의 증거는 아니다. 공유기 NAT/포트포워딩/UPnP 및 호스트 방화벽이 미확인이라 과거 외부 접근 여부와 침해 여부는 판정하지 않았다.
