#!/bin/sh
# Series: the platform configuration article — onboarding step 7: render a project's boundary from templates/ into projects/<project>/
# Run by the catalog Pipeline gitops-repo-update (submitMode pr) as its update
# script, from the root of a clone of this repository; the Pipeline then pushes
# a branch and opens the merge request. Never applies anything to a cluster.
#
# Usage: sh templates/render.sh <project> <gitops-repo-url> <cluster-name> <argocd-namespace>
#
# Reads projects/<project>.yaml (environments, owners) and, from the optional
# `update-scripts` workspace of gitops-repo-update ($GITOPS_UPDATE_SCRIPTS_DIR),
# platform-project.yaml, the platform project exported by onboarding step 1.
# Writes projects/<project>/ from scratch (so a removed environment disappears
# from the boundary too) and adds <project> to projects/kustomization.yaml.
# Needs yq v4 (the catalog kubectl image ships it as yq-<version>).
set -eu

[ "$#" -eq 4 ] || { echo "usage: $0 <project> <gitops-repo-url> <cluster-name> <argocd-namespace>" >&2; exit 1; }
PROJECT="$1"
REPO_URL="$2"
CLUSTER="$3"
ARGOCD_NS="$4"
export PROJECT REPO_URL CLUSTER ARGOCD_NS

fail() { echo "render.sh: $*" >&2; exit 1; }

# The catalog kubectl image names yq with its version; fall back to plain yq.
YQ="$(find /usr/local/bin -maxdepth 1 -name 'yq-*' 2>/dev/null | head -n 1 || true)"
[ -n "$YQ" ] || YQ="$(command -v yq || true)"
[ -n "$YQ" ] || fail "no yq binary in the update script image"

DECL="projects/${PROJECT}.yaml"
OUT="projects/${PROJECT}"
[ -f "$DECL" ] || fail "declaration ${DECL} not found; merge it before onboarding"
[ -f templates/application.yaml ] || fail "run from the root of the platform repository"

EXPORTED="${GITOPS_UPDATE_SCRIPTS_DIR:-}/platform-project.yaml"
if [ -z "${GITOPS_UPDATE_SCRIPTS_DIR:-}" ] || [ ! -s "$EXPORTED" ]; then
  fail "platform-project.yaml missing: bind the update-scripts workspace to the ConfigMap written by onboarding step 1"
fi

HEADER="Series: the platform configuration article — rendered by templates/render.sh for project ${PROJECT}; change the declaration or the template, not this file"
export HEADER

rm -rf "$OUT"
mkdir -p "$OUT"

# Exported platform project, copied as is (onboarding already removed status
# and server-set metadata).
cp "$EXPORTED" "${OUT}/platform-project.yaml"

# AppProject patch: repository and one destination per environment, the only
# two fields the platform keeps on the synchronized AppProject.
"$YQ" e '. head_comment = strenv(HEADER)
  | .metadata.name = strenv(PROJECT)
  | .metadata.namespace = strenv(ARGOCD_NS)
  | .spec.sourceRepos = [strenv(REPO_URL)]
  | .spec.destinations = []' templates/appproject-patch.yaml > "${OUT}/appproject-patch.yaml"

FILES="platform-project.yaml appproject-patch.yaml"
for env in $("$YQ" e '.environments[]' "$DECL"); do
  ENV="$env"
  ENV_NS="${PROJECT}-${env}"
  export ENV ENV_NS
  "$YQ" e -i '.spec.destinations += [{"name": strenv(CLUSTER), "namespace": strenv(ENV_NS)}]' \
    "${OUT}/appproject-patch.yaml"
  "$YQ" e '. head_comment = strenv(HEADER)
    | .metadata.name = strenv(ENV_NS)
    | .metadata.namespace = strenv(ARGOCD_NS)
    | .metadata.labels."app.kubernetes.io/part-of" = strenv(PROJECT)
    | .spec.project = strenv(PROJECT)
    | .spec.source.repoURL = strenv(REPO_URL)
    | .spec.source.path = "envs/" + strenv(ENV)
    | .spec.destination.name = strenv(CLUSTER)
    | .spec.destination.namespace = strenv(ENV_NS)' templates/application.yaml > "${OUT}/application-${env}.yaml"
  FILES="${FILES} application-${env}.yaml"
