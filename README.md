# Vaultwarden Helm Chart

Production-grade Helm chart for [Vaultwarden](https://github.com/dani-garcia/vaultwarden) on Kubernetes.

## Features

- **High availability**: multiple Vaultwarden replicas with a shared JWT key, rolling updates without downtime, PDB, topology spread, optional HPA
- **PostgreSQL via [CloudNativePG](https://cloudnative-pg.io)** (`Cluster` CR, 3 instances, automated failover), or an external DB, or sqlite for small single-pod installs
- **Three storage modes**: shared RWX PVC, S3 (external, or a bundled [RustFS](https://github.com/rustfs/rustfs) served same-origin), or an RWO fallback with a single replica
- **Backups on by default**: barman-cloud WAL archiving + base backups (point-in-time recovery), restic snapshots of the files, one-shot restore Job, declarative DR bootstrap
- **Hardened**: non-root, read-only root filesystem, `drop: [ALL]`, NetworkPolicy, no ServiceAccount token, generate-once secrets kept on uninstall
- **Fail-fast**: unsafe value combinations are rejected at render time
- **S3-enabled image**: the upstream image ships without the `s3` feature; `build-image` publishes `ghcr.io/maximewewer/vaultwarden-s3` (Alpine, tag `<appVersion>-alpine`, always the chart `appVersion`) from the unmodified upstream sources
- Automated weekly version updates tracking upstream releases

## Prerequisites

- Kubernetes 1.29+, Helm 3.8+.
- [CloudNativePG](https://cloudnative-pg.io/documentation/current/installation_upgrade/) operator and, for database backups, the [barman-cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/) (needs cert-manager).
- An off-site S3 bucket for backups.

## Installation

### Helm (OCI)

```bash
helm install vaultwarden oci://ghcr.io/maximewewer/charts/vaultwarden \
  --version 1.37.5-05-11-2026 \
  --namespace vaultwarden --create-namespace \
  --set config.domain=https://vault.example.com \
  --set backup.s3.endpoint=https://s3.backup.example.com \
  --set backup.s3.bucket=vaultwarden-backups \
  --set backup.s3.existingSecret=vaultwarden-backup-s3
```

Chart versions are `<vaultwarden version>-<DD-MM-YYYY>`, which semver reads as a pre-release: Helm only resolves them with an explicit `--version` (recommended, pin it), or `--devel` for the latest one.

### From source

```bash
git clone https://github.com/MaximeWewer/vaultwarden-helm.git
cd vaultwarden-helm
helm dependency build chart/
helm install vaultwarden chart/ -n vaultwarden --create-namespace -f my-values.yaml
```

### Argo CD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vaultwarden
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ghcr.io/maximewewer/charts
    chart: vaultwarden
    targetRevision: "<chart-version>"
    helm:
      values: |
        config:
          domain: https://vault.example.com
          existingSecret: vaultwarden-secret   # rsa-private-key (+ admin-token...) from ESO/Vault
        backup:
          s3:
            endpoint: https://s3.backup.example.com
            bucket: vaultwarden-backups
            existingSecret: vaultwarden-backup-s3
  destination:
    server: https://kubernetes.default.svc
    namespace: vaultwarden
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

With Argo CD, pin `config.secrets.rsaPrivateKey` inline or use `config.existingSecret`: Argo's `lookup` is unreliable, so a generated key would re-roll on sync and log every user out.

## Configuration

Architecture, storage modes, HA caveats, backup/restore procedures and the full values reference: [`chart/README.md`](chart/README.md).

## License

This chart is distributed under the [MIT License](LICENSE). Vaultwarden itself is licensed under the [AGPL-3.0](https://github.com/dani-garcia/vaultwarden/blob/main/LICENSE.txt); the `vaultwarden-s3` image built by this repository is a build of the unmodified upstream sources and stays under AGPL-3.0.
