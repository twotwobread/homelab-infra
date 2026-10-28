# Dex 기반 신원 연동의 범위와 확장 한계

## 현재 결정

현재 GitHub → Dex → Kubernetes/Vault 구성을 유지한다. 사용자 요청에 따라 한계와 향후 선택지만 기록하고 이번 단계에서는 Keycloak을 배포하거나 issuer/권한을 전환하지 않는다. 이 문서는 설계 판단이며 미래 구성이 구현됐다는 의미가 아니다.

Kubernetes OIDC 및 개인 관리자 권한 검증은 기존 문서에 기록되어 있다. Vault는 사용자가 host network 전환 후 unseal 상태와 이후 OIDC 로그인 성공을 보고했다. 해당 Vault 로그인 성공은 에이전트가 독립 재실행한 결과가 아니다. role 이름만으로 관리자 권한을 추정하지 않으며, 처음 안내한 role은 제한된 learning-reader policy에 연결된다.

## 신원과 인가의 경계

```text
GitHub 사용자 인증
    ↓ OAuth connector
Dex: 공통 OIDC issuer
    ├─ Kubernetes: 사용자 claim → RBAC
    └─ Vault: 사용자 claim/auth role → policy
```

- Dex는 각 서비스가 신뢰할 공통 OIDC 발급자를 제공한다. 이는 **인증 연결의 중앙화**다.
- 외부 IdP가 제공하는 사용자·그룹 정보를 connector의 지원 범위와 설정에 따라 전달할 수 있다.
- 계정 생성/탈퇴, 조직·팀, MFA·계정 복구를 종합적으로 관리하는 자체 IAM이 Dex의 주목적은 아니다. 제한적인 로컬 사용자 기능이 있다는 사실과 종합 사용자 관리 기능은 구분한다.
- 현재 GitHub 개인 계정 구성에는 조직/팀 기반 제한을 사용하지 않는다. Kubernetes와 Vault는 본인의 검증된 subject를 각자의 정책에 연결한다.
- GitHub 조직·팀 또는 LDAP 등 외부에 그룹 관리 체계가 있다면 Dex를 통해 전달할 수 있다. 따라서 Dex로 중앙화가 전혀 불가능하다고 표현하지 않는다.

| 구성 요소 | 담당 |
| --- | --- |
| Tailscale 정책 | 지정 기기가 어느 서비스에 도달할 수 있는가 |
| GitHub/Dex | 로그인한 사용자가 누구인가 |
| Kubernetes Role/ClusterRole와 Binding | 어떤 Kubernetes API 작업을 허용하는가 |
| Vault auth role/Identity 매핑 | 어떤 인증 신원에 어떤 policy를 연결하는가 |
| Vault policy | 어떤 Vault 경로에서 어떤 작업을 허용하는가 |

공통 신원 사용이 공통 권한을 뜻하지 않는다. Kubernetes cluster-admin이 Vault 관리자 권한으로 자동 변환되지 않는다. 워크로드의 ServiceAccount 신원과 Vault Kubernetes auth도 사람 OIDC와 별도 흐름이다.

## 현재 방식의 확장 한계

1. **외부 조직 없이 자체 팀·그룹 관리:** Dex 안에 조직 체계를 만드는 방식보다는 별도 IdP/디렉터리가 필요하다.
2. **사용자 수 증가:** 개인 subject별 Binding과 bound_subject 관리가 늘 수 있다. 외부 그룹 기반 매핑이 필요한 시점에 검토한다.
3. **인증 정책 통합:** 자체 비밀번호·MFA·가입/탈퇴·계정 복구를 통합 운영하려면 Dex만으로 해결하려 하지 않는다.
4. **권한은 서비스별로 유지:** IdP를 바꿔도 Kubernetes RBAC와 Vault policy의 설계·감사는 별도로 필요하다.
5. **폐기 지연:** IdP 계정/그룹 변경이 이미 발급된 JWT나 Vault 토큰을 모두 즉시 폐기하지 않는다. 토큰 TTL, 갱신, Vault 토큰 회수, RBAC 회수, 네트워크 차단을 조합해야 한다.

## 향후 Keycloak 검토 조건

자체 사용자·그룹·MFA 및 여러 서비스의 SSO 관리가 실제 요구가 되면 Keycloak 같은 IdP를 검토한다. 관리형 IdP도 대안이며 Keycloak이 항상 가장 쉬운 운영 선택이라는 의미는 아니다. Keycloak은 DB, 업데이트, 백업·복원, 관리자 복구 경로를 운영해야 한다.

권장 최종 개념 구조:

```text
GitHub 외부 로그인 또는 Keycloak 자체 계정
                    ↓
                Keycloak
              사용자·그룹·인증
                    ↓
             Kubernetes / Vault
               각자의 인가
```

별도 요구가 없다면 Dex를 대체하여 중간 인증 계층을 줄인다. Keycloak → Dex 체인은 기존 서비스의 점진적 이전이나 특수 connector 요구 등 명확한 이유가 있을 때만 검토한다. Dex를 남긴다고 사용자 subject가 자동 보존되는 것은 아니다.

### 전환 시 주의사항 (현재 실행하지 않음)

- Keycloak을 먼저 준비하고 HTTPS issuer, 로그인, 토큰 claim을 검증한 뒤 서비스별 신뢰를 전환한다. Dex를 먼저 삭제하지 않는다.
- 같은 GitHub 계정이라도 issuer와 sub가 달라질 수 있다. Kubernetes의 기존 User Binding과 Vault bound_subject/Identity alias를 그대로 재사용한다고 가정하지 않는다.
- kubectl과 Vault는 별도 client로 등록한다. 필요한 사용자·그룹 claim 및 prefix를 명시적으로 매핑한다.
- 권한 상승을 방지하도록 제한된 신원과 허용/거부를 검증한다. 새 그룹에 자동으로 cluster-admin을 부여하지 않는다.
- 기존 관리자 인증과 IdP 장애에도 가능한 비상 접근을 확보한다. 병행 인증 가능 여부는 각 서비스/버전의 지원 범위에 맞춰 설계한다.
- 세션/토큰 및 secret 폐기·롤백까지 확인한 뒤 Dex 의존성을 제거한다.

## 관련 문서

- [Dex 배포 및 8443 이력](dex-bootstrap.md)
- [Kubernetes OIDC 관리자 및 GitOps](oidc-admin-gitops.md)
- [Vault OIDC 설정](vault-oidc.md)
- [Vault host network 결정](vault-host-network.md)

이번 기록은 Keycloak 설치 계획의 실행 승인이나 Dex 제거 승인이 아니다. 현재 구성을 유지한 채 필요가 발생하면 별도 변경으로 검토한다.
