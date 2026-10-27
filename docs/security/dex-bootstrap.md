# Dex + GitHub OIDC: VPN 전용 서비스 준비

## 상태와 범위

이 문서는 아직 실행 검증되지 않은 구성 및 사용자 실행 절차다. 서버 작업은 사용자가 직접 수행한다. K3s 인증 변경과 RBAC 부여는 후속 단계다.

사용자 제공 결과: Tailscale 1.104.2, Serve/Funnel 설정 없음, MagicDNS/HTTPS 활성화, Docker 29.3.0 및 Compose v5.1.0, Docker active. `docker info`에 AppArmor/seccomp/cgroupns 표시. 이는 Dex 컨테이너 동작 검증을 의미하지 않는다. GitHub OAuth App 등록 완료 보고를 받았다. 조직 없이 개인 신원 기반 RBAC로 진행한다.

## 설계

- `https://<DEX_DNS_NAME>`를 issuer로 고정한다. GitHub OAuth callback은 같은 주소의 `/callback`이다.
- Tailscale Serve가 VPN에서 HTTPS를 제공하고 `http://127.0.0.1:5556`으로 전달한다. Funnel은 사용하지 않는다.
- [Compose](../../auth/dex/compose.yaml)는 Dex v2.46.1을 명시한다. 태그는 digest 고정과 동일하지 않으며 공급망 검증 완료를 의미하지 않는다.
- 이미지의 공식 Dockerfile에서 UID/GID 1001을 확인했다. 직접 dex 바이너리를 실행하여 이미지 entrypoint의 설정 템플릿 처리를 거치지 않는다.
- 프로세스 non-root, read-only rootfs, 모든 capability 제거, no-new-privileges. SQLite는 `/var/lib/homelab-dex`에 영속화한다.
- host loopback에만 HTTP 포트를 게시한다. 컨테이너 내부에서는 0.0.0.0에 바인딩되므로 Docker 호스트/root 및 컨테이너 네트워크까지 격리된 것은 아니다. 같은 Compose 네트워크에 불필요한 컨테이너를 추가하지 않는다.
- GitHub secret은 Git 밖 root 전용 env 파일에 보관한다. Docker 환경 변수로 전달하므로 Docker 관리자/root에게는 보일 수 있다. Docker 소켓 접근 권한을 최소화하고 `docker inspect`, 전체 `docker compose config`, 원본 로그를 공유하지 않는다.
- GitHub connector는 org 제한이 없다. 로그인 가능한 GitHub 계정과 K8s 업무 권한은 다르다. 최종 권한은 정확한 OIDC subject에 RBAC로 부여한다. 변경 가능한 username 대신 기본 내부 GitHub ID 사용을 유지한다.
- public OIDC client `homelab-kubectl`은 PKCE S256을 필수로 한다. 이후 로그인 플러그인도 PKCE S256과 `http://localhost:8000` callback에 맞춰야 한다. GitHub → Dex callback과 Dex → kubectl callback을 혼동하지 않는다.
- ID token 10분, refresh token 미사용 24시간/절대 168시간으로 제한한다. 로그인 계정 차단이 이미 발급된 토큰의 즉시 폐기를 뜻하지 않는다.

## 사용자 실행 절차

### 1. 파일 배치 (minipc)

PR을 `develop`에 머지한 후 minipc에서 저장소를 가져온다. 아래 clone 명령은 대상 디렉터리가 아직 없는 경우에만 실행한다.

```bash
git clone --branch develop https://github.com/twotwobread/homelab-infra.git
cd homelab-infra/auth/dex
```

이미 clone했다면 기존 작업 변경을 확인한 뒤 `develop`을 fast-forward로 갱신하고 `auth/dex/`로 이동한다. 아래 파일 배치 명령은 **저장소의 `auth/dex/` 디렉터리에서** 실행한다. 실제 secret은 저장소가 아닌 `/opt/homelab-dex/`에 직접 입력한다.

