# syntax=docker/dockerfile:1
# Worker image: the bridge runs the entrypoint on every action. Add the tools your steps need.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.1

# --chown: np chmods the action script in place, so the tree must belong to the runtime uid.
COPY --chown=10001:10001 . /app/pkg
ENV NP_PACKAGE_NAME=my-service \
    NP_SERVICE_PATH=/app/pkg/my-service \
    NP_SCOPE_ENTRYPOINT=/app/pkg/my-service/entrypoint/entrypoint

# Numeric so runAsNonRoot admission can verify it; worker-bridge 2.0.0+ ships this user and a writable HOME.
USER 10001:10001
