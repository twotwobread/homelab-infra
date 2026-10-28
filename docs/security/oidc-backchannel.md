# Dex–Vault 내부 TLS 네트워크

## 근거와 상태

사용자 제공 결과에서 minipc 호스트는 Dex HTTPS 8443 discovery에 접근하지만 Vault 컨테이너는 같은 IP에 Connection refused였다. `ss`는 tailscaled의 `100.x.x.x%tailscale0:8443` 리스너를 표시했고 Vault는 Docker bridge 주소를 사용했다. DNS 해석 실패가 아니라 인터페이스에 묶인 Serve 수신 경로와 Docker bridge 경로의 차이를 가리킨다. 별도 패킷 캡처로 모든 방화벽 거절 가능성을 배제한 것은 아니다.

이 문서의 새 구성은 템플릿/정적 검사 단계이며 적용 및 로그인 성공은 아직 검증하지 않았다. 운영 명령은 사용자가 실행한다. Vault는 이미 초기화/unseal했다고 보고했으므로 다시 init하지 않는다.

## 설계

```text
브라우저/호스트 → MagicDNS → Tailscale IP:8443 → Serve → Dex HTTP:5556
Vault 컨테이너 → Docker DNS alias → Dex 컨테이너:8443 → Dex 자체 TLS
```

두 경로는 동일한 HTTPS issuer를 사용한다. GitHub OAuth callback, Vault OIDC discovery URL, Kubernetes issuer/kubeconfig는 바꾸지 않는다. HTTPS 인증서는 원래 issuer hostname을 검증하며 TLS 우회를 사용하지 않는다.

- 외부 공유 네트워크 `homelab-oidc-backchannel`을 `--internal`로 만들고 두 Compose 프로젝트가 참조한다. 이 네트워크를 다른 앱과 공유하지 않는다.
- 각 컨테이너는 기존 default 네트워크도 유지한다. default의 gw_priority=1로 외부 연결 기본 경로를 유지하며 새 내부 네트워크는 인터넷 egress를 제공하지 않는다. Compose 2.33.1 이상 필요, 사용자 환경은 5.1.0 보고.
- Dex의 alias는 issuer DNS 이름이다. 컨테이너 IP를 고정하거나 hosts 파일에 직접 기록하지 않는다. 중복 alias를 부여하지 않는다.
- Dex의 HTTPS 8443은 Docker 호스트에 게시하지 않는다. 기존 host loopback 5556은 Serve용으로 유지한다.
- 공유 네트워크는 포트별 ACL이 아니다. 두 컨테이너는 해당 네트워크의 서로 다른 리스너에도 도달할 수 있다. 신뢰하지 않는 앱을 추가하지 않으며 이 구성만으로 마이크로세그멘테이션 완료를 주장하지 않는다.
- Vault listener에도 TLS/인증이 유지된다. Raft 8201은 host에 게시하지 않지만 공유 네트워크에서의 도달 가능성은 별도 경계다.

### 같은 DNS 이름의 주의점

alias는 포트별이 아니다. Vault 컨테이너 안에서 같은 DNS 이름의 8200 요청도 Dex IP로 해석될 수 있다. 따라서 Vault CLI 환경 변수는 `VAULT_ADDR=https://127.0.0.1:8200`, `VAULT_TLS_SERVER_NAME=<Vault DNS 이름>`으로 변경한다. 연결 대상만 loopback이고 인증서 이름 검증은 유지된다. 이 환경 변수는 Vault CLI용이며 서버의 `api_addr`, OIDC issuer, 브라우저 callback은 변경하지 않는다. WSL/브라우저/호스트의 DNS에는 alias가 적용되지 않는다. 다른 내부 클라이언트를 나중에 추가하면 같은 이름 문제를 재검토한다.

## 적용 전 준비

1. 현재 Dex/Vault Compose 및 로컬 config를 제한된 경로에 백업한다. 실제 secret을 Git에 추가하지 않는다.
2. 기존 관리자 Kubernetes 접근을 유지하고, Vault unseal share 임계 개수를 사용할 수 있는지 확인한다.
3. 이미지 UID/GID: Dex 1001:1001, Vault는 기존 확인값 유지. Vault 데이터 경로를 변경하거나 삭제하지 않는다.
4. 새 Compose를 pull한 뒤 아래 네트워크·인증서·로컬 config 준비가 끝나기 전 `up`을 실행하지 않는다.

## 1. 네트워크 (minipc)

```bash
docker network ls --filter name=homelab-oidc-backchannel
```

없을 때만 생성한다.

```bash
docker network create --driver bridge --internal homelab-oidc-backchannel
```

```bash
docker network inspect homelab-oidc-backchannel --format 'Driver={{.Driver}} Internal={{.Internal}}'
```

기대 bridge/true. 기존 다른 네트워크를 임의 삭제하지 않는다.

## 2. Dex 로컬 설정과 TLS

실행 위치: 저장소의 `auth/dex/`.

```bash
cp -n .env.example .env
chmod 600 .env
```

.env의 DEX_DNS_NAME에 실제 issuer hostname을 입력한다. 이것은 Compose 보간용으로, 기존 dex.env.local의 GitHub/Vault client secret과 별개다.

