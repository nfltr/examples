# One variant of the example (app/ or with-nfltr/) in one runtime image, for
# the end-to-end test (scripts/test-dotnet-fleet.sh). The build
# context holds proto/, common/ and the variant's tree as fleet/; the same
# `dotnet publish` commands work on a machine with the .NET 8 SDK. nfltr is
# mounted at run time (the released binary), not baked in.
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY proto/ proto/
COPY fleet/agent/Agent.csproj fleet/agent/
COPY fleet/controlplane/ControlPlane.csproj fleet/controlplane/
RUN dotnet restore fleet/agent/Agent.csproj && dotnet restore fleet/controlplane/ControlPlane.csproj
COPY common/ common/
COPY fleet/ fleet/
RUN dotnet publish fleet/agent/Agent.csproj -c Release --no-restore -o /app/agent \
 && dotnet publish fleet/controlplane/ControlPlane.csproj -c Release --no-restore -o /app/controlplane

FROM mcr.microsoft.com/dotnet/aspnet:8.0
# The directory of the sidecar's unix sockets: only its owner may write it.
RUN mkdir -m 700 /run/nfltr
COPY --from=build /app /app
