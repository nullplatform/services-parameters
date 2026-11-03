# syntax=docker/dockerfile:1
#
# The bash package's worker image, published beside the TypeScript worker's as
# agent-plugins/services/parameters:<version>-bash: the bridge runs the
# entrypoint on every parameter:<action>. Built from this directory, so the
# scripts are all it carries:
#
#   docker build -t parameters-bash parameters
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.7

# The AWS providers and utils/assume_role call the AWS CLI. Azure Key Vault, GCP
# Secret Manager and HashiCorp Vault go through their REST APIs with curl, and
# bash, jq, curl and the np CLI ship with the bridge, so nothing else is needed.
RUN apk add --no-cache aws-cli

# --chown: np chmods the action script in place, and utils/assume_role caches STS
# credentials under $SERVICE_PATH/credentials, so the tree must belong to the runtime uid.
COPY --chown=10001:10001 . /app/pkg/parameters
ENV NP_PACKAGE_NAME=parameters \
    NP_SERVICE_PATH=/app/pkg/parameters \
    NP_SCOPE_ENTRYPOINT=/app/pkg/parameters/entrypoint

# Numeric so runAsNonRoot admission can verify it; worker-bridge 2.0.0+ ships this user and a writable HOME.
USER 10001:10001
