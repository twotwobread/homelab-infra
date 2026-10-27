# Dex + GitHub OIDC: VPN 전용 배포

## 상태와 근거

사용자 보고로 Docker Compose 실행, Windows/WSL GitHub 로그인, 8443 issuer 전환 후 Kubernetes `auth whoami` 성공을 확인했다. 에이전트가 운영 서버에서 독립 검증한 것은 아니다. 그룹은 `system:authenticated`였으며 이 자체가 관리자 권한을 뜻하지 않는다. 개인 사용자 cluster-admin Binding은 요청에 따라 템플릿을 추가했으며 적용 성공은 아직 보고되지 않았다.

환경: Tailscale 1.104.2, Docker 29.3.0, Compose v5.1.0. MagicDNS/HTTPS 활성화, GitHub 개인 OAuth App 사용, 조직 제한 없음. 서버 변경은 사용자가 직접 수행한다.

## 443 충돌과 8443 결정

초기 Serve 443은 WSL 로그인에는 동작했지만 K3s의 issuer 조회에서 Traefik 기본 인증서를 반환했다. 사용자 제공 결과:

- DNS는 minipc Tailscale IP로 정상 해석됨.
- DNS와 HTTP proxy를 배제한 minipc의 요청도 TLS 검증 실패.
- NAT OUTPUT → 로컬 목적지 CNI-HOSTPORT-DNAT → TCP 443의 ServiceLB DNAT 규칙 존재.
- API 로그: issuer 인증서 이름 불일치 → OIDC authenticator 미초기화 → Unauthorized.

K3s 관리 NAT 규칙을 수동 삭제하거나 잘못된 인증서를 신뢰하지 않고, Dex HTTPS를 8443으로 분리했다. Dex/GitHub callback/K3s/kubeconfig의 issuer를 함께 변경한 뒤 사용자가 OIDC 인증 성공을 보고했다. 443 Serve 및 이전 grant 제거 여부는 별도 확인한다.

## 구성

- 외부 issuer: `https://<DEX_DNS_NAME>:8443`
- GitHub OAuth App callback: `https://<DEX_DNS_NAME>:8443/callback`
- Tailscale Serve → host `127.0.0.1:5556` → Dex 컨테이너. Funnel 미사용.
- [Compose](../../auth/dex/compose.yaml): v2.46.1 태그, UID/GID 1001, read-only rootfs, capability 제거, no-new-privileges, SQLite `/var/lib/homelab-dex` 영속화. 태그 지정은 digest 고정과 다르다.
- host loopback 게시가 Docker 관리자/root 또는 컨테이너 네트워크까지 차단하는 것은 아니다.
- GitHub secret은 mode 600 로컬 env 파일. Docker 환경 변수로 주입되므로 Docker 관리자에게는 보일 수 있다. 전체 inspect/config 출력 공유 금지.
- GitHub org 제한은 없다. 인증과 RBAC를 구분하며 정확한 개인 subject에 권한 부여.
- kubectl public client `homelab-kubectl`, PKCE S256 필수, callback `http://localhost:8000`. 이것은 GitHub → Dex callback과 다르다.
- ID token 10분, refresh token 미사용 24시간/절대 168시간. 토큰 발급 후 계정 차단이 즉시 무효화를 보장하지 않는다.

## 저장소에서 직접 실행 (minipc)

최초 clone은 PR 머지 후 수행한다. 기존 clone은 로컬 변경을 확인하고 develop을 fast-forward로 갱신한다.

```bash
git clone --branch develop https://github.com/twotwobread/homelab-infra.git
cd homelab-infra/auth/dex
```

실행 위치는 `auth/dex/`. 기존 로컬 설정은 덮어쓰지 않는다.

```bash
cp -n config.yaml.example config.local.yaml
cp -n dex.env.example dex.env.local
chmod 644 config.local.yaml
chmod 600 dex.env.local
sudo install -d -m 0700 -o 1001 -g 1001 /var/lib/homelab-dex
```

config의 DNS placeholder 두 곳과 env의 자격 증명을 편집기에서 치환한다. env는 raw 형식이므로 따옴표 없이 입력한다. shell history에 secret을 남기지 않는다. 기존에 443 주소를 쓰는 config는 `cp -n`으로 갱신되지 않으므로 직접 수정한다. 실제 로컬 파일은 Git 제외 대상이며 `git clean -fdx`로 삭제하지 않도록 주의한다. /opt 배포와 혼용하지 않는다.

```bash
git check-ignore config.local.yaml dex.env.local
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
curl --fail --silent --show-error http://127.0.0.1:5556/.well-known/openid-configuration
```

config 변경 후에는 `docker compose restart dex`로 다시 읽는다. env 변경은 `docker compose up -d --force-recreate dex` 등 컨테이너 재생성이 필요하다. discovery issuer가 HTTPS 8443 주소인지 확인한다.

## Serve 및 정책

[정책 템플릿](../../network/tailscale/policy.hujson.example)은 노트북 → minipc VPN IP TCP 22/8443, LAN IP TCP 22/6443을 허용한다. 최종 정책에서 VPN IP의 443은 허용하지 않는다. 실제 관리 화면 정책을 검토한 뒤 적용한다.

```bash
tailscale serve status
tailscale funnel status
sudo tailscale serve --bg --https=8443 http://127.0.0.1:5556
```

다른 Serve 설정을 덮어쓰지 않는다. WSL과 minipc 양쪽에서 다음을 검증한다.

```bash
curl --fail --silent --show-error https://<DEX_DNS_NAME>:8443/.well-known/openid-configuration
```

TLS 우회 옵션 `-k`는 사용하지 않는다. 443에서 전환했다면 GitHub App callback, K3s issuer, kubeconfig exec issuer를 함께 수정한다. 인증 성공 후 **Dex용으로 만들었던 Serve 443만** `sudo tailscale serve --https=443 off`로 제거하고 정책의 443 허용도 제거한다. 일반 LAN 관리 차단은 아직 완료되지 않았다.

## K3s와 RBAC

설정과 적용 절차는 [OIDC 관리자 및 GitOps 관리](oidc-admin-gitops.md)를 참고한다. kubeconfig exec의 issuer는 반드시 같은 HTTPS 8443 주소다. API endpoint는 기존 LAN 주소를 유지한다. 토큰 원문·개인키를 저장하지 않는다.

## 롤백

이 문서로 추가한 Serve 8443만 해제할 경우:

```bash
sudo tailscale serve --https=8443 off
# auth/dex 디렉터리에서
docker compose stop
```

이 작업은 OIDC 신규 로그인/갱신 및 API의 issuer 접근에 영향을 준다. 기존 관리자 context와 로컬 콘솔을 확보한다. DB/secret 파일은 삭제하지 않는다. K3s 설정을 되돌릴 때는 해당 설정 백업을 복원하고 재시작한다. SQLite 백업은 인증 상태를 포함할 수 있으므로 암호화한다.

## 공식 참고

- https://dexidp.io/docs/connectors/github/
- https://github.com/dexidp/dex/blob/v2.46.1/Dockerfile
- https://github.com/dexidp/dex/blob/v2.46.1/examples/config-dev.yaml
- https://tailscale.com/kb/1242/tailscale-serve
