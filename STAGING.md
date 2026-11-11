# Deploying AGARI v2 to staging

| URL | What |
| --- | --- |
| <https://agari-v2-staging.openup.org.za> | the SPA |
| <https://api-v2-staging.openup.org.za> | the API (`/admin/` is the Django admin) |
| <https://api-v2-staging.openup.org.za/info/health> | health and running version |
| <https://minio-v2-staging.openup.org.za> | object storage (used by presigned upload URLs) |

Mailpit and Elasticsearch have no ingress on purpose.

## What you need

* SSH to the controller. It has `kubectl`,
  `helm` and a checkout of this repo in `~/agari-stack`.
* For config changes only: the secrets file `agari-staging-v2-secrets.yaml`.

## Deploying

Every push to agari-platform `master` builds
`ghcr.io/openupsa/agari-platform:<short commit hash>`. The run summary of the
[image workflow](https://github.com/OpenUpSA/agari-platform/actions/workflows/image.yml)
shows the tag. To deploy it, run this on the controller

```sh
cd ~/agari-stack && git pull -q && helm dependency update charts/agari-stack >/dev/null
helm upgrade agari charts/agari-stack -n agari-staging-v2 \
  --reuse-values --set agari-platform.image.tag=<hash> --wait --timeout 15m
```

`--reuse-values` keeps every setting and secret from the last release, so only the
image changes. Migrations run before the new pods start, and `--wait` returns
once they are up. Check the result with:

```sh
curl -s https://api-v2-staging.openup.org.za/info/health
kubectl -n agari-staging-v2 get pods
```

To see which image is running, use `helm -n agari-staging-v2 get values agari | grep ' tag:'`.
A new frontend image works the same way, with `--set agari-frontend.image.tag=<tag>`.

### Changing config

Settings live in `values/staging.yaml` and the secrets file
Use this when either of them changes, or when a chart change needs new values

1. Edit `values/staging.yaml` and push it to master. Make sure its image tags
   match what's running (`helm -n agari-staging-v2 get values agari | grep ' tag:'`), or the upgrade will roll the
   image back.
2. Copy the secrets file to the controller, upgrade from both files, then delete
   the copy:

   ```sh
   scp agari-staging-v2-secrets.yaml ubuntu@k8s-controller.sanbi.ac.za:/tmp/
   ssh ubuntu@k8s-controller.sanbi.ac.za
   cd ~/agari-stack && git pull -q && helm dependency update charts/agari-stack >/dev/null
   helm upgrade agari charts/agari-stack -n agari-staging-v2 \
     -f values/staging.yaml -f /tmp/agari-staging-v2-secrets.yaml --wait --timeout 15m
   rm /tmp/agari-staging-v2-secrets.yaml
   ```

### Rolling back

```sh
helm -n agari-staging-v2 history agari
helm -n agari-staging-v2 rollback agari <REVISION> --wait
```

A rollback restores the previous image and config. It does **not** undo database
migrations. If a release contained a migration that the old code cannot run
against, roll forward with a fix instead.

## Adding users

* **Normal path:** sign in at the SPA with the email address. A magic link is
  mailed and the account is created on first sign-in. Then add the user to an
  organisation or project, as its owner in the app or in the Django admin.
* **Django admin:** <https://api-v2-staging.openup.org.za/admin/> as
  `admin@agari-v2-staging.openup.org.za` (password: `adminPassword` in the
  secrets file). Go to **Users → Add user**, then set name, surname and
  *accepted terms*.
