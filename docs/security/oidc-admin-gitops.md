# 개인 OIDC 관리자 및 GitOps 관리 경계

## 상태

사용자는 8443 issuer 전환 후 `auth whoami`에서 `oidc:` 접두사의 개인 신원과 `system:authenticated` 그룹을 확인했다. 실제 subject/credential-id 원문은 저장하지 않는다. 이후 사용자 제공 출력으로 개인 cluster-admin 권한 및 실제 조회 성공을 확인했다. 이 문서 작성으로 운영 설정을 변경하지 않는다.

## 검증 기록

2026-10-27 사용자 제공 실행 결과에 근거한다. 에이전트가 별도 자격 증명으로 재실행한 검증은 아니다.

| 명령/항목 | 관측 결과 |
| --- | --- |
| Binding 적용 전 diff | 정확한 OIDC User 하나를 cluster-admin에 연결하는 신규 ClusterRoleBinding |
| OIDC context의 `auth whoami` | 기대한 `oidc:` 접두사의 개인 신원, `system:authenticated` 그룹 |
| `auth can-i '*' '*' --all-namespaces` | yes |
| `get nodes` | minipc control-plane 및 homelab-pi 모두 Ready |
| `get pods -A` | 전체 namespace 조회 성공, 시스템 Pod Running 및 Helm 설치 Job Completed |

RBAC는 사용자에게 권한을 연결하므로 `auth whoami`의 그룹에 cluster-admin이 추가되지 않는 것이 정상이다. 실제 Secret 값 조회나 파괴적 작업으로 권한을 검증하지 않았다. 로그의 subject와 JTI 원문은 기록하지 않는다.

연속된 일부 `auth whoami`에서 브라우저 로그인이 요구됐으나 이후 권한/조회 명령은 성공했다. 원인은 확정하지 않았으며 토큰 캐시/refresh 동작을 검증 완료로 주장하지 않는다. 기본 context 전환과 기존 Serve 443 제거의 별도 명령 출력은 확보하지 않았다. LAN 직접 관리 접근 차단 및 VPN OFF 거부 테스트는 아직 미검증이다.

