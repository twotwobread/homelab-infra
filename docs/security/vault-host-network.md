# Vault host network 전환

## 결정과 근거

사용자는 별도 사전 host-network 테스트를 생략하고 전환하기로 결정했다. minipc 호스트의 Dex 8443 discovery 요청은 성공, 기존 bridge Vault 컨테이너에서는 Connection refused였고 Serve의 tailscale0 바인딩을 확인했다. 같은 호스트 네트워크를 사용해 기존 성공 경로를 활용하려는 선택이다. 적용 후의 실제 동작은 아직 미검증이다. 정확한 bridge 거절 경로를 패킷 캡처로 확정한 것은 아니다.

공유 Docker network alias 및 Dex 내부 TLS안(PR #8)은 이 전환안에 포함하지 않는다. Dex/Serve/issuer/GitHub callback은 변경하지 않는다. 인증서 자동 갱신을 이 작업에서 구현하지 않으며, **Vault 자체 TLS 파일의 갱신 책임은 여전히 남는다.**

## 변경 범위

- Vault Compose: ports 매핑 제거, network_mode: host.
- HCL API listener: minipc Tailscale IPv4:8200으로 제한.
- HCL cluster listener: 127.0.0.1:8201 (단일 노드 전용).
- TLS 활성화, api_addr DNS, cluster_addr loopback, Raft 데이터 경로, node_id는 유지.
- non-root, read-only rootfs, capability 제거, no-new-privileges 유지. Docker 소켓을 추가하지 않는다.
- host network에서는 호스트 localhost 서비스 접근이 가능해진다. 완전한 호스트 root 권한을 자동으로 부여하는 것은 아니다.
- IP 바인딩은 인터페이스별 방화벽 정책과 같지 않다. Vault 인증과 TLS, Tailscale 정책을 유지하고 LAN/IPv6 등 모든 우회 경로를 차단 완료했다고 주장하지 않는다.

## 적용 절차 (사용자가 minipc에서 실행)

이 문서는 기존 초기화된 Vault 배포를 전환하는 절차다. unseal에 필요한 기존 share를 확보한다. `operator init` 반복, Raft 데이터 삭제, docker compose down -v는 하지 않는다. Vault 재생성 중 API를 사용할 수 없다.

### 1. pull 전 기존 구성 백업

저장소의 auth/vault에서 실행한다. 백업에는 환경 정보가 있으므로 root 전용으로 보관한다.

```bash
BACKUP="/root/vault-network-backups/$(date +%Y%m%d-%H%M%S)"
sudo install -d -m 0700 "$BACKUP"
sudo install -m 0600 compose.yaml "$BACKUP/compose.yaml"
sudo install -m 0600 vault.local.hcl "$BACKUP/vault.local.hcl"
printf 'Backup: %s\n' "$BACKUP"
```

`.env`, TLS 파일과 데이터는 그대로 둔다. 위 명령은 설정 롤백용이며 Raft 데이터 백업이 아니다. 이미 새 Compose를 pull했다면 이전 bridge Compose는 이 변경 전 Git revision에서 별도로 확보해야 한다.

### 2. PR 머지 후 develop 갱신 및 로컬 HCL 수정

저장소 루트에서 기존 변경을 확인하고 develop을 fast-forward로 갱신한 뒤 auth/vault로 돌아온다. 로컬 HCL은 Git 제외 대상이므로 pull로 수정되지 않는다.

```bash
tailscale ip -4
vim vault.local.hcl
```

`listener "tcp"` 안의 두 줄만 실제 주소로 수정한다.

```hcl
address         = "<현재 minipc의 Tailscale IPv4>:8200"
cluster_address = "127.0.0.1:8201"
```

HCL에 .env의 `${VAULT_BIND_IP}`를 넣지 않는다. TLS 파일 경로, tls_disable=false, api_addr, storage, node_id 등 나머지는 유지한다. `.env`의 VAULT_DNS_NAME은 유지하고 이전 VAULT_BIND_IP는 새 Compose에서 사용하지 않으므로 제거해도 된다. 롤백 시에는 이전 ports 매핑이 이를 요구한다.

**기존 0.0.0.0 listener를 수정하기 전에는 컨테이너를 재생성하지 않는다.**

### 3. 재생성

```bash
docker compose config --quiet
docker compose up -d --force-recreate vault
docker compose ps
```

Compose config 검사는 HCL의 유효성 검사가 아니다. 실패 시 제한된 로그를 확인하고 민감 값을 제거한 오류만 공유한다.

```bash
docker compose logs --tail=50 vault
```

host mode에서는 ps에 기존 포트 매핑이 표시되지 않는 것이 정상이다. 실제 리스너를 확인한다.

```bash
sudo ss -lntp 'sport = :8200'
sudo ss -lntp 'sport = :8201'
```

API는 지정한 Tailscale IPv4에서만, cluster는 loopback에서만 리스닝해야 한다. cluster listener가 sealed 상태에서 아직 시작되지 않았다면 unseal 후 다시 확인한다. 예상치 않은 wildcard 리스너가 있으면 서비스를 중지하고 설정을 재검토한다.

### 4. 기존 share로 unseal 및 접근 확인

브라우저의 기존 Vault HTTPS UI에서 서로 다른 기존 share 두 개로 unseal한다. initialized=false로 보이면 init하지 말고 볼륨/데이터 경로를 확인한다.

WSL에서:

```bash
curl --silent --show-error --max-time 10 --write-out '\nHTTP %{http_code}\n' https://<VAULT_DNS_NAME>:8200/v1/sys/health
```

unseal 후 initialized=true, sealed=false, HTTP 200 확인. minipc auth/vault에서:

```bash
docker compose exec -T vault sh -c 'wget -qO- -T 10 https://<DEX_DNS_NAME>:8443/.well-known/openid-configuration'
```

TLS 검증 우회 없이 성공해야 한다. 네트워크 namespace는 공유하지만 컨테이너 파일시스템과 resolver 설정은 별개이므로 DNS 문제는 여전히 별도로 확인한다. 다음으로 Vault OIDC 설정/로그인 절차를 진행한다. 외부에서 host의 Tailscale 주소가 아직 올라오기 전에 컨테이너가 시작되면 바인딩 실패할 수 있으므로 재부팅 시 서비스 순서/재시작도 검증한다.

## 롤백

저장한 bridge Compose와 HCL을 작업 디렉터리에 복원한다. 이전 Compose의 VAULT_BIND_IP에 실제 Tailscale IP를 .env에서 다시 설정한다. 원래 HCL의 HTTP/TLS를 임의로 완화하지 않는다. 같은 Compose 프로젝트 이름과 데이터 경로를 유지하여 `docker compose up -d --force-recreate vault`로 복구하고 기존 share로 unseal한다. 롤백 시에도 init을 반복하지 않는다. 이전 bridge에서는 Vault→Dex 접근 실패가 다시 남는다.
