# BASE_IMAGE is declared before the first FROM so that it is a global build arg
# and can be referenced by the FROM of the workload stage further down.
ARG BASE_IMAGE=mcr.microsoft.com/powershell:latest

# --------------------------------------------------------------------------
# Stage 1 - fetch the module.
#
# This stage runs on the build host's own architecture ($BUILDPLATFORM), which
# matters on Apple Silicon: the PowerShell base image below is amd64 only, and
# PowerShellGet crashes under emulation as soon as it downloads anything large.
# Fetching natively sidesteps that, and has the nice side effect of leaving no
# PSGallery bootstrap in the final image at all.
# --------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM alpine:3.20 AS modules

ARG GRAPH_AUTH_VERSION=2.36.1
ENV MODULE_DIR=/modules/Microsoft.Graph.Authentication

# Microsoft.Graph.Authentication ONLY.
#
# Do not install the Microsoft.Graph meta-module. It pulls in around 40 sub-modules
# and several hundred megabytes of cmdlets you will never call, and it turns a one
# minute build into a very long walk. Connect-MgGraph and Invoke-MgGraphRequest both
# live in Microsoft.Graph.Authentication, and Invoke-MgGraphRequest can reach every
# endpoint in Graph anyway.
RUN apk add --no-cache curl unzip \
    && mkdir -p "${MODULE_DIR}/${GRAPH_AUTH_VERSION}" \
    && curl -sSL "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication/${GRAPH_AUTH_VERSION}" -o /tmp/graph.nupkg \
    && unzip -q /tmp/graph.nupkg -d "${MODULE_DIR}/${GRAPH_AUTH_VERSION}" \
    && rm -rf /tmp/graph.nupkg \
              "${MODULE_DIR}/${GRAPH_AUTH_VERSION}/_rels" \
              "${MODULE_DIR}/${GRAPH_AUTH_VERSION}/package" \
              "${MODULE_DIR}/${GRAPH_AUTH_VERSION}/[Content_Types].xml" \
    && rm -f "${MODULE_DIR}/${GRAPH_AUTH_VERSION}"/*.nuspec

# --------------------------------------------------------------------------
# Stage 2 - the workload.
#
# The default tag is amd64. mcr.microsoft.com/powershell does publish arm64, but
# only under the Azure Linux tags, so on Apple Silicon build with:
#
#   docker build --build-arg BASE_IMAGE=mcr.microsoft.com/powershell:lts-azurelinux-3.0-arm64 .
#
# Build for the architecture of your cluster nodes. An amd64 image will not run on
# an arm64 node: containerd rejects it outright with "no match for platform in
# manifest" long before any emulation gets a chance to help.
# --------------------------------------------------------------------------
FROM ${BASE_IMAGE}

COPY --from=modules /modules /usr/local/share/powershell/Modules

WORKDIR /app
COPY Get-GraphDeviceReport.ps1 /app/Get-GraphDeviceReport.ps1

# No secret, certificate, connection string or credential file is baked into this
# image. Everything the workload needs to authenticate is injected at runtime by
# workload identity when the pod starts.
ENTRYPOINT ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/app/Get-GraphDeviceReport.ps1"]