443에서 8443으로 issuer를 전환한 과정은 [Dex 충돌 조사 및 전환 이력](dex-bootstrap.md#조사-및-전환-이력)에 기록한다.

## 템플릿

- [K3s 호스트 설정](../../hosts/minipc/k3s/config.yaml.example)
- [개인 ClusterRoleBinding](../../kubernetes/rbac/oidc-owner-cluster-admin.yaml.example)

| Placeholder | 입력값 |
| --- | --- |
| `<MINIPC_LAN_IPV4>` | 기존 minipc LAN 주소. 세 위치에 동일 값 |
| `<OIDC_ISSUER_URL>` | `https://<DEX_DNS_NAME>:8443` 전체 주소. Dex issuer와 정확히 일치 |
| `<OIDC_USERNAME_WITH_PREFIX>` | OIDC context의 `auth whoami`가 반환한 `oidc:` 포함 전체 Username |

GitHub 닉네임, kubeconfig 별칭 또는 credential-id를 subject 대신 넣지 않는다. `kind: User`로 정확한 신원 하나에만 연결한다. `system:authenticated` 그룹으로 대체하지 않는다. cluster-admin은 전체 관리자 권한이므로 개발 namespace 관리자보다 훨씬 강력하다. OIDC를 쓴다고 작업 권한이 최소화되는 것은 아니다.

## K3s 설정 적용 (minipc에서 사용자 실행)

이 파일은 Kubernetes 리소스가 아니라 `/etc/rancher/k3s/config.yaml`의 호스트 설정이다. `kubectl apply` 또는 Argo CD 기본 리소스 sync로 적용할 수 없다.

```bash
# 저장소 루트에서
cp -n hosts/minipc/k3s/config.yaml.example hosts/minipc/k3s/config.local.yaml
```

로컬 파일을 편집하여 placeholder를 치환한다. 기존 실행 설정 및 config drop-in/환경/CLI 옵션과 충돌이 없는지 확인한다. 기존 config와 병합하며 파일 전체를 무조건 덮어쓰지 않는다. 기존 `kube-apiserver-arg` 및 다른 항목을 보존한다.

기존 설정을 root 전용 경로에 백업하고 편집 후 K3s를 재시작한다. 이미 해당 설정으로 인증에 성공한 환경은 불필요하게 재시작하지 않는다.

```bash
sudo install -d -m 0700 /root/k3s-config-backups
sudo install -m 0600 /etc/rancher/k3s/config.yaml "/root/k3s-config-backups/config.yaml.$(date +%Y%m%d-%H%M%S)"
sudoedit /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s
sudo k3s kubectl get nodes
```

재시작 중 API 중단이 발생한다. 실패 시 해당 백업을 복원하고 재시작한다. datastore 복원으로 설정 오류를 해결하려 하지 않는다. WSL OIDC context의 issuer도 새 주소와 일치해야 한다.

## Binding 적용 (관리 클라이언트에서 사용자 실행)

실행 위치: 저장소 루트. 실제 로컬 파일은 Git에서 제외한다.

```bash
cp -n kubernetes/rbac/oidc-owner-cluster-admin.yaml.example kubernetes/rbac/oidc-owner-cluster-admin.local.yaml
```

placeholder를 정확한 Username으로 치환한 후, 기존 관리자 context `homelab` 및 기본 namespace를 명시한다. kubeconfig 로딩은 기존 사용자 환경에 맞춘다. 기본 파일만으로 로드되지 않으면 명시적 `--kubeconfig`를 사용한다.

```bash
kubectl --context=homelab --namespace=default auth whoami
kubectl --context=homelab --namespace=default diff -f kubernetes/rbac/oidc-owner-cluster-admin.local.yaml
kubectl --context=homelab --namespace=default apply -f kubernetes/rbac/oidc-owner-cluster-admin.local.yaml
kubectl --context=homelab-oidc --namespace=default auth whoami
kubectl --context=homelab-oidc --namespace=default auth can-i '*' '*' --all-namespaces
kubectl --context=homelab-oidc --namespace=default get nodes
```

기존 관리자 신원은 `system:admin`, 새 신원은 `oidc:` prefix여야 한다. diff는 차이가 있으면 종료 코드 1을 반환한다. 새 신원의 광범위한 권한 검사는 yes가 목표다. 실제 Secret 값 조회나 파괴적인 작업으로 관리자 권한을 시험하지 않는다. ClusterRoleBinding은 클러스터 범위이므로 namespace 옵션으로 권한 범위가 축소되지 않는다.

권한 회수:

```bash
kubectl --context=homelab --namespace=default delete clusterrolebinding homelab-owner-oidc-cluster-admin
```

다른 Binding의 권한은 남는다. GitOps 자동 동기화를 나중에 도입하면 Git의 선언도 수정해야 재생성되지 않는다. 기본 context 변경은 권한 검증 후 별도로 수행한다.

## Argo CD: 모두 Secret으로 만들 필요 없음

IP, issuer URL, OAuth client ID, OIDC 사용자 식별자는 인증 비밀이 아니다. 개인/환경 정보를 공개하고 싶지 않아 placeholder를 사용하는 것과 Secret 보관은 별개다.

- ClusterRoleBinding은 일반 Kubernetes 리소스로 GitOps 관리 가능하다. Secret으로 감싸지 않는다.
- Kubernetes RBAC는 Secret 값을 읽어 subject를 치환하지 않는다. Argo CD도 일반 YAML의 `<...>`를 자동 치환하지 않는다.
- 실제 배포에는 환경별 Helm values 또는 Kustomize patch/replacement 등으로 **렌더링 시점**에 값을 넣어야 한다. 공개 저장소에 값을 남기기 싫으면 private 환경 저장소를 사용할 수 있다.
- 현재 `.yaml.example`은 직접 sync 대상이 아닌 템플릿이다. 이 PR은 Argo CD Application/자동 치환 구현을 포함하지 않는다.
- GitHub OAuth client secret, 개인키, 토큰, Vault unseal 자료 등만 별도 비밀 관리 대상이다. 평문 Secret YAML의 base64는 암호화가 아니다. Vault/External Secrets, SOPS 등은 필요에 맞춰 검토한다.
- K3s 호스트 설정과 OS의 Docker Compose는 Argo CD의 기본 관리 대상이 아니다. 지금은 수동 적용, 이후 Ansible 등 호스트 구성 관리가 적합하다. 이를 위해 Argo CD에 root/SSH 권한을 주지 않는다.
- cluster-admin Binding을 관리하는 GitOps 경로는 권한 상승 경로다. 저장소 쓰기/PR 승인, Argo CD AppProject의 리소스·대상 제한과 controller 권한을 검토한다. 일반 앱 개발자가 자신의 권한을 올릴 수 없도록 플랫폼 관리 경로를 분리한다.
- Argo CD가 아직 없으므로 최초 bootstrap은 기존 관리자로 수행한다. 비상 접근을 Argo CD 가용성에만 의존시키지 않는다.