```bash
sudo install -d -m 0750 -o root -g root /opt/homelab-dex
sudo install -d -m 0700 -o 1001 -g 1001 /var/lib/homelab-dex
sudo install -m 0644 compose.yaml /opt/homelab-dex/compose.yaml
sudo install -m 0644 config.yaml.example /opt/homelab-dex/config.local.yaml
sudo install -m 0600 dex.env.example /opt/homelab-dex/dex.env.local
sudoedit /opt/homelab-dex/config.local.yaml
sudoedit /opt/homelab-dex/dex.env.local
```

기존 배포가 있는 경우 위 install 명령으로 설정을 덮어쓰지 않는다. config의 `<DEX_DNS_NAME>` 두 곳을 확정한 기기 FQDN으로 바꾼다. env에는 OAuth App Client ID와 Client secret을 입력한다. `format: raw`이므로 따옴표 없이 실제 값을 넣는다. shell 명령에 secret을 직접 넣어 history에 남기지 않는다.

### 2. 실행 및 localhost 검증 (minipc)

```bash
cd /opt/homelab-dex
sudo docker compose config --quiet
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
curl --fail --silent --show-error http://127.0.0.1:5556/.well-known/openid-configuration
```

마지막 응답의 issuer가 확정한 HTTPS 주소인지 확인한다. discovery에는 토큰이나 개인키가 없다. 실패하면 제한된 로그를 로컬에서 확인하고 민감 값을 제거한 오류만 공유한다. `config --quiet`는 Compose 구문 검증이지 Dex schema/실행 검증이 아니다.

### 3. Tailscale 정책과 HTTPS

[기존 정책](tailscale-policy.md)의 minipc VPN IP 목적지 grant에 `tcp:443`, 해당 test의 accept에 `minipc:443`을 추가한다. LAN 목적지에는 443을 추가하지 않는다. 기존 전체 허용 규칙이 없어야 한다.

기존 Serve/Funnel 설정이 여전히 비어 있는지 확인하고 minipc에서 실행한다.

```bash
tailscale serve status
tailscale funnel status
sudo tailscale serve --bg --https=443 http://127.0.0.1:5556
tailscale serve status
tailscale funnel status
```

HTTPS 활성화 확인 URL이 나오면 관리자 화면에서 승인한다. Funnel 명령으로 공개를 활성화하지 않는다. Serve 상태에 tailnet 전용 접속 주소가 표시되는지 확인한다. Funnel status가 Serve와 관련된 정보를 출력하더라도 제목만으로 공개 여부를 판단하지 말고 Funnel 활성 여부를 확인한다.

### 4. WSL 및 API 서버 호스트에서 검증

placeholder를 실제 기기 FQDN으로 바꿔 WSL과 minipc 양쪽에서 실행한다.

```bash
curl --fail --silent --show-error https://<DEX_DNS_NAME>/.well-known/openid-configuration
```

`-k`를 사용하지 않는다. 양쪽에서 DNS/TLS/issuer 검증이 통과해야 한다. 이것은 로그인 성공 검증이 아니다. 브라우저 OAuth 흐름, Windows/WSL localhost callback, API 서버의 issuer/JWKS 접근 및 실제 RBAC 검증은 후속으로 수행한다.

## 되돌리기

이 문서의 Serve 443 하나만 새로 설정했을 때 minipc에서:

```bash
sudo tailscale serve --https=443 off
cd /opt/homelab-dex
sudo docker compose stop
```

기존 다른 Serve 설정은 제거하지 않는다. 필요한 경우 정책의 새 443 허용만 되돌린다. SQLite 및 config/secret 파일은 삭제하지 않는다. 현재 단계는 K3s 설정을 변경하지 않는다. 데이터 백업을 만들면 키/토큰 상태가 포함될 수 있으므로 암호화·접근 통제한다.

## 근거

- https://dexidp.io/docs/connectors/github/
- https://dexidp.io/docs/configuration/storage/
- https://github.com/dexidp/dex/releases/tag/v2.46.1
- https://github.com/dexidp/dex/blob/v2.46.1/Dockerfile
- https://github.com/dexidp/dex/blob/v2.46.1/examples/config-dev.yaml
- https://tailscale.com/kb/1242/tailscale-serve
