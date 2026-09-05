# Version-controlled themes and plugins

Bind-mounted into both environments as:

```text
custom/plugins  →  wp-content/plugins/custom
custom/themes   →  wp-content/themes/custom
```

Put a theme or plugin in a subdirectory:

```text
custom/themes/my-theme/
custom/plugins/my-plugin/
```

Do not place uploads or cache here. Runtime `wp-content` lives in Docker volumes.

After changing files, reload PHP-FPM workers:

```bash
docker compose restart wordpress-prod
docker compose restart wordpress-stage
```

Production uses `opcache.validate_timestamps=0`, so a restart is required to pick up PHP changes.
