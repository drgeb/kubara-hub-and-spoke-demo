FROM liquibase/liquibase:4.31
LABEL maintainer="drgeb"

USER root
RUN apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*
USER liquibase

WORKDIR /liquibase
ENTRYPOINT ["liquibase"]
