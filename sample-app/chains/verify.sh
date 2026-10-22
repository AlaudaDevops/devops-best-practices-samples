#!/usr/bin/env bash
# Series: the delivery article — verify the Tekton Chains signature and SLSA provenance of an image, by digest
# Prints one PASS/FAIL line per check and a summary line; exits non-zero when
# any check fails.
#
# cosign.pub is the platform's Chains public key (the `cosign.pub` entry of the
# `signing-secrets` Secret in the Chains namespace). The platform distributes
# it. Only a platform administrator exports it, because the same Secret also
# holds cosign.key and cosign.password: whoever can read it can sign any image
# as the platform. Export (platform administrator):
#   kubectl get secret -n tekton-pipelines signing-secrets \
#     -o jsonpath='{.data.cosign\.pub}' | base64 -d > cosign.pub
# Publishing cosign.pub in a ConfigMap or a public repository gives projects
# the key without any access to the Secret. Check who can read the Secret
# before enabling signing (sample-app/chains/README.md).
# Chains stores signatures beside each image; only when the platform keeps them
# in a separate repository (optional hardening, `storage.oci.repository`),
# export COSIGN_REPOSITORY=<that repository> first.
set -u

# Image to verify, always repository@sha256:<digest>. Use the CI build
# (registry.example.com/shop/hello@...) or the promoted release image
# (registry.example.com/shop-prod/hello@..., signed by the promotion run).
IMAGE="${IMAGE:-registry.example.com/shop-prod/hello@sha256:<digest>}"
COSIGN_PUB="${COSIGN_PUB:-./cosign.pub}"
# Air-gapped platforms usually run Chains without a transparency log (Rekor);
# set IGNORE_TLOG=true there, otherwise cosign fails looking up the log entry.
IGNORE_TLOG="${IGNORE_TLOG:-false}"

pass=0
fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
ko() { echo "FAIL $1"; fail=$((fail + 1)); }

tlog_args=()
if [ "$IGNORE_TLOG" = "true" ]; then
  tlog_args=(--insecure-ignore-tlog=true)
fi

# A tag can be moved to another image; only a digest names the content that
# was signed, so refuse to verify anything else.
if printf '%s\n' "$IMAGE" | grep -Eq '^[^@[:space:]]+@sha256:[0-9a-f]{64}$'; then
  ok "image is pinned by digest"
else
  ko "image is pinned by digest ($IMAGE)"
fi

if [ -s "$COSIGN_PUB" ]; then
  ok "public key present ($COSIGN_PUB)"
else
  ko "public key present ($COSIGN_PUB)"
fi

if command -v cosign >/dev/null 2>&1; then
  ok "cosign available"
else
  ko "cosign available"
fi

if [ "$fail" -eq 0 ]; then
  if cosign verify --key "$COSIGN_PUB" ${tlog_args[@]+"${tlog_args[@]}"} "$IMAGE" >/dev/null; then
    ok "image signature verifies against the platform key"
  else
    ko "image signature verifies against the platform key"
  fi

  if att=$(cosign verify-attestation --key "$COSIGN_PUB" --type slsaprovenance ${tlog_args[@]+"${tlog_args[@]}"} "$IMAGE" 2>/dev/null); then
    ok "SLSA provenance attestation verifies against the platform key"
    # The attestation must be about THIS image: one of its subjects must carry
    # the digest being verified (the payload is base64-encoded in-toto JSON).
    want="${IMAGE##*@sha256:}"
    if command -v jq >/dev/null 2>&1 &&
      printf '%s\n' "$att" | jq -r '.payload | @base64d | fromjson | .subject[].digest.sha256' | grep -qx "$want"; then
      ok "provenance subject digest matches the image"
    else
      ko "provenance subject digest matches the image (needs jq)"
    fi
  else
    ko "SLSA provenance attestation verifies against the platform key"
  fi
fi

echo "== result: $pass pass / $fail fail =="
[ "$fail" -eq 0 ]
