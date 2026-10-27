# Vault 단일 노드 bootstrap 계획

## 상태 및 실행 경계

설계·템플릿만 작성한 단계다. 이미지 pull, Compose 실행, TLS 연결, init/unseal, 시크릿 저장은 검증하지 않았다. 서버 작업은 사용자 실행 방식이다. 공유기 외부 노출 검증과 LAN 직접 관리 접근 제한은 보류했으며 완료로 기록하지 않는다.

최초 단계는 minipc OS의 Vault와 관리 노트북만 연결한다. Pod/ServiceAccount 인증, 외부 Secret 동기화, Vault OIDC 로그인, HA는 후속이다. 기존 Dex HTTPS 8443과 K3s API는 변경하지 않는다.

## 버전·라이선스와 신뢰 경계

조사 당시 공식 GitHub latest는 Vault v2.2.1이었다. [Compose](../../auth/vault/compose.yaml)에 명시했지만 이미지 태그 존재/실행은 서버에서 확인해야 한다. 태그는 digest 고정과 다르다. 라이선스는 BUSL-1.1이며 OSI 오픈소스 라이선스라고 표현하지 않는다. 현재 개인 홈랩의 내부 사용은 추가 사용 허용 범위에 해당하는 방향이지만 외부 경쟁 서비스 제공/상용 재배포는 별도 검토한다. Enterprise 라이선스나 유료 KMS는 초기 구성에 사용하지 않는다.

- minipc root/Docker 관리자 침해는 Vault에도 영향을 준다. 동일 호스트 설치는 독립적인 물리적 보안 경계가 아니다.
- 단일 노드 Raft는 HA가 아니다. minipc 장애 시 Vault를 사용할 수 없다.
- 서버 재시작 후 수동 unseal이 필요하다. unseal 키를 같은 서버 스크립트에 저장해 자동 입력하지 않는다.
- Vault 암호화는 unseal 후 호스트 침해를 모두 방어하지 않는다. 운영 토큰/로그/백업에도 접근 통제가 필요하다.

## 접속 구조

```text
관리 노트북 → Tailscale 정책 → minipc Tailscale IPv4:8200
                             → Docker 게시 포트
                             → Vault 자체 TLS listener
```

외부 주소는 `https://<MINIPC_TAILSCALE_DNS_NAME>:8200`. 기존 Tailscale HTTPS 인증서의 DNS 이름을 사용하지만 Serve/Funnel을 추가하지 않고 Vault가 직접 TLS를 종료한다. 443/8443을 재사용하지 않아 Dex/Traefik과 분리한다. Raft 내부 8201은 호스트에 게시하지 않는다.

Docker 게시 IP를 Tailscale IPv4 하나로 제한하고, Tailscale 정책에는 지정 노트북 → minipc VPN IP의 TCP 8200만 추가한다. 템플릿의 기존 정책은 이번 단계에서 변경하지 않았다. 적용 시 test의 accept에도 minipc:8200을 추가하고 미허용 기기의 거부를 검증한다. Docker NAT/FORWARD가 관여하므로 게시 IP만 보고 격리 완료로 주장하지 않는다. 외부 네트워크/비허용 기기 테스트를 별도로 수행한다.

같은 Compose 네트워크/호스트 관리자까지 차단하는 구성은 아니다. 컨테이너 내부 listener는 0.0.0.0이며 API에는 TLS와 Vault 인증이 적용된다. 앱을 같은 Docker 네트워크에 임의로 추가하지 않는다.

**Pod는 이 관리 경로를 자동으로 사용할 수 없다.** 후속 단계에서 LAN 제한 TLS listener 경로 또는 전용 VPN 프록시 등과 네트워크 정책을 별도로 설계한다. 관리 API를 편의상 0.0.0.0에 게시하지 않는다.

## 실행 전 확인 (minipc, 읽기 전용)

```bash
swapon --show
free -h
df -h /var/lib
sudo ss -lntp 'sport = :8200'
sudo ss -lntp 'sport = :8201'
tailscale cert --help
```

Raft 공식 문서는 disable_mlock=true와 시스템 swap 비활성화를 권장한다. 이 구성은 이를 따른다. swap이 활성화되어 있으면 실행을 중단하고 메모리 여유와 재부팅 후 지속 설정을 별도 검토한다. `swapoff -a`를 일괄 실행하도록 안내하지 않는다. Vault만의 방어 설정으로 호스트 swap 위험이 해소되었다고 주장하지 않는다.

## 파일 준비 및 이미지 확인 (사용자 승인 후)

실행 위치: clone한 저장소의 `auth/vault/`. 기존 파일은 덮어쓰지 않는다.

```bash
cp -n .env.example .env
cp -n vault.hcl.example vault.local.hcl
chmod 600 .env
chmod 644 vault.local.hcl
```

.env의 IP/DNS, HCL의 DNS를 편집기로 치환한다. 현재 버전의 공식 이미지 사용자 UID/GID는 숫자로 가정하지 않고 확인한다. 다음 명령은 이미지 다운로드와 일회성 컨테이너 생성이며 아직 Vault 서버나 init은 실행하지 않는다.

```bash
docker pull hashicorp/vault:2.2.1
docker run --rm --entrypoint /bin/sh hashicorp/vault:2.2.1 -c 'id vault; vault version'
```

UID/GID 확인 후 그 값으로 `/var/lib/homelab-vault/{raft,audit,scratch}` 디렉터리를 mode 0700으로 준비한다. Dockerfile에서 익명 볼륨을 선언한 경로도 bind mount로 덮어 데이터가 예상하지 않은 익명 볼륨에 남지 않게 한다. `user: vault`와 직접 바이너리 entrypoint로 non-root 실행하며 IPC_LOCK은 추가하지 않는다.

