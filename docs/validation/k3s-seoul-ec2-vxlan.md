# 온프레미스 K3s와 서울 EC2 간 Flannel VXLAN 검증

2026-11-20(KST), 서울 리전의 단일 EC2 워커를 홈랩 K3s에 수동으로 연결했다. 워커는 K3s API(TCP 6443)에 접속해 클러스터에 조인했다. 조인 이후에도 노드 간 Pod IP 직접 HTTP 요청과 EC2 파드의 클러스터 DNS 조회가 실패했다. API 연결과 파드 데이터 경로를 각각 검증해야 했다.

## 목표와 설계 선택

평소에는 미니 PC와 Raspberry Pi가 있는 홈랩 K3s에서 워크로드를 실행한다. 온프레미스 용량이 부족할 때만 AWS 워커를 같은 클러스터에 추가하는 것이 목표다.

초기 계획은 AWS에 공유 게이트웨이를 두고 워커 트래픽을 라우팅하는 방식이었다. 이번 PoC에서는 추가 EC2 비용과 게이트웨이 운영을 줄이기 위해 워커가 Tailscale에 직접 등록하는 방식을 선택했다. 미니 PC와 Pi의 Flannel은 LAN 주소를 쓰고, EC2의 Flannel은 Tailscale 주소를 쓴다. 온프레미스 노드는 각자 자기 LAN 주소 한 개를 Tailscale 경로로 광고한다.

## 서울 EC2 워커 준비와 조인

서울 리전에 Ubuntu 24.04 ARM64 기반의 t4g.small CPU 워커 한 대를 띄웠다. 워커에 Tailscale을 설치하고 기기를 승인한 뒤, 워커 태그로 미니 PC의 LAN 주소에 있는 K3s API에 접근하도록 허용했다. 서버와 같은 버전의 K3s 에이전트를 단기 부트스트랩 토큰으로 등록했다. EC2에 테스트 전용 NoSchedule 테인트를 적용하고 테스트 파드에만 허용 조건을 넣었다. 노드가 Ready가 된 뒤 파드 데이터 경로를 검증했다.

| 노드 | 테스트 파드 | Flannel VXLAN에 사용한 노드 주소 |
| --- | --- | --- |
| 미니 PC `minipc` | `home` | 미니 PC LAN IP |
| 서울 EC2 `homelab-k3s-worker-poc` | `aws` | EC2 Tailscale IP |
| Raspberry Pi `homelab-pi` | `pi` | Pi LAN IP |

## 검증 방법

기존 테스트 namespace `ec2-join-check-0ce26f`에서 BusyBox HTTP 파드를 노드별로 하나씩 사용했다. `kubernetes.io/hostname` nodeSelector로 배치하고 파드가 Ready인지 확인했다. 진단과 수정 전후에 같은 파드를 사용해 상대 Pod IP의 TCP 8080에 직접 HTTP 요청을 보냈다. 응답 본문은 대상 파드 이름이었다.

미니 PC에서 대상 kubeconfig context와 namespace를 먼저 확인한다. 아래 예시는 당시 사용한 `default` context를 지정한다. `get pods -o wide`는 현재 Pod IP와 배치 노드를 표시하며, `wget -T 5 -qO-`는 5초 네트워크 타임아웃을 설정하고 응답 본문을 표준 출력에 쓴다.

```sh
kubectl config current-context
kubectl --context default -n ec2-join-check-0ce26f get pods -o wide

ns=ec2-join-check-0ce26f
pi_ip=$(kubectl --context default -n "$ns" get pod pi -o jsonpath='{.status.podIP}')
aws_ip=$(kubectl --context default -n "$ns" get pod aws -o jsonpath='{.status.podIP}')
kubectl --context default -n "$ns" exec pi -- wget -T 5 -qO- "http://$aws_ip:8080/"
kubectl --context default -n "$ns" exec aws -- wget -T 5 -qO- "http://$pi_ip:8080/"
```

수정 후 기대 응답은 순서대로 `aws`, `pi`다. 미니 PC ↔ EC2 검증에도 같은 방식으로 `home`과 `aws`를 사용했다.

## 미니 PC ↔ EC2