`config.local.yaml`의 기존 web 블록에 템플릿의 https/tlsCert/tlsKey 세 항목을 병합한다. HTTP 5556, issuer 8443, 기존 staticClients/connector는 유지한다.

Dex만 읽는 별도 인증서 파일을 만든다. Vault tls.local의 소유권을 바꾸거나 그 경로를 공유하지 않는다. 아래는 최초 준비용이며 기존 인증서 갱신 작업에는 별도 운영 절차를 사용한다.

```bash
sudo install -d -m 0700 -o root -g root tls.local
# placeholder를 실제 issuer DNS 이름으로 교체
sudo tailscale cert --cert-file="$PWD/tls.local/server.crt" --key-file="$PWD/tls.local/server.key" <DEX_DNS_NAME>
sudo chown 1001:1001 tls.local tls.local/server.crt tls.local/server.key
sudo chmod 0700 tls.local
sudo chmod 0644 tls.local/server.crt
sudo chmod 0600 tls.local/server.key
sudo openssl x509 -in tls.local/server.crt -noout -dates -ext subjectAltName
```

새 키를 무조건 생성한다는 의미는 아니며 Tailscale이 같은 이름의 인증서를 재사용할 수 있다. 파일 접근 경로/권한을 분리한다. 직접 발급한 파일은 자동 갱신이 완료된 구성이 아니다. 만료 감시, 재발급, 권한 유지, Dex에 반영하는 절차가 필요하다. Serve의 자동 인증서 관리가 이 파일을 자동으로 갱신한다고 가정하지 않는다.

## 3. Dex 재생성 및 기존 경로 확인

`auth/dex/`에서:

```bash
docker compose config --quiet
docker compose up -d --force-recreate dex
docker compose ps
```

minipc 및 WSL에서 실제 hostname으로 discovery를 확인한다.

```bash
curl --fail --silent --show-error https://<DEX_DNS_NAME>:8443/.well-known/openid-configuration
```

로그인/갱신은 잠시 중단될 수 있다. 새 8443 호스트 포트 매핑은 추가하지 않는다. 기존 Kubernetes OIDC 경로도 유지되는지 확인한다.

## 4. Vault 네트워크 반영

`auth/vault/`에서 기존 .env와 데이터 경로를 유지하고:

```bash
docker compose config --quiet
docker compose up -d --force-recreate vault
docker compose ps
```

이 재시작 후 수동 unseal이 필요하다. UI에서 **기존의 서로 다른 share 두 개**로 해제한다. 초기화/새 Raft 생성은 반복하지 않는다. 토큰/키 원문은 공유하지 않는다.

## 5. 검증

`auth/vault/`에서 실제 hostname으로 치환:

```bash
docker compose exec -T vault sh -c 'nslookup <DEX_DNS_NAME>'
docker compose exec -T vault sh -c 'wget -qO- -T 10 https://<DEX_DNS_NAME>:8443/.well-known/openid-configuration'
docker compose exec -T vault sh -c 'wget -qO- -T 10 https://<DEX_DNS_NAME>:8443/keys'
docker compose exec -T vault vault status
```

- 내부 DNS 결과가 Dex의 공유 네트워크 IP와 일치하는지 inspect의 선택 필드와 대조한다.
- discovery issuer는 기존 HTTPS 이름/8443과 같아야 한다. JWKS는 공개키이며 개인키가 아니다.
- TLS 검증을 끄지 않는다. 컨테이너의 로컬 Vault CLI가 다른 Dex IP로 가지 않고 이름 검증을 유지하며 status를 읽는지 확인한다.
- 재시작 후 Vault는 initialized=true/sealed=true일 수 있다. unseal 후 sealed=false여야 한다. status는 sealed일 때 exit code 2를 반환할 수 있다.
- WSL에서 Vault의 기존 HTTPS 8200 접근도 계속 성공해야 한다.
- 마지막으로 [Vault OIDC 절차](vault-oidc.md)의 auth/role/policy와 실제 브라우저 로그인을 검증한다. discovery 성공만으로 로그인 완료라 하지 않는다.

## 롤백

새 TLS/네트워크 준비 실패 시 즉시 데이터 삭제로 해결하려 하지 않는다. 저장한 이전 Compose와 로컬 설정으로 되돌리고 해당 서비스를 재생성한다. Vault 재생성 후에는 다시 unseal한다. 네트워크는 연결된 컨테이너가 없어진 뒤에만 제거한다. 이전 구성으로 롤백하면 기존 사용자 경로는 복구할 수 있지만 Vault → Dex 내부 접근 문제는 다시 남는다. root token은 대체 관리 인증 검증 전에 폐기하지 않는다.

## 참고

- https://docs.docker.com/compose/how-tos/networking/
- https://docs.docker.com/reference/compose-file/services/#gw_priority
- https://github.com/dexidp/dex/blob/v2.46.1/examples/config-dev.yaml
- https://developer.hashicorp.com/vault/docs/commands (VAULT_ADDR, VAULT_TLS_SERVER_NAME)
