# Vault OIDC: Dex client 준비

## 상태와 범위

사용자는 Vault의 HTTPS health 응답(initialized=false, sealed=true, HTTP 501)을 제공한 뒤 UI에서 초기화/unseal을 수행했다고 보고했다. unseal 이후 health 출력이나 Vault OIDC 로그인 결과는 아직 확보하지 않았다.

이번 변경은 Dex의 Vault용 client 템플릿만 준비한다. 실제 secret 생성·Dex 재생성·Vault auth/role/policy 설정은 사용자가 별도로 수행한다. 기존 Kubernetes client와 GitHub OAuth App callback은 유지한다. Vault를 재시작하거나 다시 초기화하지 않는다.

## 두 종류의 client 구분

- GitHub OAuth App: Dex가 GitHub와 통신. 기존 GITHUB_CLIENT_ID/SECRET 및 Dex의 8443 callback 유지.
- Dex static client `homelab-vault`: Vault가 Dex와 통신. 별도 VAULT_OIDC_CLIENT_SECRET 사용.
- Vault callback은 `https://<VAULT_DNS_NAME>:8200/ui/vault/auth/oidc/oidc/callback`. Vault auth mount를 `oidc/`로 만들 것을 전제로 한다.
- `<VAULT_DNS_NAME>`은 Vault TLS 인증서의 DNS 이름이다. 현재 같은 minipc DNS를 사용하지만 Dex issuer는 8443, Vault UI는 8200으로 구분한다.
- `secretEnv`는 환경 변수 이름을 받으므로 `$` 접두사나 실제 secret을 YAML에 넣지 않는다.

## 내부 연결 선행 조건

사용자 확인에서 Vault 컨테이너의 Dex 8443 연결은 거절됐지만 호스트에서는 성공했다. Serve의 tailscale0 바인딩과 Docker bridge 경로 차이를 해결하기 위해 [공유 네트워크와 Dex 자체 HTTPS](oidc-backchannel.md)를 추가했다. 현재 Compose는 이 외부 네트워크와 Dex TLS 파일을 요구하므로 아래 재생성 전에 해당 준비를 완료한다. 새 경로의 실제 OIDC 로그인은 아직 미검증이다.

## 기존 배포 갱신

실행 위치: minipc 저장소의 `auth/dex/`. PR 머지 후 pull하더라도 Git에서 제외된 config.local.yaml/dex.env.local은 자동으로 변경되지 않는다. 템플릿으로 로컬 파일 전체를 덮어써 기존 설정과 자격 증명을 잃지 않는다.

1. `config.local.yaml`의 기존 staticClients 목록에 [템플릿](../../auth/dex/config.yaml.example)의 `homelab-vault` 항목을 추가한다. `staticClients:` 키를 중복 선언하지 않는다. 새 DNS placeholder를 치환한다.
2. 기존 `dex.env.local`에 새 secret을 생성한다. 아래 스크립트는 기존 비어 있지 않은 실제 값을 보존하며, 없거나 템플릿/빈 값이면 해당 항목만 생성한다. 값은 출력하지 않는다.

```bash
python3 - <<'PY'
from pathlib import Path
import os
import secrets
p = Path('dex.env.local')
if not p.is_file():
    raise SystemExit('먼저 기존 GitHub 자격 증명이 있는 dex.env.local을 준비하세요.')
key = 'VAULT_OIDC_CLIENT_SECRET='
lines = p.read_text().splitlines()
indices = [i for i, line in enumerate(lines) if line.startswith(key)]
if len(indices) > 1:
    raise SystemExit('중복된 Vault secret 항목을 먼저 정리하세요.')
if indices:
    value = lines[indices[0]][len(key):].strip()
    if value and not value.startswith('<'):
        os.chmod(p, 0o600)
        print('기존 Vault client secret 유지')
        raise SystemExit(0)
    lines[indices[0]] = key + secrets.token_hex(32)
else:
    lines.append(key + secrets.token_hex(32))
os.chmod(p, 0o600)
p.write_text('\n'.join(lines) + '\n')
print('Vault client secret 생성 완료 (값은 출력하지 않음)')
PY
```

생성한 값은 이후 Vault OIDC config에 동일하게 입력한다. token/secret을 채팅·Git·shell history에 남기지 않는다. 이 값은 정적 client secret이며 회전 시 Dex/Vault 양쪽을 함께 갱신해야 한다.

3. 환경 변수 변경을 반영하려면 restart가 아니라 컨테이너 재생성이 필요하다.

```bash
docker compose config --quiet
docker compose up -d --force-recreate dex
docker compose ps
docker compose exec -T dex sh -c 'test -n "$VAULT_OIDC_CLIENT_SECRET" && echo "Vault client secret: configured"'
```

secret 설정 여부만 확인하며 원문은 출력하지 않는다. 전체 `docker compose config`나 `docker inspect`를 공유하지 않는다. Dex 재시작 동안 OIDC 신규 로그인/갱신이 잠시 영향을 받을 수 있지만 Vault unseal 상태는 바뀌지 않는다.

4. minipc와 WSL에서 실제 Dex DNS 이름으로 검증한다.

```bash
curl --fail --silent --show-error https://<DEX_DNS_NAME>:8443/.well-known/openid-configuration
```

이는 client 로그인 검증이 아니라 discovery 경로 확인이다. 기존 kubectl OIDC도 정상인지 확인한다. 이전 토큰 캐시로 API 조회가 성공하는 것과 새 로그인 검증은 구분한다.

## 후속 Vault 설정

- 초기 root token을 bootstrap에만 사용하여 `oidc/` auth 활성화.
- Vault 컨테이너에서 Dex discovery/JWKS의 DNS/TLS 접근 확인. WSL에서의 성공만으로 컨테이너 접근을 가정하지 않는다.
- issuer `https://<DEX_DNS_NAME>:8443`, client ID `homelab-vault`, 생성한 secret 등록.
- Vault role의 bound_subject는 실제 Dex `sub`로 제한. Kubernetes가 붙인 `oidc:` 접두사는 제외한다. 사용자명이나 credential-id로 대체하지 않는다.
- Vault policy는 Kubernetes cluster-admin과 별개. 정확한 관리 권한과 TTL을 설계한다.
- Dex의 PKCE S256 강제 설정을 유지한다. Vault 로그인에서 호환 여부를 확인하며 오류가 나도 전역 PKCE 요구를 무조건 끄지 않는다.
- 성공 로그인, 다른 subject 거부, policy 권한, 비상 복구 경로를 확인한 뒤 초기 root token 폐기.

OIDC는 로그인 수단이며 수동 unseal을 대체하지 않는다. Vault auth/role/policy 변경은 일반적으로 Vault 재시작 없이 API로 적용한다.

## 되돌리기

Vault에서 사용하기 전이면 새 static client 항목과 env 항목만 제거하고 Dex를 재생성한다. 기존 kubectl client와 GitHub connector는 유지한다. Vault가 OIDC를 이미 사용한다면 먼저 별도 관리자 접근을 확인한다. Dex 데이터나 Vault 데이터는 삭제하지 않는다.

## 참고

- https://github.com/dexidp/dex/blob/v2.46.1/config.yaml.dist (`secretEnv`)
- https://developer.hashicorp.com/vault/docs/auth/jwt