1. `home`과 `aws` 사이 HTTP는 양방향 모두 타임아웃이었고, `aws`의 클러스터 DNS 조회도 타임아웃이었다. 첫 Tailscale UDP 8472 grant를 적용한 뒤에도 실패했다.
2. 양단에서 패킷을 관찰했다. EC2에서 미니 PC LAN 주소로 보낸 VXLAN이 도착했고 미니 PC 파드의 TCP SYN-ACK도 확인했다. EC2 쪽에서는 미니 PC LAN 주소를 출발지로 쓰는 VXLAN이 보이지 않았다. 출발지 주소를 바꿔 UDP를 비교했을 때는 미니 PC의 Tailscale 주소를 사용한 패킷만 EC2에 도착했다.
3. EC2 워커를 대상으로 하는 UDP 8472 grant의 `src`에 `minipc-lan`을 추가했다. 이후 같은 `home`과 `aws` 사이의 HTTP가 양방향으로 성공했고, `aws`의 클러스터 DNS 조회도 성공했다. EC2의 `tailscale0`에서 미니 PC LAN 주소를 출발지로 쓰는 VXLAN도 확인했다.

## Raspberry Pi ↔ EC2

1. Pi에 Tailscale을 설치하고 부팅 시 시작하도록 활성화한 뒤 기기를 등록했다. 관리 노트북에서 Pi의 Tailscale 주소로 향하는 TCP 22 grant를 추가한 후 SSH에 성공했다.
2. Pi LAN → EC2 워커, EC2 워커 → Pi LAN 방향의 UDP 8472 grants를 적용한 뒤에도 `pi`와 `aws` 사이 HTTP는 양방향 모두 타임아웃이었다. 미니 PC에서 재시험했을 때 두 파드의 로컬 HTTP와 `home`에서 각 파드로 보낸 직접 HTTP는 정상 응답했다.
3. EC2의 경로 조회에서 Pi LAN 주소는 `ens5`, 미니 PC LAN 주소는 `tailscale0`으로 나갔다. Pi에서 자신의 LAN IP 한 개를 `/32`로 광고하고 사용자가 해당 경로를 승인했다. EC2에서 Pi LAN 주소로 향하는 경로가 `tailscale0`으로 전환됐고, 같은 `pi`와 `aws` 사이 HTTP가 양방향으로 성공했다.

## 최종 경로와 접근 정책

- 미니 PC와 Pi는 각각 자기 LAN 주소 한 개를 /32로 광고한다. 활성화된 경로를 EC2가 수락하면 각 LAN 주소가 EC2의 Tailscale 경로에 나타난다.
- UDP 8472는 미니 PC와 Pi의 실제 VXLAN 출발지인 LAN 주소에서 워커로, 워커에서 두 LAN 주소로 허용한다. 워커 태그를 붙인 EC2 사이에도 같은 UDP 포트를 허용하는 정책을 두었다. 워커 간 통신은 이번 시험에 포함하지 않았다.
- 워커에서 K3s API로 가는 TCP 6443과 관리 노트북에서 Pi로 가는 TCP 22는 별도의 접근 목적이다. 정책 허용 여부와 경로 설치 여부를 각각 점검한다.

## 검증 결과와 범위

| 항목 | 최종 결과 |
| --- | --- |
| 서울 EC2 워커의 K3s API TCP 6443 연결 및 수동 조인 | 성공 |
| 미니 PC ↔ EC2 Pod IP 직접 HTTP | 양방향 성공 |
| EC2 파드의 클러스터 DNS 조회 | 성공 |
| 관리 노트북 → Pi Tailscale 주소 SSH | 성공 |
| Pi ↔ EC2 Pod IP 직접 HTTP | 양방향 성공 |

PoC에서 Flannel 설정을 변경하지 않았다. 미니 PC 경로는 Tailscale grant에 VXLAN의 실제 출발지인 LAN 주소를 포함했을 때 복구됐고, Pi 경로는 UDP grants 적용 후 EC2가 Pi LAN 주소를 Tailscale로 라우팅했을 때 복구됐다. 결과는 수동 연결과 위 테스트 경로에 한정된다. Karpenter를 통한 워커 수명 주기 자동화와 GPU 워크로드는 검증 범위에서 제외했다.

관련 계획과 조사 자료는 [GPU autoscaling 로드맵](../plans/gpu-autoscaling-roadmap.md)과 [AWS provider의 K3s 호환성 조사](../plans/aws-provider-k3s-feasibility.md)에 있다.
