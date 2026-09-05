# Deployment

## VPS prerequisites

- Ubuntu 24.04 LTS
- Docker Engine and Docker Compose v2
- Git
- A firewall that allows `22/tcp`, `8080/tcp`, and `8081/tcp` only
- A GitLab project and a **shell** runner tagged `wordpress-infra`

Install Docker from the official Docker repository, not the Ubuntu `docker.io` metapackage, unless you already standardize on that.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Log out and back in after adding your user to `docker`.

## Initial installation

Use a fixed path so GitLab CI and manual operations share the same volumes and `.env`.

```bash
sudo mkdir -p /opt/wordpress-infra
sudo chown "$USER:$USER" /opt/wordpress-infra
git clone <gitlab-repository-url> /opt/wordpress-infra
cd /opt/wordpress-infra

cp .env.example .env
chmod 600 .env
vim .env
```

Replace every `change-me-*` password. Set `VPS_IP` to the VPS public address. Keep production and staging database/Redis passwords different.

```bash
docker compose --env-file .env config
docker compose pull
docker compose build
docker compose up -d
./scripts/healthcheck.sh
```

Open:

```text
Production:  http://VPS_IP:8080
Staging:     http://VPS_IP:8081
```

Complete the WordPress installer on each URL. Then enable Redis object caching:

```bash
./scripts/maintenance.sh enable-redis
```

Hand the tree to the runner user after the first install:

```bash
sudo chown -R gitlab-runner:gitlab-runner /opt/wordpress-infra
sudo chmod 600 /opt/wordpress-infra/.env
```

The operator who will run backups and `deploy.sh` by hand must be in the `docker` group and able to read that directory.

## Firewall

Do not open MariaDB or Redis on the host. Example with UFW (apply only after you understand the rules):

```text
22/tcp    SSH          restrict to trusted source IPs if possible
8080/tcp  Production
8081/tcp  Staging
```

```bash
sudo ufw allow OpenSSH
sudo ufw allow 8080/tcp
sudo ufw allow 8081/tcp
sudo ufw enable
```

This repository does not configure the firewall automatically.

## GitLab Runner

Install the official GitLab Runner package on the **same VPS**. Use the **shell** executor. Do not use a shared GitLab.com runner for deploy jobs.

```bash
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash
sudo apt-get install -y gitlab-runner
```

Register against your GitLab project. When prompted:

```text
Executor:          shell
Tags:              wordpress-infra
Untagged jobs:     no
```

Non-interactive example (replace URL and token):

```bash
sudo gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.example.com/" \
  --token "glrt-xxxxxxxx" \
  --executor "shell" \
  --tag-list "wordpress-infra" \
  --description "wordpress-vps"
```

The `gitlab-runner` service already runs as the `gitlab-runner` user. Do not run the runner as root.

### Docker permissions

The runner must talk to the Docker daemon:

```bash
sudo usermod -aG docker gitlab-runner
sudo systemctl restart gitlab-runner
```

**Security implication:** membership in `docker` is effectively root on the host. Anyone who can push a pipeline that runs on this runner can start privileged containers, mount the host filesystem, and read `/opt/wordpress-infra/.env`. Restrict who can push to the default branch and who can run pipelines. Do not add extra untrusted projects to this runner.

Also grant the runner ownership of the deploy tree (see above). CI uses `GIT_STRATEGY: none` and updates `/opt/wordpress-infra` in place so `.env` and named volumes survive.

## GitLab CI flow

```text
push to default branch
        │
        ▼
     validate
        │
        ▼
       test
        │
        ▼
  deploy staging          (automatic)
        │
        ▼
  deploy production       (manual play button)
```

Production never deploys on push. After staging is green, open the pipeline and run **deploy:production**.

Override `DEPLOY_DIR` in GitLab CI/CD variables only if the checkout is not `/opt/wordpress-infra`.

Set CI/CD variables `VPS_IP`, `PROD_PORT`, and `STAGE_PORT` if you want environment URLs in the GitLab UI. They are optional; the deploy scripts read `.env` on the VPS.

## Manual deploys

From `/opt/wordpress-infra`:

```bash
./scripts/deploy.sh staging
./scripts/deploy.sh production
./scripts/deploy.sh all
```

`staging` recreates only `nginx-stage`, `wordpress-stage`, and `redis-stage` (`--no-deps`), so production containers are not restarted.

`production` updates `nginx-prod`, `wordpress-prod`, `redis-prod`, and `mariadb`. MariaDB is included because its image and config are shared; `docker compose up -d` is a no-op when nothing changed.

Neither path runs `docker compose down` or `-v`.

## Rollback

There is no automatic rollback.

1. Keep the previous image tags in git history.
2. Revert the commit (or check out the last known good SHA) in `/opt/wordpress-infra`.
3. Run `./scripts/deploy.sh staging`, verify, then `./scripts/deploy.sh production`.
4. If the database was migrated in a breaking way, restore the pre-change dump. See [backup-restore.md](backup-restore.md).

Do not delete volumes to "start clean" on a live VPS.

## First WordPress URLs

WordPress stores the site URL in the database from the address you use in the installer. Use `http://VPS_IP:8080` and `http://VPS_IP:8081` consistently. If the address changes later, use WP-CLI `search-replace` on that environment only.
