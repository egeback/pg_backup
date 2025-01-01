ARG ALPINE_VERSION
FROM alpine:${ALPINE_VERSION:-3.21.0}
ARG TARGETARCH

RUN apk upgrade --update-cache --available && \
    apk add openssl postgresql-client openssl aws-cli bash tzdata && \
    rm -rf /var/cache/apk/*

RUN adduser -D backup_user

ADD src/backup.sh /app/backup
ADD src/backup_rotated.sh /app/backup_rotated
ADD src/entrypoint.sh /app/entrypoint

RUN mkdir /backup
RUN chown -R 1000:1000 /backup

USER backup_user

ENV S3_ACCESS_KEY_ID **None**
ENV S3_SECRET_ACCESS_KEY **None**
ENV S3_BUCKET **None**
ENV S3_FILE_NAME **None**
ENV S3_REGION us-west-1
ENV S3_ENDPOINT **None**
ENV S3_S3V4 no
ENV ENCRYPTION_PASSWORD **None**

ENV PATH="$PATH:/app"

ENTRYPOINT ["sh", "/app/entrypoint"]