# 보안 기반 원격 관리 구축 계획

## 상태와 승인 경계

사용자와 합의한 방향을 정리한 계획이다. [초기 조사](initial-assessment.md) 및 승인된 OpenClaw 중지는 에이전트가 수행했다. 이후 사용자는 CUPS 중지, Tailscale 설치·경로 설정·정책 적용 및 SSH/API 연결 성공을 보고했다. OIDC/RBAC 분리/Vault는 아직 계획이다. 사용자 요청에 따라 후속 서버 변경은 직접 실행할 명령을 안내하며 에이전트가 대신 실행하지 않는다. 유료 자원은 별도 승인 없이 생성하지 않는다. 위키는 생성하거나 수정하지 않는다.

## 목표와 위협

- 인터넷에서 관리 API/SSH로 직접 들어오는 공격: VPN과 호스트 방화벽으로 접근 제한.
- 공유 관리자 자격 증명 및 분실 기기: 개인별 OIDC 신원, MFA, 기기 제거, 최소 RBAC, 짧은 토큰 수명.
- 워크로드 침해의 확산: 전용 ServiceAccount, 최소 Vault policy, Pod Security 및 NetworkPolicy.
- Secret/키의 Git 유출: 실제 비밀 대신 참조·설정만 저장하고 변경 검토.
- 인증 서비스·호스트 장애: 독립된 비상 관리자와 로컬 콘솔, 외부 백업, 복원 검증.

같은 minipc의 root 침해나 장애는 K3s와 같은 호스트의 Vault/Dex에 영향을 준다. VPN이나 Vault만으로 이를 해소하지 않는다. namespace만으로 적대적 워크로드의 강한 격리를 보장하지 않는다.

## 선택 방향과 미결정 사항

| 영역 | 방향 | 구현 전 결정/검증 |
| --- | --- | --- |
| VPN | OS 수준 Tailscale 우선 | 현행 무료 약관·한도·필요 기능, 사용자/기기, 계정 복구, 접근 정책 |
| 사람 인증 | GitHub → Dex → Kubernetes OIDC | Dex 배치·저장소·HTTPS issuer·클라이언트 방식, GitHub 허용 대상과 claims |
| RBAC | 일상 조회/개발/운영과 비상 관리자 분리 | 사용자·그룹 prefix, namespace별 정확한 리소스/verb |
| Vault | minipc OS의 단일 노드 우선 | 저장소, TLS, 수동 unseal/auto-unseal, 암호화 외부 백업 |
| 워크로드 인증 | 전용 SA → Vault Kubernetes auth | reviewer 자격 증명 수명·갱신, audience, namespace/SA binding |
| 시크릿 전달 | Agent/CSI와 ESO 비교 | Kubernetes Secret 복제 여부, 갱신과 앱 reload, 장애 동작 |

Dex가 발급한 토큰을 Kubernetes가 검증한다. GitHub 비밀번호를 Kubernetes에 전달하지 않는다. OIDC kubeconfig에는 로그인 방법을 설정하고 공유 관리자 개인키를 넣지 않는다. 이미 발급된 토큰은 계정 차단만으로 즉시 무효화되지 않을 수 있다.

## 확정한 초기 접속 구성

아래는 최신 합의다. 사용자가 Windows/minipc 설치와 WSL에서의 VPN IP SSH, 기존 LAN IP 기반 SSH/API 연결 성공을 보고했다. 에이전트의 독립적인 외부망 검증은 수행하지 않았다.

- 관리 기기는 본인 Windows 노트북 한 대. Tailscale은 Windows에 설치하고 WSL에는 중복 설치하지 않는다.
- WSL은 기존 SSH 키와 kubectl 및 추후 OIDC 로그인 플러그인을 사용하는 관리 환경이다. Windows VPN 경로와 DNS 사용 가능 여부는 검증한다.
- 서버 측 초기 설치 대상은 minipc OS다. homelab-pi의 설정은 변경하지 않으며 기존 LAN 통신을 유지한다.
- minipc의 방화벽/API 변경이 worker에도 영향을 줄 수 있으므로 두 노드의 Ready 상태와 실제 통신을 변경 전후 점검한다.
- WSL 네트워크 모드는 우선 유지하고, VPN IP 연결 → DNS → API TLS → Windows 브라우저/WSL OIDC callback 순으로 확인한다. mirrored 모드 변경을 선행 조건으로 가정하지 않는다.
- VPN의 기기 신뢰 경계는 WSL만이 아니라 Windows 노트북 전체다. Windows 업데이트·화면 잠금·디스크 암호화·MFA 상태도 점검한다.
- 사용자는 minipc에 모니터·키보드로 직접 접속 가능하다고 확인했다. 실제 복구 실험은 아직 하지 않았으며 pi의 직접 콘솔 경로는 미확인이다.
- 기존 SSH config와 kubeconfig 주소를 유지하기 위해 minipc LAN IPv4 하나의 `/32` subnet route를 사용하도록 초기 계획을 변경했다. 집 LAN 전체를 광고하지 않는다.
- exit node와 Tailscale SSH는 사용하지 않는다. 기존 OpenSSH를 유지한다. 노트북에서 minipc VPN IP의 TCP 22 및 LAN IP의 TCP 22/6443을 허용하며 정책 템플릿과 적용 절차는 별도 관리한다.

