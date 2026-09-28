# dpp-validator with a dpp-criteria checkout at a fixed commit.
# Build context is the repository root: ./build.sh (resolves the commit).
ARG RUBY_IMAGE=ruby:3.3-slim-bookworm

# dpp-criteria at DPP_CRITERIA_REF; the full commit is kept in COMMIT and
# reported in every result.
FROM ${RUBY_IMAGE} AS criteria
ARG DPP_CRITERIA_REF
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN test -n "${DPP_CRITERIA_REF}" && \
    git clone --quiet https://github.com/OwnYourData/dpp-criteria.git /opt/dpp-criteria && \
    cd /opt/dpp-criteria && git checkout --quiet --detach "${DPP_CRITERIA_REF}" && \
    git rev-parse HEAD > COMMIT && rm -rf .git

FROM ${RUBY_IMAGE}
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN apt-get update && apt-get install -y --no-install-recommends build-essential && \
    gem install bundler -v 2.5.23 --no-document && \
    bundle install && \
    apt-get purge -y build-essential && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
COPY . .
COPY --from=criteria /opt/dpp-criteria /opt/dpp-criteria
ENV DPP_CRITERIA_DIR=/opt/dpp-criteria
ENTRYPOINT ["docker/entrypoint.sh"]
CMD ["version"]
