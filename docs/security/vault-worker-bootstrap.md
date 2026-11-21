# EC2 워커 부트스트랩용 Vault 인증과 정책

홈랩 Vault의 기존 HTTPS 리스너를 유지한다. 신규 EC2는 Tailscale 가입 전 Vault에 접근할 수 없으므로, 가입 키를 먼저 AWS Secrets Manager에서 가져온다.

1. 홈랩의 전용 Job은 `worker-bootstrap/tailscale-key-relay` 서비스 계정으로 Vault에 로그인한다. Vault에서 `tag:k3s-worker`가 붙은 1회용 가입 키를 읽고, AWS Secrets Manager의 지정된 시크릿에 전달한다.
2. EC2 워커는 인스턴스 프로파일 자격 증명으로 지정된 시크릿을 읽어 Tailscale에 가입하고 승인된 LAN 경로를 수락한다. 이후 기존 Vault HTTPS 엔드포인트에서 AWS IAM auth로 로그인해 K3s 에이전트 조인 토큰을 읽는다.
3. AWS 쪽에서는 전달 Job의 쓰기 권한과 워커의 읽기 권한을 서로 다른 역할에 부여하고, 지정된 시크릿으로 제한한다. 1회용 키의 소비와 전달용 시크릿의 정리는 후속 구현에서 검증한다. 키와 토큰을 Git, EC2 user data, 출력 및 로그에 기록하지 않는다.

| 호출자 | Vault auth 경로 및 역할 | KV v2 데이터 경로 |
| --- | --- | --- |
| 홈랩 Job SA | `worker-kubernetes` / `tailscale-key-relay` | `worker-bootstrap/data/tailscale-auth-key` 읽기 |
| EC2 인스턴스 프로파일의 IAM 역할 | `worker-aws` / `k3s-worker-bootstrap` | `worker-bootstrap/data/k3s-agent-token` 읽기 |

두 Vault 역할 모두 기본 정책 없이 TTL과 명시적 최대 TTL이 5분인 서비스 토큰을 발급한다. 후속 Job, Secrets Manager 리소스 및 AWS IAM 정책, tailnet 정책 적용, 실제 시크릿 입력과 Karpenter 설치는 별도 작업이다.

## Tailscale 가입 키 발급과 수명

첫 CPU 워커 검증은 짧은 유효기간의 일회용 가입 키 한 개를 미리 준비해 진행한다. 위의 Vault 경로에는 **발급된 기기 가입 키**를 넣는다. Vault 역할의 5분 TTL은 Vault 로그인 토큰에 적용되며, Tailscale 가입 키의 만료와는 별개다.

