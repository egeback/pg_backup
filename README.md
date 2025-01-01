# pg_backup

Postgres backup runner

Fork from https://github.com/damoclark/pg_backup/ with added support to upload to S3 bucket.

## Configuration

### Build and install

Update docker-compose.yaml_sample and rename to docker-compose.yaml

* Backup schedule: ``ofelia.job-exec.postgres-backup.schedule: "0 0 2 * * *"``. [Scheduling format documentation.](https://godoc.org/github.com/robfig/cronhttps:/)
* Backup location under volumes: ``- ./postgres/:/backup/``

### Application configuration

Update pg_backup.config_sample and rename to pg_backup.config

## Build

Build the image through docker compose.
``docker compose build``

## Install

Install image
``docker compose up -d``

## Licence

This script based on its origins are licenced under the terms of the [PostgreSQL License](https://wiki.postgresql.org/wiki/PostgreSQL_wiki:Copyrights).