## TLS 준비 및 갱신 요구사항

현재 단계에서는 `tailscale cert`로 기기 DNS 이름의 인증서·키를 발급하고 `tls.local/server.crt`, `tls.local/server.key`로 보관하는 방안을 사용한다. 실제 발급 명령은 `tailscale cert --help`와 확인된 컨테이너 UID/GID에 맞춰 안내한다.

- `tls.local/`은 제한된 접근 권한, key는 Vault 사용자가 읽을 수 있는 최소 권한으로 설정. 공개 인증서는 private key와 구분한다.
- 인증서/키를 Git에 추가하지 않는다. Git ignore만으로 비밀 관리가 완료되는 것은 아니다.
- 기존 Dex Serve가 관리하는 인증서와 직접 발급한 파일을 혼동하지 않는다. **직접 발급한 파일의 자동 갱신/교체는 자동으로 완성되지 않는다.**
- 만료 모니터링, 제한된 권한의 갱신 작업, 키 권한 보존, Vault의 SIGHUP에 의한 TLS reload 및 갱신 검증을 후속 운영 작업으로 구현해야 한다. 자동화 전에는 실데이터 상시 운영 완료로 판단하지 않는다.
- 인증서 이름은 CT 공개 로그에 남을 수 있다. HTTPS는 비공개 인증서 이름을 보장하지 않는다.
- CA 신뢰 검증을 끄거나 HTTP로 대신 공개하지 않는다.

## 시작과 초기 상태 검증 (위 조건 충족 후)

```bash
docker compose config --quiet
docker compose up -d
docker compose ps
```

WSL에서 실제 DNS 이름으로 바꿔 실행한다. 초기 미초기화 상태에서는 HTTP 501이 정상일 수 있으므로 `curl --fail`을 사용하지 않는다.

```bash
curl --silent --show-error --max-time 10 \
  --write-out '\nHTTP %{http_code}\n' \
  https://<VAULT_DNS_NAME>:8200/v1/sys/health
```

기대: TLS 검증 성공, `initialized: false`, `sealed: true`. 이미 initialized=true라면 다시 init하지 말고 데이터 출처를 확인한다. 이후 sealed 상태 HTTP 503도 동작 의미를 구분한다. 정상 unsealed active 서버는 200이다. 자동 health restart로 sealed 상태를 반복 재시작시키지 않는다.

## 초기화는 별도 단계

**현재 PR은 init 명령을 자동 실행하지 않는다.** init은 비밀 자료를 생성하므로 보관 계획을 먼저 확정한다.

- Shamir shares 3 / threshold 2를 초기 검토안으로 한다. 모두 본인이 보관하면 다자 통제가 아니라 분실 대비 분산 보관이라는 한계가 있다.
- 평문 init 출력이 터미널 녹화/로그/채팅/Git에 남지 않도록 보호된 로컬 경로 또는 PGP 암호화 출력을 선택한다.
- 최소 두 share를 복구할 수 있도록 서로 다른 보호 장소에 보관하고 minipc 자체를 유일한 보관 장소로 삼지 않는다.
- 초기 root token도 비밀이다. unseal key와 로그인 토큰은 다르다.
- unseal 키를 명령행 인자로 넣지 않고 숨김 프롬프트를 사용한다.
- root로 감사 로깅과 최소 관리 정책·인증을 구성하고 대체 관리 경로를 검증한 뒤 초기 root token을 revoke한다. 먼저 폐기해서 관리 접근을 잃지 않는다.
- vault login의 기본 token helper는 파일에 토큰을 저장할 수 있으므로 명시적으로 저장 방식과 세션 후 정리를 선택한다.

## 초기화 후 학습·운영 검증

1. audit file device를 `/vault/logs/audit.json`에 활성화하고 권한/용량을 관리한다. 감사 장치 쓰기 실패가 서비스 요청에 영향을 줄 수 있다. 로그 원문을 공유하지 않는다.
2. KV v2를 `kv/`에 만들고 비민감 테스트 값만 저장한다.
3. [learning-reader policy](../../auth/vault/policies/learning-reader.hcl)를 적용하고 짧은 TTL의 제한 토큰으로 `kv/learning/demo` 읽기 성공, 다른 경로 읽기 실패, 쓰기 실패를 확인한다.
4. 해당 토큰을 revoke하고 접근 실패를 확인한다. root token으로 제한 policy를 시험하지 않는다.
5. 재시작 후 sealed 상태와 수동 unseal을 검증한다.
6. Raft snapshot을 보호된 외부 장소에 보관하고 격리된 환경에서 복원을 검증한다. 실행 중 Raft 파일 단순 복사로 대체하지 않는다. snapshot과 unseal 자료의 보관을 분리한다.
7. 이후 Kubernetes auth TokenReview 자격 증명/갱신, SA/namespace/audience 제한을 설계한다. Vault 정책과 Kubernetes RBAC는 별개다.

## 롤백

초기화 전이라도 실제 데이터 유무를 확인하고 `docker compose stop`으로 중지한다. 데이터를 삭제하지 않는다. 추가했던 Tailscale 8200 grant만 제거하며 Dex 8443과 SSH/API 규칙은 유지한다. init 후에는 중지/재시작에 unseal이 필요하고, 이미지 다운그레이드의 저장소 호환성을 가정하지 않는다.

## 공식 근거

- https://github.com/hashicorp/vault/releases/tag/v2.2.1
- https://github.com/hashicorp/vault/blob/v2.2.1/LICENSE
- https://github.com/hashicorp/vault/blob/v2.2.1/Dockerfile
- https://developer.hashicorp.com/vault/docs/configuration/storage/raft
- https://developer.hashicorp.com/vault/docs/configuration/listener/tcp
- https://tailscale.com/kb/1153/enabling-https