반복 증설에서는 홈랩의 발급 자동화가 Vault에 별도로 보관한 Tailscale OAuth 클라이언트 자격 증명으로 단기 API 액세스 토큰을 얻는다. OAuth 권한은 가입 키 발급과 워커 태그로 제한한다. 그 토큰으로 새 EC2마다 짧게 유효한 일회용 가입 키를 발급한다. 기기 승인이 켜져 있으면 사전 승인 옵션을 사용한다. 각 워커가 자신에게 할당된 키만 읽도록 AWS 전달 경로를 구성한다. 여러 워커가 동시에 기동할 때 같은 일회용 키를 소비하지 않는지 검증한다. EC2로 전달되는 값은 가입 키이며, OAuth 클라이언트 시크릿과 API 토큰은 발급 자동화에만 남긴다. OAuth 발급과 워커별 키 전달 구현은 후속 범위다. [Tailscale OAuth 클라이언트](https://tailscale.com/docs/features/oauth-clients) · [Tailscale 가입 키](https://tailscale.com/docs/features/access-control/auth-keys)

짧은 유효기간과 일회용 설정은 노출 시 악용 가능한 시간과 가입 횟수를 줄인다. 정상 워커가 쓰기 전에 키가 노출되면 다른 기기가 워커 태그로 가입할 수 있다. 이 경우 미사용 키를 폐기하고, 이미 가입한 의심 기기는 관리 콘솔에서 등록을 해제한다. 키 만료나 폐기 이후에도 등록된 기기는 별도로 확인한다.

## 적용 전 전제

- Vault의 TLS 이름과 CA를 홈랩 Job과 가입을 마친 워커에서 검증하고, 두 호출자의 Vault TCP 8200 접근을 각각 확인한다. 기존 리스너를 공개하지 않는다.
- Vault 호스트에서 TLS로 K3s API와 AWS STS에 연결할 수 있어야 한다. Vault 서버 측 AWS 자격 증명은 별도로 준비하고, IAM 역할의 고유 ID를 해석하는 데 필요한 `iam:GetRole`을 지정된 워커 역할로 한정한다. 워커 역할은 EC2 인스턴스 프로파일에 연결된 IAM 역할 ARN을 사용한다.
- K3s의 에이전트 전용 조인 토큰을 준비한다. 기본 설정에서 agent-token 파일은 서버 토큰을 가리킬 수 있다. 두 토큰이 분리됐음을 확인한 뒤 에이전트 전용 값만 Vault에 저장한다. [K3s 토큰 종류](https://docs.k3s.io/cli/token)
- 운영 Vault 관리 세션에서 기존 auth 및 KV 마운트를 확인한다. 아래 이름은 이 부트스트랩 전용이다. 이름이 겹치면 소유권과 구성을 확인한 뒤 진행한다.
- Kubernetes 대상 context를 확인하고 저장소 루트에서 [서비스 계정과 TokenReview RBAC](../../auth/vault/bootstrap/service-accounts.yaml)를 적용할 준비를 한다. reviewer에게는 TokenReview 생성만 허용한다. 전용 namespace에서 Job, Pod 또는 SA 토큰을 생성할 수 있는 주체도 제한한다.

## 구성 절차

승인된 적용 시점에 저장소 루트에서 실행한다. `<context>`는 확인한 K3s context로 바꾼다. 처음 한 번 전용 auth 및 KV v2 마운트를 만들고, 재적용 시에는 마운트 생성을 건너뛴다.

```sh
kubectl config current-context
kubectl --context '<context>' apply -f auth/vault/bootstrap/service-accounts.yaml

vault auth enable -path=worker-kubernetes kubernetes
vault auth enable -path=worker-aws aws
vault secrets enable -path=worker-bootstrap kv-v2
```

관리 세션에서 `VAULT_ADDR`, `KUBE_API_URL`, `KUBE_CA_FILE`, `WORKER_IAM_ROLE_ARN`, `VAULT_IAM_SERVER_ID`를 설정한다. `VAULT_IAM_SERVER_ID`는 일반적으로 Vault의 TLS DNS 이름을 사용한다. `REVIEWER_JWT_FILE`은 reviewer SA에 대해 API 서버용 기본 audience로 발급한 기한부 토큰을 담은 파일의 경로로 지정한다. 파일은 운영자만 읽을 수 있게 생성하고 사용 후 안전하게 정리한다. 외부 Docker Vault는 이 JWT를 마운트 설정에 보관하므로 만료 전에는 새 reviewer 토큰으로 갱신해야 한다. Job의 별도 projected SA 토큰 audience는 `vault-worker-bootstrap`이다.

[구성 스크립트](../../auth/vault/bootstrap/configure.sh)는 두 정책과 역할, Kubernetes TokenReview 설정, AWS IAM server ID를 기록한다. AWS IAM 로그인 클라이언트는 전용 마운트(auth/worker-aws/login, Vault CLI에서는 -path=worker-aws)를 지정하고 동일한 ID를 `X-Vault-AWS-IAM-Server-ID` 헤더에 넣고 서명에 포함한다.

```sh
bash auth/vault/bootstrap/configure.sh
```

## 교차 접근 검증

격리된 검증용 Vault의 두 KV 경로에 더미 값을 준비한다. 양쪽 모두 존재해야 미존재와 접근 거부를 구별할 수 있다. 로그인 응답은 토큰을 포함하므로 화면이나 로그에 남기지 않는다. 각 토큰을 해당 호출자 세션에만 전달하고, Vault API GET의 HTTP 상태만 확인한다.

| 발급받은 토큰 | `GET /v1/worker-bootstrap/data/tailscale-auth-key` | `GET /v1/worker-bootstrap/data/k3s-agent-token` |
| --- | --- | --- |
| 전용 Job SA로 로그인한 토큰 | 200 | 403 |
| 지정된 EC2 IAM role로 로그인한 토큰 | 403 | 200 |

다른 SA 또는 잘못된 audience로 Kubernetes 로그인을 시도해 거부를 확인한다. AWS 쪽은 다른 IAM 역할 또는 누락·불일치한 server ID의 로그인이 거부되는지 확인한다. 두 토큰 모두 KV 메타데이터 목록 조회와 시크릿 쓰기가 거부되어야 한다. 정상 로그인 응답의 TTL과 정책 목록을 확인하고, 5분 뒤 정상 경로 요청도 거부되는지 확인한다. 운영 승인 후 동일한 검증을 진행할 때도 응답 본문은 출력하지 않는다.

참고 자료는 [Vault Kubernetes auth API](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes)와 [Vault AWS auth API](https://developer.hashicorp.com/vault/api-docs/auth/aws)다.