done

# Owners' RoleBinding: one Group subject per `owners` entry. An empty list
# would bind nobody, so it is refused (step 1 of onboarding refuses it too).
"$YQ" e '. head_comment = strenv(HEADER)
  | .metadata.name = strenv(PROJECT) + "-owners"
  | .metadata.namespace = strenv(PROJECT)
  | .metadata.labels."app.kubernetes.io/part-of" = strenv(PROJECT)
  | .subjects = []' templates/rolebinding-owners.yaml > "${OUT}/rolebinding-owners.yaml"
for owner in $("$YQ" e '.owners[]' "$DECL"); do
  OWNER="$owner"
  export OWNER
  "$YQ" e -i '.subjects += [{"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": strenv(OWNER)}]' \
    "${OUT}/rolebinding-owners.yaml"
done
[ "$("$YQ" e '.subjects | length' "${OUT}/rolebinding-owners.yaml")" != "0" ] || fail "${DECL} lists no owners"
FILES="${FILES} rolebinding-owners.yaml"

# Connector mounts: `get` on the Connectors each run mounts, for the CI
# ServiceAccount of <project>-build (<project>/<project>-harbor and the other
# project Connectors the CI may mount) and for <project>-delivery
# (<project>-cd/<project>-gitops-writer). Each Connector has two rules (`get`
# on the Connector, `connectors/proxy` `*` for the approval feature). The CI
# template names more than one Connector, so each of its resourceNames is
# renamed by its `shop-` prefix; the delivery template names one Connector,
# so `.rules[]` sets resourceNames in every rule. Each template holds
# a Role and its RoleBinding; both documents get the same name and namespace,
# and the CI subject keeps its fixed ServiceAccount name (`default`, what the
# runs use when TektonConfig sets no default ServiceAccount) with the project's
# build namespace.
"$YQ" e 'with(select(document_index == 0); . head_comment = strenv(HEADER))
  | .metadata.name = strenv(PROJECT) + "-ci-mount"
  | .metadata.namespace = strenv(PROJECT)
  | .metadata.labels."app.kubernetes.io/part-of" = strenv(PROJECT)
  | with(select(.kind == "Role"); .rules[].resourceNames[] |= sub("^shop-", strenv(PROJECT) + "-"))
  | with(select(.kind == "RoleBinding"); .roleRef.name = strenv(PROJECT) + "-ci-mount"
      | .subjects[0].namespace = strenv(PROJECT) + "-build")' \
  templates/connector-mount-ci.yaml > "${OUT}/connector-mount-ci.yaml"
"$YQ" e 'with(select(document_index == 0); . head_comment = strenv(HEADER))
  | .metadata.name = strenv(PROJECT) + "-delivery-mount"
  | .metadata.namespace = strenv(PROJECT) + "-cd"
  | .metadata.labels."app.kubernetes.io/part-of" = strenv(PROJECT)
  | with(select(.kind == "Role"); .rules[].resourceNames = [strenv(PROJECT) + "-gitops-writer"])
  | with(select(.kind == "RoleBinding"); .roleRef.name = strenv(PROJECT) + "-delivery-mount"
      | .subjects[0].name = strenv(PROJECT) + "-delivery"
      | .subjects[0].namespace = strenv(PROJECT) + "-cd")' \
  templates/connector-mount-delivery.yaml > "${OUT}/connector-mount-delivery.yaml"
FILES="${FILES} connector-mount-ci.yaml connector-mount-delivery.yaml"

{
  echo "# ${HEADER}"
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources:"
  for f in $FILES; do echo "  - ${f}"; done
} > "${OUT}/kustomization.yaml"

# Register the directory once; re-runs leave projects/kustomization.yaml as is,
# so an unchanged declaration produces no diff and no merge request.
if ! "$YQ" e '(.resources // [])[]' projects/kustomization.yaml | grep -qx "$PROJECT"; then
  "$YQ" e -i '.resources = ((.resources // []) + [strenv(PROJECT)])' projects/kustomization.yaml
fi
echo "rendered ${OUT}: ${FILES}"
