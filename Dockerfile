# Kavita on Railway
#
# The upstream image is used unchanged; this wrapper only adds the boot-time work
# Railway needs and Kavita cannot express as configuration:
#
#   * Kavita reads ONLY ./config/appsettings.json — Program.cs calls
#     config.Sources.Clear() before adding it, so no environment variable
#     configures the app. Anything Railway must set has to be written to that file.
#   * Kavita's config directory is hardcoded to <cwd>/config, so the volume is
#     symlinked into place rather than mounted over the application directory.
#   * The first account registered through POST /api/account/register becomes the
#     administrator. Without a bootstrap the server is claimable by whoever reaches
#     the URL first.
FROM ghcr.io/kareadita/kavita:latest

# jq builds appsettings.json and the API payloads: hand-rolled escaping cannot be
# made safe for a generated password. tini reaps the backgrounded bootstrap shell.
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq tini \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /railway-entrypoint.sh
RUN chmod +x /railway-entrypoint.sh

ENV KAVITA_DATA_DIR=/data \
    KAVITA_MEDIA_DIR=/data/media \
    KAVITA_BOOTSTRAP=true \
    KAVITA_DEMO_MEDIA=true

EXPOSE 5000

ENTRYPOINT ["/usr/bin/tini", "--", "/railway-entrypoint.sh"]