## 단계와 통과 조건

### 0. 현황 조사와 복구 준비 (진행 중)

- 현재 신원·노드·권한 일부 확인 완료. SSH는 agent 등록 후 복구되었고 일반 사용자 수준 OS 점검을 수행했다.
- 사용자가 root 점검 결과를 제공했다: UFW inactive, CUPS 포트 소유, 기본 state.db 존재. datastore 확정과 백업/복원 검증은 미수행이다. minipc 로컬 콘솔은 사용자 보고로 확보되었다.
- Tailscale 설치의 선행 조건으로 K3s 중지·datastore 백업을 요구하지 않기로 조정했다. 백업은 별도 운영 과제이며 변경 종류에 맞는 롤백을 우선한다.
- 기존 접근을 제거하지 않음. 복구 가능성이 확인되지 않으면 차단 정책 적용을 진행하지 않음.

### 1. VPN

- 공식 가격표를 확인했고 사용자가 Windows/minipc에 설치했다. 기존 K3s 노드 통신 주소를 유지한다. 플랜 조건은 변경될 수 있으므로 추가 기능 사용 전 다시 확인한다.
- 사용자가 지정한 최초 관리 기기는 본인 노트북 한 대다. 필요한 대상/포트만 허용하며 추후 기기 추가는 별도 정책 검토를 거친다. LAN 및 IPv6 경로는 별도로 검토.
- 외부 핫스팟에서 허용 SSH 성공과 비허용 접근 실패를 각각 검증.
- 실패 시 기존 LAN 접속으로 정책/서비스를 되돌림. VPN 정상화 전 LAN 관리 경로 차단 금지.

### 2. API TLS와 사람 인증

- API는 subnet route를 통해 기존 LAN 주소를 유지하므로 VPN 주소용 TLS SAN을 추가하지 않는다. 기존 CA 검증을 유지하고 TLS 검증 우회는 금지한다.
- Dex/GitHub 연동, API issuer/audience/claim 검증, 로그인 플러그인 구성.
- 별도 OIDC context를 추가. 기존 관리자 자격 증명은 비상용으로 분리하되 검증 전 폐기하지 않음.
- 개인 신원을 `auth whoami`로 확인. 접근 허용 대상과 비허용 계정, issuer/audience 불일치의 거부 동작 검증.
- Dex 장애 시 비상 context로 복구 가능해야 함. 로그인 캐시/refresh token도 민감 정보로 보호.

### 3. RBAC와 워크로드 격리

- 조회용/개발용 권한을 테스트 namespace에 먼저 적용.
- `auth can-i`와 실제 제한된 신원의 요청을 모두 검사.
- Secret 조회, exec, Pod 생성, RBAC 수정, bind/escalate/impersonate의 위험을 검토.
- API가 불필요한 앱은 SA token 자동 마운트 비활성화.
- Pod Security는 영향 관측 후 enforce; NetworkPolicy는 CNI 지원 확인 후 DNS 등 필요한 통신부터 설계.
- 거부 기준: 조회 사용자의 삭제/Secret 조회 불가, 개발 사용자의 다른 namespace 접근 불가.
- 문제 발생 시 새 Binding/정책만 되돌리며 시스템 역할을 무작정 수정하지 않음.

### 4. Vault

- dev mode 금지, TLS 검증 유지, 인터넷 직접 공개 금지, 일상 root token 사용 금지.
- unseal 자료와 백업 해제 수단은 같은 호스트에만 두지 않음. root token 폐기/비상 재생성 절차 정의.
- 감사 로그 활성화 및 보호. 정적 KV Secret과 동적 자격 증명을 구분.
- 앱별 SA/role/policy로 시크릿 접근을 분리.
- 앱 A의 신원으로 앱 B의 시크릿 접근 실패, 토큰 만료/회수, 갱신, seal 이후 재기동, 외부 백업 복원을 검증.
- Vault 시작에 필수인 자격 증명을 Vault 안에서만 얻는 순환 의존성 금지.
- 두 물리 노드로 장애를 견디는 Raft HA가 된다고 가정하지 않음.

### 5. 운영 인수

- 기기 분실, OIDC/Vault 장애, 자격 증명 유출, 호스트 재부팅의 runbook 작성과 검증.
- 예상한 보안 효과와 실제 검증 결과, 남은 위험을 분리 기록.
- 완료 판정은 설치 성공이 아니라 허용/거부 테스트와 복구 테스트를 근거로 함.

## 저장소 관리 원칙

추후 단계별로 비밀을 제외한 VPN 정책, RBAC/SA/NetworkPolicy 매니페스트, OS 서비스 설정 템플릿과 검증 스크립트를 추가한다. 실제 개인키, 인증서, kubeconfig, OAuth client secret, Vault token/unseal 자료, K3s token, 평문 Secret, 원본 백업은 커밋하지 않는다. Git ignore만으로 유출 방지를 보장하지 않으므로 diff와 로그도 검토한다.
